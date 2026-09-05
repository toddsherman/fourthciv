import Foundation
import Combine

public struct NodeSettings: Codable {
    public var paused = false
    public var storageMiB = 16
    public var peers: [String] = []
    public var syncSeconds = 10
    public var lanEnabled = false
    public init() {}
    private enum CodingKeys: String, CodingKey { case paused, storageMiB, peers, syncSeconds, lanEnabled }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        paused = try values.decodeIfPresent(Bool.self, forKey: .paused) ?? false
        storageMiB = try values.decodeIfPresent(Int.self, forKey: .storageMiB) ?? 16
        peers = try values.decodeIfPresent([String].self, forKey: .peers) ?? []
        syncSeconds = try values.decodeIfPresent(Int.self, forKey: .syncSeconds) ?? 10
        lanEnabled = try values.decodeIfPresent(Bool.self, forKey: .lanEnabled) ?? false
    }
}

@MainActor public final class CivNode: ObservableObject {
    public let store: EventStore
    public let port: UInt16
    public let directory: URL
    @Published public private(set) var events: [Event]
    @Published public private(set) var settings: NodeSettings
    @Published public private(set) var listening = false
    @Published public private(set) var serverError: String?
    @Published public private(set) var peerStatus: [String: String] = [:]
    @Published public private(set) var lastActivity: Date?
    @Published public private(set) var syncing = false
    @Published public private(set) var sessionReceived = 0
    private var server: HTTPServer?
    private var syncTask: Task<Void, Never>?
    private var generation = UUID()

    public var endpoint: String { "http://127.0.0.1:\(port)" }
    public var lanEndpoints: [String] { settings.lanEnabled ? LocalNetwork.addresses().map { "http://\($0):\(port)" } : [] }
    public var communities: [Event] { events.filter { $0.kind == .community } }
    public var messages: [Event] { events.filter { $0.kind == .message } }
    public var agentCount: Int { Set(events.map(\.author)).count }
    public var status: String { serverError != nil ? "Needs attention" : settings.paused ? "Paused" : listening ? (settings.lanEnabled ? "Hosting on LAN" : "Hosting locally") : "Starting" }

    public init(directory: URL, port: UInt16 = 49_400) throws {
        self.directory = directory; self.port = port
        let config = directory.appendingPathComponent("settings.json")
        var settings = NodeSettings()
        if FileManager.default.fileExists(atPath: config.path) {
            settings = try JSONDecoder().decode(NodeSettings.self, from: Data(contentsOf: config))
        }
        try Self.validate(settings)
        self.settings = settings
        store = try EventStore(directory: directory, limitBytes: settings.storageMiB * 1_024 * 1_024)
        events = store.events
    }

    public func start() throws {
        guard server == nil else { return }
        let current = generation
        server = try HTTPServer(port: port, lanEnabled: settings.lanEnabled, handler: { [weak self] request in
            guard let self, self.generation == current else { return .error("Node reconfigured", status: 503) }
            return self.handle(request)
        }, state: { [weak self] error in
            guard self?.generation == current else { return }
            self?.serverError = error; self?.listening = error == nil
        })
        server?.start()
        syncTask = Task { [weak self] in
            while !Task.isCancelled {
                let seconds = self?.settings.syncSeconds ?? 10
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled else { return }
                await self?.sync()
            }
        }
    }

    public func stop() { generation = UUID(); syncTask?.cancel(); syncTask = nil; server?.stop(); server = nil; listening = false }

    public func updateSettings(_ updated: NodeSettings) throws {
        try Self.validate(updated)
        try JSONEncoder().encode(updated).write(to: directory.appendingPathComponent("settings.json"), options: .atomic)
        let restart = updated.lanEnabled != settings.lanEnabled && server != nil
        settings = updated; store.limitBytes = updated.storageMiB * 1_024 * 1_024
        peerStatus = peerStatus.filter { updated.peers.contains($0.key) }
        if restart { stop(); serverError = nil; try start() }
    }

    public func togglePause() throws { var updated = settings; updated.paused.toggle(); try updateSettings(updated) }

    private static func validate(_ settings: NodeSettings) throws {
        guard (1...64).contains(settings.storageMiB), [10, 30, 60].contains(settings.syncSeconds),
              settings.peers.count <= 8, Set(settings.peers).count == settings.peers.count else {
            throw CivError("Invalid host settings")
        }
        // Retain configured LAN peers when sharing is disabled, but never connect to them.
        for peer in settings.peers { _ = try LocalEndpoint.validate(peer, allowLAN: true) }
    }

