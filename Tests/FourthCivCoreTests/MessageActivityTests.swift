import Foundation
import Combine
import CryptoKit
import Testing
@testable import FourthCivCore

/// This fixture never opens a socket or contacts a public relay.
@MainActor private final class MessageActivityRelay {
    var epoch = UUID().uuidString
    var events: [Event] = []
    var acknowledgement = "accepted"
    var wrongAcknowledgementID = false
    var failMessageUpload = false
    var holdMessageAcknowledgement = false
    var waitingForAcknowledgement = false
    var onPage: (() throws -> Void)?
    var onMessageUpload: (() throws -> Void)?
    var calls = 0
    var uploads: [Event] = []
    private var pendingAcknowledgement: CheckedContinuation<Void, Never>?

    func releaseAcknowledgement() {
        pendingAcknowledgement?.resume()
        pendingAcknowledgement = nil
    }

    func request(_ base: URL, _ path: String, _ event: Event?, _ lan: Bool, _ internet: Bool, _ maximum: Int) async throws -> Data {
        calls += 1
        if path == "/.well-known/fourthciv" {
            return try JSONSerialization.data(withJSONObject: ["name": "Message activity fixture", "protocol": "fourthciv/1",
                "visibility": "public", "capabilities": ["relay-sync-v1"], "epoch": epoch])
        }
        if let event {
            uploads.append(event)
            if event.kind == .message {
                try onMessageUpload?()
                if failMessageUpload { throw TransferFailure(message: "Fixture unavailable", receivedBytes: 0) }
                if holdMessageAcknowledgement {
                    waitingForAcknowledgement = true
                    await withCheckedContinuation { pendingAcknowledgement = $0 }
                }
            }
            return try JSONEncoder().encode(["id": wrongAcknowledgementID && event.kind == .message ? "wrong-id" : event.id,
                "result": event.kind == .message ? acknowledgement : "accepted"])
        }
        try onPage?()
        let offset = try #require(Int(path.split(separator: "=").last ?? ""))
        let page = Array(events.dropFirst(offset).prefix(64))
        let cursor = offset + page.count
        return try JSONSerialization.data(withJSONObject: [
            "events": JSONSerialization.jsonObject(with: JSONEncoder().encode(page)), "cursor": cursor,
            "next": cursor < events.count ? cursor as Any : NSNull(), "epoch": epoch])
    }
}

