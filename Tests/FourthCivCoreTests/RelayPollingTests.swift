import Foundation
import CryptoKit
import Testing
@testable import FourthCivCore

/// Advances only relay scheduling time. Real node persistence, event validation,
/// transfer accounting, pagination, and sync decisions run without sockets or sleeps.
@MainActor private final class PollingRelay {
    let endpoint = "https://polling.example"
    let epoch = UUID().uuidString
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    var events: [Event] = []
    var pageSize = 64
    var calls: [String] = []
    var unavailable = false

    func request(_ base: URL, _ path: String, _ event: Event?, _ lan: Bool, _ internet: Bool, _ maximum: Int) async throws -> Data {
        #expect(base.absoluteString == endpoint && internet && !lan)
        calls.append(path)
        if unavailable { throw TransferFailure(message: "Unavailable", receivedBytes: 0) }
        let data: Data
        if path == "/.well-known/fourthciv" {
            data = try JSONSerialization.data(withJSONObject: ["name": "Polling fixture", "protocol": "fourthciv/1",
                "visibility": "public", "capabilities": ["relay-sync-v1"], "epoch": epoch])
        } else if let event {
            try event.validate()
            if !events.contains(where: { $0.id == event.id }) { events.append(event) }
            data = try JSONEncoder().encode(["id": event.id, "result": "accepted"])
        } else {
            let offset = try #require(Int(path.split(separator: "=").last ?? ""))
            let page = Array(events.dropFirst(offset).prefix(pageSize))
            let cursor = offset + page.count
            data = try JSONSerialization.data(withJSONObject: [
                "events": JSONSerialization.jsonObject(with: JSONEncoder().encode(page)), "cursor": cursor,
                "next": cursor < events.count ? cursor as Any : NSNull(), "epoch": epoch])
        }
        #expect(data.count <= maximum)
        return data
    }
}

struct RelayPollingTests {
    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fourthciv-polling-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func community(_ title: String) throws -> Event {
        try Event.signed(kind: .community, key: .init(), attribution: Attribution(name: "Polling test"),
            title: title, body: "Local signed fixture; never published.")
    }

    @MainActor private func node(in directory: URL, relay: PollingRelay) throws -> CivNode {
        let node = try CivNode(directory: directory, request: relay.request)
        node.relaySchedulingNow = { relay.now }
        var settings = node.settings
        settings.internetEnabled = true; settings.relays = [relay.endpoint]
        try node.updateSettings(settings)
        return node
    }

    @Test @MainActor func firstSyncIsImmediateThenIdleRelaysWaitSixtySeconds() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let relay = PollingRelay()
        let node = try node(in: directory, relay: relay)
        let start = relay.now
        await node.sync()
        #expect(relay.calls.count == 2)
        #expect(node.hostConnection.phase == .synced)
        #expect(node.hostConnection.nextAttempt == start.addingTimeInterval(60))
        for seconds in [1, 30, 59] {
            relay.now = start.addingTimeInterval(Double(seconds))
            await node.sync()
            #expect(relay.calls.count == 2)
        }
        relay.now = start.addingTimeInterval(60)
        await node.sync()
        #expect(relay.calls.count == 4)
        #expect(node.hostConnection.nextAttempt == start.addingTimeInterval(120))
    }

    @Test(arguments: [false, true]) @MainActor func receivingOrSendingKeepsThirtySecondFollowUp(upload: Bool) async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let relay = PollingRelay()
        let event = try community(upload ? "Outgoing" : "Incoming")
        if upload { try JSONEncoder().encode([event]).write(to: directory.appendingPathComponent("events.json")) }
        else { relay.events = [event] }
        let node = try node(in: directory, relay: relay)
        let start = relay.now
        await node.sync()
        #expect(node.events == [event] && relay.events == [event])
        #expect(node.hostConnection.nextAttempt == start.addingTimeInterval(30))
        let calls = relay.calls.count
        relay.now = start.addingTimeInterval(29)
        await node.sync()
        #expect(relay.calls.count == calls)
        relay.now = start.addingTimeInterval(30)
        await node.sync()
        #expect(relay.calls.count == calls + 2)
        #expect(node.events == [event])
        // The following pass accepts/shares nothing new and can become idle.
        #expect(node.hostConnection.nextAttempt == start.addingTimeInterval(90))
    }

    @Test @MainActor func pendingPaginationKeepsThirtySecondsEvenWhenEventsAreAlreadyKnown() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let relay = PollingRelay()
        relay.events = try (0..<17).map { try community("Known community \($0)") }
        relay.pageSize = 1
        try JSONEncoder().encode(relay.events).write(to: directory.appendingPathComponent("events.json"))
        let node = try node(in: directory, relay: relay)
        // Previously uploaded events may already be acknowledged while the relay's
        // read cursor still needs to traverse them. No new receives/sends are needed.
        var progress = RelayProgress()
        progress.epoch = relay.epoch; progress.acknowledged = Set(relay.events.map(\.id))
        try node.ledger.setProgress(progress, for: relay.endpoint)
        let start = relay.now
        await node.sync()
        #expect(relay.calls.count == 17) // Discovery plus the bounded 16 pages.
        #expect(node.ledger.progress(for: relay.endpoint).offset == 16)
        #expect(node.sessionReceived == 0 && node.hostConnection.phase == .fetching)
        #expect(node.hostConnection.nextAttempt == start.addingTimeInterval(30))
        relay.now = start.addingTimeInterval(29)
        await node.sync()
        #expect(relay.calls.count == 17)
        relay.now = start.addingTimeInterval(30)
        await node.sync()
        #expect(relay.calls.count == 19)
        #expect(node.ledger.progress(for: relay.endpoint).offset == 17)
        #expect(node.hostConnection.phase == .synced)
        #expect(node.hostConnection.nextAttempt == start.addingTimeInterval(90))
    }

    @Test @MainActor func failureBackoffRemainsBoundedAndSuccessResetsIt() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let relay = PollingRelay(); relay.unavailable = true
        let node = try node(in: directory, relay: relay)
        for delay in [30, 60, 120, 240, 300, 300] {
            let attempt = relay.now
            await node.sync()
            let calls = relay.calls.count
            #expect(node.hostConnection.phase == .retrying)
            #expect(node.hostConnection.nextAttempt == attempt.addingTimeInterval(Double(delay)))
            relay.now = attempt.addingTimeInterval(Double(delay - 1))
            await node.sync()
            #expect(relay.calls.count == calls)
            relay.now = attempt.addingTimeInterval(Double(delay))
        }
        relay.unavailable = false
        await node.sync()
        #expect(node.hostConnection.phase == .synced)
        #expect(node.diagnosticSnapshot().relays[0].consecutiveFailures == 0)
        #expect(node.hostConnection.nextAttempt == relay.now.addingTimeInterval(60))
        relay.now = relay.now.addingTimeInterval(60); relay.unavailable = true
        await node.sync()
        #expect(node.hostConnection.nextAttempt == relay.now.addingTimeInterval(30))
        #expect(node.diagnosticSnapshot().relays[0].consecutiveFailures == 1)
    }
}