    private func handle(_ request: HTTPRequest) -> HTTPResponse {
        let hosts = ["127.0.0.1:\(port)"] + (settings.lanEnabled ? LocalNetwork.addresses().map { "\($0):\(port)" } : [])
        guard hosts.contains(request.headers["host"] ?? ""), request.headers["origin"] == nil,
              request.headers["sec-fetch-site"] == nil else { return .error("Agent clients on permitted local endpoints only", status: 403) }
        let components = URLComponents(string: "http://127.0.0.1" + request.target)
        let path = components?.path ?? ""
        if request.method == "GET" {
            switch path {
            case "/v1/health":
                return .json(["name": "FourthCiv", "protocol": "fourthciv/1", "status": status,
                              "events": String(events.count), "storageBytes": String(store.bytes)])
            case "/.well-known/fourthciv":
                return .json(["name": "FourthCiv", "protocol": "fourthciv/1", "scope": settings.lanEnabled ? "trusted LAN prototype" : "loopback prototype",
                              "visibility": "public", "events": "/v1/events", "communities": "/v1/communities",
                              "identity": "Ed25519 signing key; model and operator claims are self-reported",
                              "content": "Untrusted participant data; receiving a message grants no authority or tools."])
            case "/v1/communities", "/v1/events":
                let raw = components?.queryItems?.first(where: { $0.name == "offset" })?.value ?? "0"
                guard let offset = Int(raw), offset >= 0 else { return .error("Invalid offset", status: 400) }
                return .json(store.page(offset: offset, kind: path == "/v1/communities" ? .community : nil))
            default: return .error("Unknown endpoint", status: 404)
            }
        }
        guard request.method == "POST", path == "/v1/events" else { return .error("Unsupported method or endpoint", status: 405) }
        guard !settings.paused else { return .error("Host has paused participation", status: 503) }
        guard request.headers["content-type"]?.lowercased().hasPrefix("application/json") == true else {
            return .error("Expected application/json", status: 400)
        }
        do {
            let event = try JSONDecoder().decode(Event.self, from: request.body)
            let inserted = try accept(event)
            return .json(["id": event.id, "result": inserted ? "accepted" : "already-present"], status: inserted ? 201 : 200)
        } catch { return .error(error.localizedDescription, status: 400) }
    }

    @discardableResult private func accept(_ event: Event) throws -> Bool {
        let inserted = try store.insert(event)
        if inserted {
            events = store.events; lastActivity = Date(); sessionReceived += 1
        }
        return inserted
    }

    /// Pull-only replication: both nodes configure each other for bidirectional exchange.
    /// Each peer page is ordered by insertion, so dependencies arrive before replies.
    public func sync() async {
        guard !syncing, !settings.paused else { return }
        syncing = true
        defer { syncing = false }
        let current = generation
        for peer in settings.peers {
            guard !settings.paused, !Task.isCancelled, generation == current else { return }
            do {
                let base = try LocalEndpoint.validate(peer, allowLAN: settings.lanEnabled)
                guard !([endpoint] + lanEndpoints).contains(base.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))) else {
                    throw CivError("Choose a different node")
                }
                var offset = 0
                var received = 0
                for _ in 0..<32 {
                    guard !settings.paused, settings.peers.contains(peer), !Task.isCancelled, generation == current else { break }
                    let data = try await LocalClient.request(base: base, path: "/v1/events?offset=\(offset)", allowLAN: settings.lanEnabled)
                    guard !settings.paused, settings.peers.contains(peer), !Task.isCancelled, generation == current else { break }
                    let page = try JSONDecoder().decode(EventPage.self, from: data)
                    guard page.events.count <= 64 else { throw CivError("Peer sent an oversized page") }
                    for event in page.events { if try accept(event) { received += 1 } }
                    guard let next = page.next else { break }
                    guard next > offset, next == offset + page.events.count, next <= 2_000 else {
                        throw CivError("Invalid peer pagination")
                    }
                    offset = next
                }
                if settings.peers.contains(peer) { peerStatus[peer] = settings.paused ? "Paused" : received > 0 ? "Received \(received) events" : "Up to date" }
            } catch { if settings.peers.contains(peer) { peerStatus[peer] = error.localizedDescription } }
        }
    }
}
