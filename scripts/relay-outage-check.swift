// Compiled with the production FourthCivCore sources by relay/test/outage.mjs.
// The injected transport maps one test hostname to a loopback HTTP relay.
// No public relay, TLS trust setting, or installed-app data is used.
import Foundation
import CryptoKit

@MainActor private final class OutageTransport {
    static let relay = "https://outage.example"
    let endpoint: URL
    var calls = 0
    var failures = 0

    init(endpoint: URL) { self.endpoint = endpoint }

    func request(_ base: URL, _ path: String, _ event: Event?, _ lan: Bool,
                 _ internet: Bool, _ maximum: Int) async throws -> Data {
        guard base.absoluteString == Self.relay, internet, !lan else {
            throw CivError("Unexpected test destination")
        }
        calls += 1
        do {
            return try await LocalClient.request(base: endpoint, path: path, event: event,
                                                 allowLAN: false, allowInternet: false,
                                                 maxResponseBytes: maximum)
        } catch {
            failures += 1
            throw error
        }
    }
}

@main private struct RelayOutageCheck {
    @MainActor static func main() async {
        do { try await run() }
        catch {
            FileHandle.standardError.write(Data("FAIL: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw CivError(message) }
    }

    @MainActor static func eventually(_ description: String, seconds: Double,
                                      _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw CivError("Timed out: \(description)")
    }

    static func say(_ message: String) {
        FileHandle.standardOutput.write(Data("\(message)\n".utf8))
    }

    static func readEvents(_ endpoint: URL) async throws -> [Event] {
        let data = try await LocalClient.request(base: endpoint, path: "/v1/events?offset=0")
        let page = try JSONDecoder().decode(EventPage.self, from: data)
        try check(page.next == nil, "Unexpected pagination in small test fixture")
        for event in page.events { try event.validate() }
        return page.events
    }

    @MainActor static func run() async throws {
        let args = CommandLine.arguments
        guard args.count == 7, let relayURL = URL(string: args[1]),
              relayURL.scheme == "http", relayURL.host == "127.0.0.1",
              let portA = UInt16(args[3]), let portB = UInt16(args[4]),
              portA > 0, portB > 0, portA != portB else {
            throw CivError("Expected loopback relay, isolated directory, two ports, control file, and report path")
        }
        let root = URL(fileURLWithPath: args[2], isDirectory: true)
        let control = URL(fileURLWithPath: args[5])
        let report = URL(fileURLWithPath: args[6])
        let transportA = OutageTransport(endpoint: relayURL)
        let transportB = OutageTransport(endpoint: relayURL)
        let nodeA = try CivNode(directory: root.appendingPathComponent("node-a"), port: portA, request: transportA.request)
        let nodeB = try CivNode(directory: root.appendingPathComponent("node-b"), port: portB, request: transportB.request)
        for node in [nodeA, nodeB] {
            var settings = node.settings
            settings.internetEnabled = true
            settings.relays = [OutageTransport.relay]
            try node.updateSettings(settings)
        }
        defer { nodeA.stop(); nodeB.stop() }
        try nodeA.start(); try nodeB.start()
        try await eventually("node listeners", seconds: 5) { nodeA.listening && nodeB.listening }
        let endpointA = URL(string: nodeA.endpoint)!
        let endpointB = URL(string: nodeB.endpoint)!
        let key = Curve25519.Signing.PrivateKey()
        let attribution = Attribution(name: "Isolated outage fixture", runtime: "Automated integration check")
        let town = try Event.signed(kind: .community, key: key, attribution: attribution,
                                    title: "Relay outage check", body: "Temporary test data")
        let earlier = try Event.signed(kind: .message, key: key, attribution: attribution,
                                       community: town.id, body: "Saved before the relay outage")
        for event in [town, earlier] {
            _ = try await LocalClient.request(base: endpointA, path: "/v1/events", event: event)
        }
        await nodeA.sync(); await nodeB.sync()
        try check(nodeB.events == [town, earlier], "Baseline failed to reach receiver")
        say("PASS: two native nodes and the real PostgreSQL relay share the signed baseline")

        try Data("{\"unavailable\":true}".utf8).write(to: control, options: .atomic)
        try await eventually("both nodes observing relay 503", seconds: 45) {
            transportA.failures > 0 && transportB.failures > 0
        }
        for node in [nodeA, nodeB] {
            try check(node.peerStatus[OutageTransport.relay]?.contains("retry in 30s") == true,
                      "Expected the first retry delay after relay failure")
        }
        let queued = try Event.signed(kind: .message, key: key, attribution: attribution,
                                      community: town.id, parent: earlier.id,
                                      body: "Queued while the relay returns HTTP 503")
        let receiptData = try await LocalClient.request(base: endpointA, path: "/v1/events", event: queued)
        let receipt = try JSONDecoder().decode([String: String].self, from: receiptData)
        try check(receipt["id"] == queued.id && receipt["result"] == "accepted", "Local queue rejected the message")
        let saved = try JSONDecoder().decode([Event].self, from: Data(contentsOf: nodeA.directory.appendingPathComponent("events.json")))
        try check(saved.filter { $0.id == queued.id } == [queued], "Queued event is not durable")
        let offlineHistory = try await readEvents(endpointB)
        try check(offlineHistory == [town, earlier], "Receiver history changed during the outage")
        let calls = transportA.calls + transportB.calls
        await nodeA.sync(); await nodeB.sync()
        try check(transportA.calls + transportB.calls == calls, "Retry backoff allowed an immediate extra transfer")
        say("PASS: HTTP 503 preserves readable history, accepts a durable local post, and enforces retry backoff")

        let restored = Date()
        try Data("{\"unavailable\":false}".utf8).write(to: control, options: .atomic)
        // No sync(), restart, or settings change after restoration: use the real node timers.
        try await eventually("automatic receiver catch-up", seconds: 100) {
            nodeB.events.contains { $0.id == queued.id }
        }
        let expected = [town, earlier, queued]
        for endpoint in [endpointA, endpointB, relayURL] {
            let events = try await readEvents(endpoint)
            try check(events == expected, "Signed event envelopes or insertion order differ after recovery")
            try check(events.filter { $0.id == queued.id }.count == 1, "Queued event stored more than once")
        }
        let seconds = Date().timeIntervalSince(restored)
        let result: [String: Any] = [
            "passed": true, "checkedAt": ISO8601DateFormatter().string(from: Date()),
            "scope": "Two production CivNode instances and real relay handler/PostgreSQL storage over loopback HTTP; test-only destination mapping excludes public TLS and physical-Mac validation.",
            "relayFailure": "HTTP 503 from the production handler while its store is unavailable",
            "oldHistoryReadableDuringOutage": true, "newPostDurableDuringOutage": true,
            "retryBackoffEnforced": true, "automaticRecoveryWithoutRestartOrSettingsChange": true,
            "recoverySeconds": seconds, "matchingSignedEventsPerStore": expected.count,
            "queuedEventID": queued.id, "queuedEventOccurrencesPerStore": 1,
            "relayFailuresObservedByNodes": [transportA.failures, transportB.failures]
        ]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: report, options: .atomic)
        say("PASS: automatic recovery in \(String(format: "%.1f", seconds))s; all three stores contain the exact queued event once")
    }
}
