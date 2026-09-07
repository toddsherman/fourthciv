import Foundation
import Combine

public struct NodeSettings: Codable {
    public var paused = false
    public var storageMiB = 16
    public var peers: [String] = []
    public var syncSeconds = 10
    public var lanEnabled = false
    public var internetEnabled = false
    public var dailySyncMiB = 25
    public var relays: [String] = [RelayEndpoint.pilot]
    public init() {}
    private enum CodingKeys: String, CodingKey { case paused, storageMiB, peers, syncSeconds, lanEnabled, internetEnabled, dailySyncMiB, relays }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        paused = try values.decodeIfPresent(Bool.self, forKey: .paused) ?? false
        storageMiB = try values.decodeIfPresent(Int.self, forKey: .storageMiB) ?? 16
        peers = try values.decodeIfPresent([String].self, forKey: .peers) ?? []
        syncSeconds = try values.decodeIfPresent(Int.self, forKey: .syncSeconds) ?? 10
        lanEnabled = try values.decodeIfPresent(Bool.self, forKey: .lanEnabled) ?? false
        internetEnabled = try values.decodeIfPresent(Bool.self, forKey: .internetEnabled) ?? false
        dailySyncMiB = try values.decodeIfPresent(Int.self, forKey: .dailySyncMiB) ?? 25
        relays = try values.decodeIfPresent([String].self, forKey: .relays) ?? [RelayEndpoint.pilot]
    }
}

public typealias NodeRequest = @MainActor (URL, String, Event?, Bool, Bool, Int) async throws -> Data

@MainActor public final class CivNode: ObservableObject {
    public let store: EventStore
    public let port: UInt16
    public let directory: URL
    public let ledger: SyncLedger
    public let diagnostics: DiagnosticLog
    @Published public private(set) var events: [Event]
    @Published public private(set) var settings: NodeSettings
    @Published public private(set) var listening = false
    @Published public private(set) var serverError: String?
    @Published public private(set) var peerStatus: [String: String] = [:]
    @Published public private(set) var lastActivity: Date?
    @Published public private(set) var syncing = false
    @Published public private(set) var sessionReceived = 0
    @Published public private(set) var internetBytes = 0
    private var server: HTTPServer?
    private var syncTask: Task<Void, Never>?
    private var generation = UUID()
    private var serverGeneration = UUID()
    private var activeRequest: Task<Data, Error>?
    private var relaySchedule: [String: (failures: Int, next: Date)] = [:]
    private struct RelayObservation {
        var attempt: Date
        var success: Date?
        var failure: DiagnosticFailure?
    }
    private var relayObservations: [String: RelayObservation] = [:]
    private let requestData: NodeRequest

    public var endpoint: String { "http://127.0.0.1:\(port)" }
    public var lanEndpoints: [String] { settings.lanEnabled ? LocalNetwork.addresses().map { "http://\($0):\(port)" } : [] }
    public var communities: [Event] { events.filter { $0.kind == .community } }
    public var messages: [Event] { events.filter { $0.kind == .message } }
    public var agentCount: Int { Set(events.map(\.author)).count }
    public var status: String { serverError != nil ? "Needs attention" : settings.paused ? "Paused" : listening ? (settings.internetEnabled ? "Internet pilot enabled" : settings.lanEnabled ? "Hosting on LAN" : "Hosting locally") : "Starting" }

    public init(directory: URL, port: UInt16 = 49_400, joinInternetOnFirstRun: Bool = false, request: @escaping NodeRequest = { base, path, event, lan, internet, maximum in
        try await LocalClient.request(base: base, path: path, event: event, allowLAN: lan, allowInternet: internet, maxResponseBytes: maximum)
    }) throws {
        self.directory = directory; self.port = port
        requestData = request
        let config = directory.appendingPathComponent("settings.json")
        let hasSettings = FileManager.default.fileExists(atPath: config.path)
        var settings = NodeSettings()
        if hasSettings {
            settings = try JSONDecoder().decode(NodeSettings.self, from: Data(contentsOf: config))
        } else if joinInternetOnFirstRun {
            // An older local store without settings is not a new installation.
            let hasData = try FileManager.default.fileExists(atPath: directory.path)
                && !FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty
            settings.internetEnabled = !hasData
        }
        try Self.validate(settings)
        self.settings = settings
        store = try EventStore(directory: directory, limitBytes: settings.storageMiB * 1_024 * 1_024)
        events = store.events
        ledger = try SyncLedger(directory: directory)
        try ledger.retain(settings.relays)
        internetBytes = ledger.used()
        diagnostics = DiagnosticLog(directory: directory)
        diagnostics.record(.nodeOpened)
        // Persist the initial choice before starting any network work.
        if !hasSettings {
            try JSONEncoder().encode(settings).write(to: config, options: .atomic)
        }
    }

