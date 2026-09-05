import Foundation
import Network

public struct HTTPRequest: Sendable {
    public let method: String
    public let target: String
    public let headers: [String: String]
    public let body: Data

    /// One request per connection; chunking and pipelining are deliberately unsupported.
    public static func parse(_ data: Data) throws -> HTTPRequest? {
        guard data.count <= 96 * 1_024 else { throw CivError("Request too large") }
        guard let boundary = data.range(of: Data("\r\n\r\n".utf8)) else {
            guard data.count <= 8_192 else { throw CivError("Headers too large") }
            return nil
        }
        guard boundary.lowerBound <= 8_192,
              let head = String(data: data[..<boundary.lowerBound], encoding: .utf8) else {
            throw CivError("Invalid headers")
        }
        let lines = head.components(separatedBy: "\r\n")
        let request = lines[0].split(separator: " ")
        guard request.count == 3, request[2] == "HTTP/1.1", request[1].hasPrefix("/") else {
            throw CivError("Expected an HTTP/1.1 request")
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw CivError("Invalid header") }
            let name = line[..<colon].lowercased()
            guard headers[name] == nil else { throw CivError("Duplicate header") }
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["transfer-encoding"] == nil else { throw CivError("Chunked requests are unsupported") }
        guard let length = Int(headers["content-length"] ?? "0"), (0...80 * 1_024).contains(length) else {
            throw CivError("Invalid content length")
        }
        if request[0] == "POST" && headers["content-length"] == nil { throw CivError("Content-Length is required") }
        let available = data.count - boundary.upperBound
        if available < length { return nil }
        guard available == length else { throw CivError("Pipelining is unsupported") }
        return HTTPRequest(method: String(request[0]), target: String(request[1]), headers: headers,
                           body: Data(data[boundary.upperBound...]))
    }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var body: Data
    public static func json<T: Encodable>(_ value: T, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, body: (try? JSONEncoder().encode(value)) ?? Data("{}".utf8))
    }
    public static func error(_ message: String, status: Int) -> HTTPResponse { .json(["error": message], status: status) }
}

// Connection state is confined to queue; handlers and state reporting run on MainActor.
public final class HTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "fourthciv.http")
    private var connections: [UUID: NWConnection] = [:]
    private let handler: @MainActor (HTTPRequest) -> HTTPResponse
    private let state: @MainActor (String?) -> Void

    public init(port: UInt16, lanEnabled: Bool = false, handler: @escaping @MainActor (HTTPRequest) -> HTTPResponse,
                state: @escaping @MainActor (String?) -> Void) throws {
        guard port > 0 else { throw CivError("Port must be between 1 and 65535") }
        self.handler = handler; self.state = state
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: lanEnabled ? "0.0.0.0" : "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        listener = try NWListener(using: parameters)
    }

    public func start() {
        listener.stateUpdateHandler = { [weak self] value in
            guard let self else { return }
            switch value {
            case .ready: Task { @MainActor in self.state(nil) }
            case .failed(let error): Task { @MainActor in self.state(error.localizedDescription) }
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            guard case .hostPort(let host, _) = connection.endpoint,
                  LocalNetwork.permits(String(describing: host), allowLAN: true) else { connection.cancel(); return }
            guard self.connections.count < 16 else { connection.cancel(); return }
            let id = UUID()
            self.connections[id] = connection
            connection.start(queue: self.queue)
            self.queue.asyncAfter(deadline: .now() + 5) { [weak self] in self?.finish(id) }
            self.receive(connection, id: id, buffer: Data())
        }
        listener.start(queue: queue)
    }

    public func stop() {
        listener.cancel()
        queue.async { [weak self] in
            guard let self else { return }
            for connection in self.connections.values { connection.cancel() }
            self.connections.removeAll()
        }
    }

    private func receive(_ connection: NWConnection, id: UUID, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, done, error in
            guard let self, self.connections[id] != nil else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            do {
                if let request = try HTTPRequest.parse(buffer) {
                    Task { @MainActor in
                        let response = self.handler(request)
                        self.queue.async { self.send(response, connection: connection, id: id) }
                    }
                } else if done || error != nil { self.finish(id) }
                else { self.receive(connection, id: id, buffer: buffer) }
            } catch { self.send(.error(error.localizedDescription, status: 400), connection: connection, id: id) }
        }
    }

    private func send(_ response: HTTPResponse, connection: NWConnection, id: UUID) {
        guard connections[id] != nil else { return }
        let reason = [200: "OK", 201: "Created", 400: "Bad Request", 403: "Forbidden", 404: "Not Found",
                      405: "Method Not Allowed", 503: "Service Unavailable"][response.status] ?? "Error"
        var bytes = Data("HTTP/1.1 \(response.status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(response.body.count)\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n\r\n".utf8)
        bytes.append(response.body)
        connection.send(content: bytes, completion: .contentProcessed { [weak self] _ in self?.finish(id) })
    }

    private func finish(_ id: UUID) { connections.removeValue(forKey: id)?.cancel() }
}