struct MessageActivityTests {
    private func directory(events: [Event] = []) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fourthciv-message-activity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !events.isEmpty {
            try JSONEncoder().encode(events).write(to: directory.appendingPathComponent("events.json"))
        }
        return directory
    }

    private func conversation(messageCount: Int = 1) throws -> [Event] {
        let key = Curve25519.Signing.PrivateKey()
        let attribution = Attribution(name: "Local message fixture")
        let community = try Event.signed(kind: .community, key: key, attribution: attribution,
            title: "Activity fixture", body: "Never published.")
        return [community] + (try (0..<messageCount).map { position in
            try Event.signed(kind: .message, key: key, attribution: attribution, community: community.id,
                body: "Saved fixture message \(position)")
        })
    }

    @MainActor private func enable(_ node: CivNode) throws {
        var settings = node.settings
        settings.internetEnabled = true
        settings.relays = ["https://message-activity.example"]
        try node.updateSettings(settings)
    }

    @Test @MainActor func onlyNewSavedMessagesAdvanceActivityAndLoadingHistoryDoesNotReplayIt() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let events = try conversation(messageCount: 3)
        let relay = MessageActivityRelay(); relay.events = [events[0]]
        var node: CivNode? = try CivNode(directory: directory, request: relay.request)
        try enable(node!)
        await node!.sync()
        #expect(node!.messageActivityCount == 0)
        #expect(node!.sessionReceived == 1 && node!.lastActivity != nil) // Keep existing event-wide semantics.

        var published: [UInt64] = []
        let subscription = node!.$messageActivityCount.sink { count in
            published.append(count)
            // A subscriber must never see activity before the message is saved.
            let saved = try? JSONDecoder().decode([Event].self, from: Data(contentsOf: directory.appendingPathComponent("events.json")))
            #expect(saved?.filter { $0.kind == .message }.count == Int(count))
        }
        relay.events = events
        try node!.togglePause(); try node!.togglePause()
        await node!.sync()
        #expect(node!.events == events && node!.messageActivityCount == 3)
        #expect(published == [0, 1, 2, 3])
        #expect(node!.sessionReceived == events.count)
        let lastActivity = node!.lastActivity

        // A new remote history epoch redelivers exact duplicates. Neither receipt
        // nor a later empty successful check should look like new message movement.
        relay.epoch = UUID().uuidString
        try node!.togglePause(); try node!.togglePause(); await node!.sync()
        try node!.togglePause(); try node!.togglePause(); await node!.sync()
        #expect(node!.messageActivityCount == 3 && published == [0, 1, 2, 3])
        #expect(node!.lastActivity == lastActivity && node!.sessionReceived == events.count)
        #expect(node!.hostConnection.phase == .synced)
        subscription.cancel()

        node = nil
        node = try CivNode(directory: directory, request: relay.request)
        #expect(node!.events == events && node!.messageActivityCount == 0)
        #expect(node!.lastActivity == nil && node!.sessionReceived == 0)
        await node!.sync()
        #expect(node!.messageActivityCount == 0)
    }

    @Test @MainActor func rejectedIncomingMessagesDoNotAdvanceActivity() async throws {
        let events = try conversation()
        for storageFailure in [false, true] {
            let directory = try directory(events: [events[0]])
            defer { try? FileManager.default.removeItem(at: directory) }
            let relay = MessageActivityRelay()
            if storageFailure {
                relay.events = events
            } else {
                var fields = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(events[1])) as? [String: Any])
                fields["body"] = "Tampered message"
                let invalid = try JSONDecoder().decode(Event.self, from: JSONSerialization.data(withJSONObject: fields))
                relay.events = [events[0], invalid]
            }
            let node = try CivNode(directory: directory, request: relay.request)
            try enable(node)
            if storageFailure { node.store.limitBytes = node.store.bytes }
            await node.sync()
            #expect(node.messageActivityCount == 0 && node.events == [events[0]])
            #expect(node.lastActivity == nil && node.sessionReceived == 0)
            #expect(node.hostConnection.phase == (storageFailure ? .storageLimitReached : .retrying))
        }
    }

    @Test @MainActor func outgoingMessageLightsOnlyAfterItsNewAcceptanceArrives() async throws {
        let events = try conversation()
        let directory = try directory(events: events); defer { try? FileManager.default.removeItem(at: directory) }
        let relay = MessageActivityRelay(); relay.holdMessageAcknowledgement = true
        let node = try CivNode(directory: directory, request: relay.request)
        try enable(node)
        let syncing = Task { await node.sync() }
        defer { relay.releaseAcknowledgement(); syncing.cancel() }
        for _ in 0..<100 where !relay.waitingForAcknowledgement { try await Task.sleep(for: .milliseconds(10)) }
        try #require(relay.waitingForAcknowledgement)
        #expect(relay.uploads == events) // Community ACK already arrived; message ACK is still pending.
        #expect(node.messageActivityCount == 0)
        #expect(node.lastActivity == nil && node.sessionReceived == 0)
        #expect(!node.ledger.progress(for: "https://message-activity.example").acknowledged.contains(events[1].id))
        relay.releaseAcknowledgement()
        await syncing.value
        #expect(node.messageActivityCount == 1 && node.hostConnection.phase == .synced)
        #expect(node.lastActivity == nil && node.sessionReceived == 0)
        #expect(node.ledger.progress(for: "https://message-activity.example").acknowledged.contains(events[1].id))
        try node.togglePause(); try node.togglePause(); await node.sync()
        #expect(node.messageActivityCount == 1 && relay.uploads == events)
    }

    @Test @MainActor func duplicateFailedAndInvalidAcknowledgementsDoNotAdvanceActivity() async throws {
        let events = try conversation()
        for outcome in ["already-present", "wrong-id", "invalid-result", "failure"] {
            let directory = try directory(events: events)
            defer { try? FileManager.default.removeItem(at: directory) }
            let relay = MessageActivityRelay()
            relay.acknowledgement = outcome == "already-present" ? outcome : outcome == "invalid-result" ? "unknown" : "accepted"
            relay.wrongAcknowledgementID = outcome == "wrong-id"
            relay.failMessageUpload = outcome == "failure"
            let node = try CivNode(directory: directory, request: relay.request)
            try enable(node)
            relay.onMessageUpload = { [weak node] in #expect(node?.messageActivityCount == 0) }
            await node.sync()
            #expect(relay.uploads == events)
            #expect(node.messageActivityCount == 0 && node.lastActivity == nil)
            #expect(node.hostConnection.phase == (outcome == "already-present" ? .synced : .retrying))
            #expect(node.ledger.progress(for: "https://message-activity.example").acknowledged.contains(events[1].id) == (outcome == "already-present"))
        }
    }

    @Test @MainActor func pausingBeforeOrDuringTransfersDoesNotGenerateActivity() async throws {
        let events = try conversation()
        for receiving in [false, true] {
            let directory = try directory(events: receiving ? [] : events)
            defer { try? FileManager.default.removeItem(at: directory) }
            let relay = MessageActivityRelay(); relay.events = receiving ? events : []
            let node = try CivNode(directory: directory, request: relay.request)
            try enable(node)
            try node.togglePause(); await node.sync()
            #expect(relay.calls == 0 && node.messageActivityCount == 0)
            try node.togglePause()
            if receiving { relay.onPage = { [weak node] in try node?.togglePause() } }
            else { relay.onMessageUpload = { [weak node] in try node?.togglePause() } }
            await node.sync()
            #expect(node.settings.paused && node.hostConnection.phase == .paused)
            #expect(node.messageActivityCount == 0 && node.lastActivity == nil)
            #expect(node.events == (receiving ? [] : events))
        }
    }
}
