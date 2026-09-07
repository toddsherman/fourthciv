import Foundation
import CryptoKit
import Testing
@testable import FourthCivCore

struct DiagnosticsTests {
    private func directory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test @MainActor func failureRecoveryReportsFactsWithoutPrivateContentAndSurvivesRestart() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let secret = "PRIVATE-SENTINEL /Users/person/key.json https://secret.example/token?auth=credential 192.168.2.44"
        let event = try Event.signed(kind: .community, key: .init(), attribution: Attribution(name: secret), title: "Private fixture", body: secret)
        let epoch = UUID().uuidString
        var failing = true
        var requests = 0
        let transport: NodeRequest = { _, path, _, _, _, _ in
            requests += 1
            if failing { throw TransferFailure(message: secret, receivedBytes: 0, diagnostic: DiagnosticFailure(kind: .http, httpStatus: 503)) }
            if path == "/.well-known/fourthciv" {
                return try JSONSerialization.data(withJSONObject: ["name": "Relay", "protocol": "fourthciv/1", "visibility": "public", "capabilities": ["relay-sync-v1"], "epoch": epoch])
            }
            let events = try JSONSerialization.jsonObject(with: JSONEncoder().encode([event]))
            return try JSONSerialization.data(withJSONObject: ["events": events, "cursor": 1, "next": NSNull(), "epoch": epoch])
        }
        var node: CivNode? = try CivNode(directory: dir, request: transport)
        var settings = node!.settings; settings.internetEnabled = true; settings.relays = ["https://private-relay.example"]
        try node!.updateSettings(settings)
        #expect(node!.diagnosticSnapshot().relays[0].lastSuccess == nil)
        await node!.sync()
        let failure = node!.diagnosticSnapshot().relays[0]
        #expect(failure.lastAttempt != nil && failure.lastSuccess == nil)
        #expect(failure.lastFailure?.httpStatus == 503 && failure.consecutiveFailures == 1)
        #expect(try #require(failure.nextAttempt) > Date())
        await node!.sync(); #expect(requests == 1)
        failing = false
        try node!.togglePause(); try node!.togglePause() // Existing settings behavior clears retry scheduling.
        await node!.sync()
        let success = node!.diagnosticSnapshot().relays[0]
        #expect(success.lastSuccess != nil && success.lastFailure == nil)
        #expect(success.pendingEvents == 0 && success.acknowledgedEvents == 1)
        #expect(node!.events == [event])
        let report = try DiagnosticReport(node: node!.diagnosticSnapshot()).json()
        let disk = try String(contentsOf: dir.appendingPathComponent("diagnostics.json"), encoding: .utf8)
        for value in ["PRIVATE-SENTINEL", "private-relay.example", "192.168.2.44", "/Users/", "credential", event.author, event.id, event.signature, event.title] {
            #expect(!report.contains(value)); #expect(!disk.contains(value))
        }
        #expect(report.contains("503") && report.contains("syncSucceeded"))
        let previousSession = node!.diagnostics.session
        node = nil
        node = try CivNode(directory: dir, request: transport)
        #expect(node!.diagnostics.entries.contains { $0.session == previousSession && $0.action == .syncFailed })
        #expect(node!.diagnosticSnapshot().relays[0].lastSuccess == nil) // Do not imply a successful sync in this new session.
        #expect(node!.events == [event])
        node = nil
    }

    @Test @MainActor func boundedPrivateHistoryAndDamagedLogsDoNotBlockTheNode() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let log = DiagnosticLog(directory: dir)
        for _ in 0..<110 { log.record(.syncStarted) }
        #expect(log.entries.count == 100)
        let file = dir.appendingPathComponent("diagnostics.json")
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
        #expect(DiagnosticLog(directory: dir).entries.count == 100)
        try Data("not json".utf8).write(to: file)
        let node = try CivNode(directory: dir)
        #expect(node.diagnostics.recoveredUnreadableHistory)
        #expect(node.diagnostics.saved && node.events.isEmpty)
        #expect(try JSONDecoder().decode([DiagnosticEntry].self, from: Data(contentsOf: file)).count == 1)
    }

    @Test @MainActor func oldHistoryExpiresAndStorageFailureRemainsReportable() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let old = DiagnosticEntry(at: Date().addingTimeInterval(-90_000), session: UUID(), configuration: 0,
                                  action: .syncSucceeded, target: nil, failure: nil, received: 0, sent: 0)
        let file = dir.appendingPathComponent("diagnostics.json")
        try JSONEncoder().encode([old]).write(to: file)
        let log = DiagnosticLog(directory: dir)
        #expect(log.entries.isEmpty)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        log.record(.nodeOpened)
        #expect(!log.saved && log.entries.count == 1)
    }

    @Test func errorCategoriesDoNotCopyDescriptionsAndNamesKeepSigningKeys() throws {
        let secret = "secret-token /Users/private/name"
        do {
            _ = try JSONDecoder().decode(NodeSettings.self, from: Data("invalid json".utf8))
            Issue.record("Invalid fixture unexpectedly decoded")
        } catch { #expect(DiagnosticFailure.capture(error).kind == .invalidData) }
        let network = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: [NSLocalizedDescriptionKey: secret])
        let error = DiagnosticFailure.capture(network)
        #expect(error.kind == .network && error.networkCode == NSURLErrorTimedOut)
        #expect(!String(decoding: try JSONEncoder().encode(error), as: UTF8.self).contains(secret))
        #expect(DiagnosticFailure.capture(CivError("Storage budget reached; increase it in host settings")).kind == .storageBudget)
        #expect(DiagnosticFailure.capture(CivError("Daily sync-data budget reached; it resets at midnight UTC")).kind == .syncBudget)
        let key = Curve25519.Signing.PrivateKey()
        let name = try AgentName.resolve(nil, publicKey: key.publicKey.rawRepresentation)
        #expect(try name == AgentName.resolve(" \n", publicKey: key.publicKey.rawRepresentation))
        #expect(try AgentName.resolve("Chosen name", publicKey: key.publicKey.rawRepresentation) == "Chosen name")
        let original = try Event.signed(kind: .community, key: key, attribution: Attribution(name: name), title: "Test", body: "Test")
        let renamed = try Event.signed(kind: .message, key: key, attribution: Attribution(name: "New name"), community: original.id, body: "Test")
        try original.validate(); try renamed.validate()
        #expect(original.author == renamed.author && original.attribution.name == name)
        #expect(throws: (any Error).self) { try AgentName.resolve(String(repeating: "é", count: 81), publicKey: key.publicKey.rawRepresentation) }
    }
}