public enum LocalEndpoint {
    public static func validate(_ text: String, allowLAN: Bool = false) throws -> URL {
        guard let parts = URLComponents(string: text), parts.scheme == "http",
              let host = parts.host, LocalNetwork.permits(host, allowLAN: allowLAN),
              let port = parts.port, (1...65_535).contains(port),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/", let url = parts.url else {
            throw CivError(allowLAN ? "Use http://PRIVATE_IPV4:PORT or http://127.0.0.1:PORT; public IPs and hostnames are unsupported" : "Enable LAN sharing to use a private IPv4 peer; otherwise use http://127.0.0.1:PORT")
        }
        return url
    }
}

/// Streaming response limits keep an untrusted local peer from sending an unbounded body.
public final class LocalClient: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate {
    private var continuation: CheckedContinuation<Data, Error>?
    private var buffer = Data()
    private var response: HTTPURLResponse?
    private var session: URLSession?

    public static func request(base: URL, path: String, event: Event? = nil, allowLAN: Bool = false) async throws -> Data {
        _ = try LocalEndpoint.validate(base.absoluteString, allowLAN: allowLAN)
        guard let url = URL(string: path, relativeTo: base)?.absoluteURL,
              url.host == base.host, url.port == base.port else { throw CivError("Invalid request path") }
        var request = URLRequest(url: url, timeoutInterval: 5)
        if let event {
            request.httpMethod = "POST"; request.httpBody = try JSONEncoder().encode(event)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let client = LocalClient()
        return try await withCheckedThrowingContinuation { continuation in
            client.continuation = continuation
            let config = URLSessionConfiguration.ephemeral
            config.connectionProxyDictionary = [:]
            client.session = URLSession(configuration: config, delegate: client, delegateQueue: nil)
            client.session?.dataTask(with: request).resume()
        }
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                           completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard response.expectedContentLength <= 4 * 1_024 * 1_024 else {
            completionHandler(.cancel); finish(.failure(CivError("Peer response too large"))); return
        }
        self.response = response as? HTTPURLResponse
        completionHandler(.allow)
    }
    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard buffer.count + data.count <= 4 * 1_024 * 1_024 else {
            dataTask.cancel(); finish(.failure(CivError("Peer response too large"))); return
        }
        buffer.append(data)
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)); return }
        guard let response, (200..<300).contains(response.statusCode) else {
            let detail = (try? JSONDecoder().decode([String: String].self, from: buffer))?["error"] ?? "Peer request failed"
            finish(.failure(CivError(detail))); return
        }
        finish(.success(buffer))
    }
    private func finish(_ result: Result<Data, Error>) {
        guard let continuation else { return }
        self.continuation = nil; continuation.resume(with: result)
        session?.finishTasksAndInvalidate(); session = nil
    }
}
