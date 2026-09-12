import Foundation
import Combine
import Testing
@testable import FourthCivCore

@MainActor private final class HostConnectionFixture {
    var epoch = UUID().uuidString
    var events: [String: [Event]] = [:]
    var failing = Set<String>()
    var malformed = false
    var pageSize = 64
    var calls = 0
    var onRequest: (() throws -> Void)?

    func request(_ base: URL, _ path: String, _ event: Event?, _ lan: Bool, _ internet: Bool, _ maximum: Int) async throws -> Data {
        calls += 1
        try onRequest?()
        try Task.checkCancellation()
        let host = base.host!
        if failing.contains(host) {
            throw TransferFailure(message: "Unavailable", receivedBytes: 0, diagnostic: DiagnosticFailure(kind: .http, httpStatus: 503))
        }
        if path == "/.well-known/fourthciv" {
            return try JSONSerialization.data(withJSONObject: ["name": "Test relay", "protocol": "fourthciv/1",
                "visibility": "public", "capabilities": ["relay-sync-v1"], "epoch": epoch])
        }
        if let event {
            if !(events[host] ?? []).contains(where: { $0.id == event.id }) { events[host, default: []].append(event) }
            return try JSONEncoder().encode(["id": event.id, "result": "accepted"])
        }
        let offset = Int(path.split(separator: "=").last!)!
        let all = events[host] ?? []
        let page = Array(all.dropFirst(offset).prefix(pageSize))
        let cursor = offset + page.count
        let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(page))
        return try JSONSerialization.data(withJSONObject: ["events": body, "cursor": cursor + (malformed ? 1 : 0),
            "next": cursor < all.count ? cursor as Any : NSNull(), "epoch": epoch])
    }
}

struct HostConnectionTests {
    private func directory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func town(_ name: String) throws -> Event {
        try Event.signed(kind: .community, key: .init(), attribution: Attribution(name: "Fixture"), title: name, body: "Fixture")
    }