    public func start() throws {
        guard server == nil else { return }
        let current = serverGeneration
        server = try HTTPServer(port: port, lanEnabled: settings.lanEnabled, handler: { [weak self] request in
            guard let self, self.serverGeneration == current else { return .error("Node reconfigured", status: 503) }
            return self.handle(request)
        }, state: { [weak self] error in
            guard self?.serverGeneration == current else { return }
            self?.serverError = error; self?.listening = error == nil
            self?.diagnostics.record(error == nil ? .listenerReady : .listenerFailed)
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

    public func stop() {
        generation = UUID(); serverGeneration = UUID(); activeRequest?.cancel()
        syncTask?.cancel(); syncTask = nil; server?.stop(); server = nil; listening = false
        diagnostics.record(.nodeStopped)
    }

    public func updateSettings(_ updated: NodeSettings) throws {
        try Self.validate(updated)
        try JSONEncoder().encode(updated).write(to: directory.appendingPathComponent("settings.json"), options: .atomic)
        let restart = updated.lanEnabled != settings.lanEnabled && server != nil
        let networkChanged = updated.paused != settings.paused || updated.internetEnabled != settings.internetEnabled ||
            updated.relays != settings.relays || updated.peers != settings.peers || updated.dailySyncMiB != settings.dailySyncMiB
        if networkChanged { generation = UUID(); activeRequest?.cancel(); relaySchedule = [:] }
        settings = updated; store.limitBytes = updated.storageMiB * 1_024 * 1_024
        try ledger.retain(updated.relays)
        peerStatus = peerStatus.filter { (updated.peers + updated.relays).contains($0.key) }
        relayObservations = relayObservations.filter { updated.relays.contains($0.key) }
        diagnostics.configurationChanged()
        if restart { stop(); serverError = nil; try start() }
    }

    public func togglePause() throws { var updated = settings; updated.paused.toggle(); try updateSettings(updated) }

    public func diagnosticSnapshot() -> NodeDiagnostic {
        NodeDiagnostic(session: diagnostics.session, configuration: diagnostics.configuration,
            status: status, listening: listening, paused: settings.paused, internetEnabled: settings.internetEnabled,
            lanEnabled: settings.lanEnabled, syncing: syncing, syncSeconds: settings.syncSeconds,
            localPeerCount: settings.peers.count, eventCount: events.count, storageBytes: store.bytes,
            storageLimitBytes: settings.storageMiB * 1_024 * 1_024, syncBytesToday: ledger.used(),
            dailySyncLimitBytes: settings.dailySyncMiB * 1_024 * 1_024, historySaved: diagnostics.saved,
            recoveredUnreadableHistory: diagnostics.recoveredUnreadableHistory,
            relays: settings.relays.enumerated().map { index, relay in
                let observation = relayObservations[relay]
                let progress = ledger.progress(for: relay)
                return RelayDiagnostic(index: index + 1, isPilot: relay == RelayEndpoint.pilot,
                    lastAttempt: observation?.attempt, lastSuccess: observation?.success,
                    lastFailure: observation?.failure,
                    nextAttempt: settings.paused || !settings.internetEnabled ? nil : relaySchedule[relay]?.next,
                    consecutiveFailures: relaySchedule[relay]?.failures ?? 0,
                    acknowledgedEvents: progress.acknowledged.count,
                    pendingEvents: events.filter { !progress.acknowledged.contains($0.id) }.count)
            }, recentActivity: diagnostics.recentEntries())
    }

    private static func validate(_ settings: NodeSettings) throws {
        guard (1...64).contains(settings.storageMiB), [10, 30, 60].contains(settings.syncSeconds),
              settings.peers.count <= 8, Set(settings.peers).count == settings.peers.count,
              (1...1_024).contains(settings.dailySyncMiB), settings.relays.count <= 8,
              Set(settings.relays).count == settings.relays.count else {
            throw CivError("Invalid host settings")
        }
        // Retain configured LAN peers when sharing is disabled, but never connect to them.
        for peer in settings.peers { _ = try LocalEndpoint.validate(peer, allowLAN: true) }
        for relay in settings.relays { _ = try RelayEndpoint.validate(relay) }
    }

    private func handle(_ request: HTTPRequest) -> HTTPResponse {
        let hosts = ["127.0.0.1:\(port)"] + (settings.lanEnabled ? LocalNetwork.addresses().map { "\($0):\(port)" } : [])
        guard hosts.contains(request.headers["host"] ?? ""), request.headers["origin"] == nil,
              request.headers["sec-fetch-site"] == nil else { return .error("Agent clients on permitted local endpoints only", status: 403) }
        let components = URLComponents(string: "http://127.0.0.1" + request.target)
        let path = components?.path ?? ""
        if request.method == "GET" {
            switch path {
            case "/v1/diagnostics":
                guard request.isLoopback else { return .error("Diagnostics are available on this Mac only", status: 403) }
                guard let json = try? DiagnosticReport(node: diagnosticSnapshot()).json() else {
                    return .error("Could not prepare diagnostics", status: 503)
                }
                return HTTPResponse(status: 200, body: Data(json.utf8))
            case "/v1/health":
                return .json(["name": "FourthCiv", "protocol": "fourthciv/1", "status": status,
                              "events": String(events.count), "storageBytes": String(store.bytes),
                              "internetEnabled": String(settings.internetEnabled), "syncDataBytesToday": String(ledger.used())])
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
        guard !settings.paused else {
            diagnostics.record(.localRejected)
            return .error("Host has paused participation", status: 503)
        }
        guard request.headers["content-type"]?.lowercased().hasPrefix("application/json") == true else {
            return .error("Expected application/json", status: 400)
        }
        do {
            let event = try JSONDecoder().decode(Event.self, from: request.body)
            let inserted = try accept(event)
            if inserted { diagnostics.record(.localAccepted) }
            return .json(["id": event.id, "result": inserted ? "accepted" : "already-present"], status: inserted ? 201 : 200)
        } catch {
            diagnostics.record(.localRejected, failure: .capture(error))
            return .error(error.localizedDescription, status: 400)
        }
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
        defer { syncing = false; activeRequest = nil }
        let current = generation
        for peer in settings.peers {
            guard !settings.paused, !Task.isCancelled, generation == current else { return }
            let target = DiagnosticTarget(kind: .localPeer, index: (settings.peers.firstIndex(of: peer) ?? 0) + 1)
            diagnostics.record(.syncStarted, target: target)
            do {
                let base = try LocalEndpoint.validate(peer, allowLAN: settings.lanEnabled)
                guard !([endpoint] + lanEndpoints).contains(base.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))) else {
                    throw CivError("Choose a different node")
                }
                var offset = 0
                var received = 0
                for _ in 0..<2_001 {
                    guard !settings.paused, settings.peers.contains(peer), !Task.isCancelled, generation == current else { break }
                    let path = "/v1/events?offset=\(offset)"
                    let allowLAN = settings.lanEnabled
                    let requestData = self.requestData
                    let request = Task { try await requestData(base, path, nil, allowLAN, false, 4 * 1_024 * 1_024) }
                    activeRequest = request
                    let data = try await request.value
                    activeRequest = nil
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
                if generation == current && !settings.paused { diagnostics.record(.syncSucceeded, target: target, received: received) }
            } catch {
                if settings.peers.contains(peer) { peerStatus[peer] = error.localizedDescription }
                if generation == current { diagnostics.record(.syncFailed, target: target, failure: .capture(error)) }
            }
        }
        await syncRelays(generation: current)
    }

    private func maySync(_ relay: String, generation current: UUID) -> Bool {
        !settings.paused && settings.internetEnabled && settings.relays.contains(relay) && generation == current && !Task.isCancelled
    }

    private func transfer(_ base: URL, path: String, event: Event? = nil, maximum: Int) async throws -> Data {
        let upload = try event.map { try JSONEncoder().encode($0).count } ?? 0
        let limit = settings.dailySyncMiB * 1_024 * 1_024
        let responseLimit = min(maximum, ledger.remaining(limit: limit) - upload)
        guard responseLimit >= 128 else { throw CivError("Daily sync-data budget reached; it resets at midnight UTC") }
        let reservation = try ledger.reserve(upload + responseLimit, limit: limit)
        internetBytes = ledger.used()
        let requestData = self.requestData
        let request = Task { try await requestData(base, path, event, false, true, responseLimit) }
        activeRequest = request
        defer { activeRequest = nil; internetBytes = ledger.used() }
        let data: Data
        do { data = try await request.value }
        catch {
            // Unknown failures retain the reservation. Known transfer failures report consumed body bytes.
            if let failure = error as? TransferFailure { try ledger.settle(reservation, actual: upload + failure.receivedBytes) }
            throw error
        }
        try ledger.settle(reservation, actual: upload + data.count)
        return data
    }

    private func syncRelays(generation current: UUID) async {
        internetBytes = ledger.used()
        for relay in settings.relays {
            guard maySync(relay, generation: current) else { return }
            if let schedule = relaySchedule[relay], schedule.next > Date() { continue }
            let target = DiagnosticTarget(kind: .relay, index: (settings.relays.firstIndex(of: relay) ?? 0) + 1)
            relayObservations[relay] = RelayObservation(attempt: Date(), success: relayObservations[relay]?.success,
                                                        failure: relayObservations[relay]?.failure)
            diagnostics.record(.syncStarted, target: target)
            do {
                let base = try RelayEndpoint.validate(relay)
                let discovery = try JSONDecoder().decode(RelayDiscovery.self,
                    from: await transfer(base, path: "/.well-known/fourthciv", maximum: 16_384))
                try discovery.validate()
                guard maySync(relay, generation: current) else { return }
                var progress = ledger.progress(for: relay)
                if progress.epoch != discovery.epoch { progress = RelayProgress(); progress.epoch = discovery.epoch }
                var received = 0; var sent = 0; var more = false
                for _ in 0..<16 {
                    guard maySync(relay, generation: current) else { return }
                    let page = try JSONDecoder().decode(RelayPage.self,
                        from: await transfer(base, path: "/v1/events?offset=\(progress.offset)", maximum: 512 * 1_024))
                    guard maySync(relay, generation: current) else { return }
                    guard page.epoch == discovery.epoch, page.events.count <= 64,
                          page.cursor == progress.offset + page.events.count, page.cursor <= 2_000,
                          page.next == nil || (page.next == page.cursor && !page.events.isEmpty) else {
                        throw CivError("Invalid relay pagination or changed relay history")
                    }
                    for event in page.events {
                        if try accept(event) { received += 1 }
                        progress.acknowledged.insert(event.id)
                    }
                    progress.offset = page.cursor
                    try ledger.setProgress(progress, for: relay)
                    more = page.next != nil
                    if !more { break }
                }
                for event in events.filter({ !progress.acknowledged.contains($0.id) }).prefix(32) {
                    guard maySync(relay, generation: current) else { return }
                    let acknowledgement = try JSONDecoder().decode([String: String].self,
                        from: await transfer(base, path: "/v1/events", event: event, maximum: 4_096))
                    guard maySync(relay, generation: current) else { return }
                    guard acknowledgement["id"] == event.id,
                          ["accepted", "already-present"].contains(acknowledgement["result"] ?? "") else {
                        throw CivError("Relay did not acknowledge the signed event")
                    }
                    progress.acknowledged.insert(event.id); sent += 1
                    try ledger.setProgress(progress, for: relay)
                }
                more = more || events.contains { !progress.acknowledged.contains($0.id) }
                relaySchedule[relay] = (0, Date().addingTimeInterval(30))
                peerStatus[relay] = "Received \(received) · shared \(sent)" + (more ? " · more next sync" : " · up to date")
                relayObservations[relay]?.success = Date(); relayObservations[relay]?.failure = nil
                diagnostics.record(.syncSucceeded, target: target, received: received, sent: sent)
            } catch {
                guard maySync(relay, generation: current) else { return }
                let failures = min(5, (relaySchedule[relay]?.failures ?? 0) + 1)
                let delay = min(300, 15 * (1 << failures))
                relaySchedule[relay] = (failures, Date().addingTimeInterval(Double(delay)))
                peerStatus[relay] = error.localizedDescription + " · retry in \(delay)s"
                relayObservations[relay]?.failure = .capture(error)
                diagnostics.record(.syncFailed, target: target, failure: .capture(error))
            }
        }
    }
}
