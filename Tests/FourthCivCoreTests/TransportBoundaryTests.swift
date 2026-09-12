import Foundation
import Network
import Testing
@testable import FourthCivCore

/// A real loopback peer with deliberately hostile HTTP responses. It never contacts a relay.
private final class BoundaryHTTPPeer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "fourthciv.transport-boundary-test")
    private let response: Data
    private let holdOpen: Bool
    private var connections: [NWConnection] = []
    private var requestCount = 0
    private var startup: CheckedContinuation<Void, Error>?

    private init(response: Data, holdOpen: Bool) throws {
        self.response = response; self.holdOpen = holdOpen
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    static func start(_ response: Data = Data(), holdOpen: Bool = false) async throws -> BoundaryHTTPPeer {
        let peer = try BoundaryHTTPPeer(response: response, holdOpen: holdOpen)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peer.startup = continuation
            peer.listener.stateUpdateHandler = { [weak peer] state in
                guard let peer, let startup = peer.startup else { return }
                switch state {
                case .ready: peer.startup = nil; startup.resume()
                case .failed(let error): peer.startup = nil; startup.resume(throwing: error)
                default: break
                }
            }
            peer.listener.newConnectionHandler = { [weak peer] connection in
                guard let peer else { connection.cancel(); return }
                peer.connections.append(connection)
                connection.start(queue: peer.queue)
                peer.receive(connection, data: Data())
            }
            peer.listener.start(queue: peer.queue)
        }
        return peer
    }

    var base: URL { URL(string: "http://127.0.0.1:\(listener.port!.rawValue)")! }
    var requests: Int { queue.sync { requestCount } }

    func stop() {
        listener.cancel()
        queue.sync {
            connections.forEach { $0.cancel() }
            connections.removeAll()
        }
    }

    private func receive(_ connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] bytes, _, done, error in
            guard let self else { return }
            var received = data
            if let bytes { received.append(bytes) }
            if received.range(of: Data("\r\n\r\n".utf8)) != nil {
                self.requestCount += 1
                guard !self.response.isEmpty else { return }
                connection.send(content: self.response, completion: .contentProcessed { [weak self] _ in
                    if self?.holdOpen != true { connection.cancel() }
                })
            } else if !done && error == nil && received.count < 96 * 1_024 {
                self.receive(connection, data: received)
            } else { connection.cancel() }
        }
    }
}

struct TransportBoundaryTests {
    private func response(body: Data, chunked: Bool = false, declaredLength: Int? = nil) -> Data {
        let framing = chunked ? "Transfer-Encoding: chunked" : "Content-Length: \(declaredLength ?? body.count)"
        var result = Data("HTTP/1.1 200 OK\r\n\(framing)\r\nConnection: close\r\n\r\n".utf8)
        if chunked { result.append(Data("\(String(body.count, radix: 16))\r\n".utf8)) }
        result.append(body)
        if chunked { result.append(Data("\r\n0\r\n\r\n".utf8)) }
        return result
    }

    private func rejected(_ operation: () async throws -> Data) async throws -> TransferFailure {
        do { _ = try await operation() }
        catch { return try #require(error as? TransferFailure) }
        Issue.record("The hostile response was accepted")
        throw CivError("Expected transport rejection")
    }

    @Test func redirectsNeverForwardSignedBodiesToAnotherOrigin() async throws {
        let target = try await BoundaryHTTPPeer.start(response(body: Data("unexpected".utf8)))
        defer { target.stop() }
        let event = try Event.signed(kind: .community, key: .init(), attribution: Attribution(name: "Local fixture"),
                                     title: "Redirect fixture", body: "Must not be forwarded")
        for status in [302, 307] {
            let source = try await BoundaryHTTPPeer.start(Data("HTTP/1.1 \(status) Redirect\r\nLocation: \(target.base)/v1/events\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
            defer { source.stop() }
            let failure = try await rejected {
                try await LocalClient.request(base: source.base, path: "/v1/events", event: event)
            }
            #expect(failure.diagnostic.httpStatus == status)
            #expect(source.requests == 1)
        }
        #expect(target.requests == 0)
    }

    @Test func fixedAndChunkedBodiesAtTheResponseLimitRemainIntact() async throws {
        let body = Data(repeating: 0x61, count: 1_024)
        for chunked in [false, true] {
            let peer = try await BoundaryHTTPPeer.start(response(body: body, chunked: chunked))
            defer { peer.stop() }
            let received = try await LocalClient.request(base: peer.base, path: "/v1/events", maxResponseBytes: body.count)
            #expect(received == body)
        }
    }

    @Test func oversizedDeclaredAndStreamingBodiesAreRejected() async throws {
        for chunked in [false, true] {
            let peer = try await BoundaryHTTPPeer.start(response(body: Data(repeating: 0x61, count: 128 * 1_024), chunked: chunked))
            defer { peer.stop() }
            let failure = try await rejected {
                try await LocalClient.request(base: peer.base, path: "/v1/events", maxResponseBytes: 1_024)
            }
            #expect(failure.diagnostic.kind == .responseTooLarge)
            if chunked { #expect(failure.receivedBytes > 1_024) }
            else { #expect(failure.receivedBytes == 0) }
        }
    }

    @Test func aTruncatedResponseNeverBecomesSuccessfulData() async throws {
        let partial = Data("partial".utf8)
        let peer = try await BoundaryHTTPPeer.start(response(body: partial, declaredLength: 1_024))
        defer { peer.stop() }
        let failure = try await rejected {
            try await LocalClient.request(base: peer.base, path: "/v1/events")
        }
        #expect(failure.receivedBytes <= partial.count)
        #expect(peer.requests == 1)
    }

    @Test func cancellationStopsAnActiveStalledRequest() async throws {
        let peer = try await BoundaryHTTPPeer.start(holdOpen: true)
        defer { peer.stop() }
        let request = Task { try await LocalClient.request(base: peer.base, path: "/v1/events") }
        defer { request.cancel() }
        for _ in 0..<200 {
            if peer.requests > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(peer.requests == 1)
        let cancelledAt = ContinuousClock.now
        request.cancel()
        let failure = try await rejected { try await request.value }
        #expect(failure.diagnostic.kind == .cancelled)
        #expect(failure.receivedBytes == 0)
        #expect(cancelledAt.duration(to: .now) < .seconds(3))
    }

    @Test(.timeLimit(.minutes(1))) func aStalledPeerTimesOutWithoutExternalCancellation() async throws {
        let peer = try await BoundaryHTTPPeer.start(holdOpen: true)
        defer { peer.stop() }
        let started = ContinuousClock.now
        let failure = try await rejected {
            try await LocalClient.request(base: peer.base, path: "/v1/events")
        }
        #expect(peer.requests == 1)
        #expect(failure.diagnostic.networkCode == NSURLErrorTimedOut)
        #expect(failure.receivedBytes == 0)
        #expect(started.duration(to: .now) < .seconds(30))
    }
}