    @Test @MainActor func enabledIsNotSuccessAndExchangePublishesVerifiedProgress() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = HostConnectionFixture()
        let event = try town("Received conversation")
        fixture.events["a.example"] = [event]
        let node = try CivNode(directory: dir, request: fixture.request)
        #expect(node.hostConnection.phase == .internetDisabled)
        var settings = node.settings; settings.internetEnabled = true; settings.relays = ["https://a.example"]
        try node.updateSettings(settings)
        #expect(node.hostConnection.phase == .fetching && node.hostConnection.lastSuccess == nil)
        #expect(node.hostConnection.title == "Waiting to sync")
        var published: [HostConnectionStatus] = []
        let subscription = node.$hostConnection.sink { published.append($0) }
        await node.sync()
        #expect(node.events == [event])
        #expect(node.hostConnection.phase == .synced && node.hostConnection.lastSuccess != nil)
        #expect(node.hostConnection.successfulRelayCount == 1 && node.hostConnection.failedRelayCount == 0)
        #expect(published.contains { $0.phase == .fetching && $0.isSyncing && $0.title == "Fetching conversations" })
        #expect(published.contains { $0.phase == .synced && $0.lastSuccess != nil })
        #expect(!node.hostConnection.isSyncing)
        #expect(node.diagnosticSnapshot().relays[0].lastSuccess == node.hostConnection.lastSuccess)
        #expect(node.diagnosticSnapshot().status == node.status)
        subscription.cancel()
    }

    @Test @MainActor func failedExchangeRetainsHistoricalSuccessAndRespectsBackoff() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = HostConnectionFixture()
        let node = try CivNode(directory: dir, request: fixture.request)
        var settings = node.settings; settings.internetEnabled = true; settings.relays = ["https://a.example"]
        try node.updateSettings(settings); await node.sync()
        let lastSuccess = try #require(node.hostConnection.lastSuccess)
        fixture.failing = ["a.example"]
        try node.togglePause()
        #expect(node.hostConnection.phase == .paused && node.hostConnection.nextAttempt == nil)
        #expect(node.hostConnection.lastSuccess == lastSuccess)
        try node.togglePause()
        #expect(node.hostConnection.phase == .fetching && node.hostConnection.lastSuccess == lastSuccess)
        await node.sync()
        #expect(node.hostConnection.phase == .retrying && node.hostConnection.lastSuccess == lastSuccess)
        #expect(node.hostConnection.successfulRelayCount == 0 && node.hostConnection.failedRelayCount == 1)
        #expect(try #require(node.hostConnection.nextAttempt) > Date())
        let calls = fixture.calls
        await node.sync()
        #expect(fixture.calls == calls && node.hostConnection.phase == .retrying)
        fixture.failing = []
        try node.togglePause(); try node.togglePause(); await node.sync()
        #expect(node.hostConnection.phase == .synced)
        #expect(try #require(node.hostConnection.lastSuccess) >= lastSuccess)
    }

    @Test @MainActor func oneWorkingRelayDoesNotConcealOtherFailuresOrIncompleteHistory() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = HostConnectionFixture(); fixture.failing = ["b.example"]
        fixture.events["a.example"] = [try town("Available conversation")]
        let node = try CivNode(directory: dir, request: fixture.request)
        var settings = node.settings; settings.internetEnabled = true; settings.relays = ["https://a.example", "https://b.example"]
        try node.updateSettings(settings); await node.sync()
        #expect(node.events.count == 1)
        #expect(node.hostConnection.phase == .partiallyConnected && node.hostConnection.lastSuccess != nil)
        #expect(node.hostConnection.failedRelayCount == 1 && node.hostConnection.successfulRelayCount == 1)
        #expect(node.hostConnection.nextAttempt == node.diagnosticSnapshot().relays[1].nextAttempt)

        fixture.failing = []; fixture.pageSize = 1
        fixture.events["c.example"] = try (0..<17).map { try town("Conversation \($0)") }
        settings.relays = ["https://c.example"]; try node.updateSettings(settings)
        #expect(node.hostConnection.lastSuccess == nil) // A removed relay cannot establish the new connection.
        await node.sync()
        #expect(node.hostConnection.phase == .fetching && node.hostConnection.lastSuccess != nil)
        #expect(node.events.count == 17) // The existing conversation and 16 of the 17 incoming conversations.
        try node.togglePause(); try node.togglePause(); await node.sync()
        #expect(node.hostConnection.phase == .synced && node.events.count == 18)
    }

    @Test @MainActor func emptyDisabledPausedAndDataLimitedStatesDoNotClaimConnection() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = HostConnectionFixture()
        let node = try CivNode(directory: dir, request: fixture.request)
        var settings = node.settings; settings.internetEnabled = true; settings.relays = []
        try node.updateSettings(settings); await node.sync()
        #expect(node.hostConnection.phase == .noRelays && fixture.calls == 0)
        settings.relays = ["https://a.example"]; settings.dailySyncMiB = 1
        try node.updateSettings(settings)
        _ = try node.ledger.reserve(node.ledger.remaining(limit: 1_024 * 1_024), limit: 1_024 * 1_024)
        await node.sync()
        #expect(node.hostConnection.phase == .dataLimitReached && fixture.calls == 0)
        #expect(node.hostConnection.lastSuccess == nil && node.hostConnection.nextAttempt != nil)
        settings.paused = true; try node.updateSettings(settings)
        #expect(node.hostConnection.phase == .paused && node.hostConnection.nextAttempt == nil)
        settings.paused = false; settings.internetEnabled = false; try node.updateSettings(settings)
        #expect(node.hostConnection.phase == .internetDisabled)
        settings.internetEnabled = true; settings.dailySyncMiB = 2; try node.updateSettings(settings)
        await node.sync()
        #expect(node.hostConnection.phase == .synced)
    }

    @Test @MainActor func interruptedAndInvalidResponsesNeverBecomeSuccessfulSyncs() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = HostConnectionFixture()
        let node = try CivNode(directory: dir, request: fixture.request)
        var settings = node.settings; settings.internetEnabled = true; settings.relays = ["https://a.example"]
        try node.updateSettings(settings)
        fixture.onRequest = { [weak node] in try node?.togglePause() }
        await node.sync()
        #expect(node.hostConnection.phase == .paused && node.hostConnection.lastSuccess == nil)
        #expect(!node.hostConnection.isSyncing)
        fixture.onRequest = nil; fixture.malformed = true
        try node.togglePause(); await node.sync()
        #expect(node.hostConnection.phase == .retrying && node.hostConnection.lastSuccess == nil)
        #expect(node.hostConnection.failedRelayCount == 1)
    }

    @Test @MainActor func remainingAllowanceMustFitTheNextMessageBeforeReportingSync() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let event = try Event.signed(kind: .community, key: .init(), attribution: Attribution(name: "Fixture"),
            title: "Waiting to share", body: String(repeating: "x", count: 6_000))
        try JSONEncoder().encode([event]).write(to: dir.appendingPathComponent("events.json"))
        let fixture = HostConnectionFixture()
        let node = try CivNode(directory: dir, request: fixture.request)
        var settings = node.settings; settings.internetEnabled = true; settings.dailySyncMiB = 1; settings.relays = ["https://a.example"]
        try node.updateSettings(settings)
        _ = try node.ledger.reserve(1_024 * 1_024 - 4_000, limit: 1_024 * 1_024)
        await node.sync()
        #expect(node.ledger.remaining(limit: 1_024 * 1_024) > 128)
        #expect(node.hostConnection.phase == .dataLimitReached && node.hostConnection.lastSuccess == nil)
        #expect(fixture.events["a.example"] == nil)
    }

    @Test @MainActor func storageFailureDoesNotAppearAsSuccessfulReceiptAndCanRecover() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = HostConnectionFixture(); fixture.events["a.example"] = [try town("Too large for available space")]
        let node = try CivNode(directory: dir, request: fixture.request)
        var settings = node.settings; settings.internetEnabled = true; settings.relays = ["https://a.example"]
        try node.updateSettings(settings)
        node.store.limitBytes = 1 // Exercise the real insertion failure without a large fixture.
        await node.sync()
        #expect(node.hostConnection.phase == .storageLimitReached && node.hostConnection.lastSuccess == nil)
        #expect(node.events.isEmpty)
        try node.togglePause(); try node.togglePause() // Reapplies the configured storage limit.
        await node.sync()
        #expect(node.hostConnection.phase == .synced && node.events.count == 1)
    }

    @Test @MainActor func reopeningKeepsConversationsWithoutClaimingAnExchangeInTheNewSession() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = HostConnectionFixture(); fixture.events["a.example"] = [try town("Saved conversation")]
        var node: CivNode? = try CivNode(directory: dir, request: fixture.request)
        var settings = node!.settings; settings.internetEnabled = true; settings.relays = ["https://a.example"]
        try node!.updateSettings(settings); await node!.sync()
        #expect(node!.hostConnection.phase == .synced)
        node = nil
        node = try CivNode(directory: dir, request: fixture.request)
        #expect(node!.events.count == 1)
        #expect(node!.hostConnection.phase == .fetching && node!.hostConnection.lastSuccess == nil)
        node = nil
    }
}
