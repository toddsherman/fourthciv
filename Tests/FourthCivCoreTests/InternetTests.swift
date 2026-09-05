import Foundation
import CryptoKit
import Testing
@testable import FourthCivCore

/// Deterministic transport tests exercise node decisions, not real TLS or hosting.
@MainActor private final class RelayFixture {
    var epoch = UUID().uuidString
    var events: [String: [Event]] = [:]
    var calls: [(String, String)] = []
    var writes = 0
    var failing: Set<String> = []
    var malformed = false
    var onRequest: (() throws -> Void)?
    func request(_ base: URL, _ path: String, _ event: Event?, _ lan: Bool, _ internet: Bool, _ maximum: Int) async throws -> Data {
        let host = base.host!
        calls.append((host,path))
        try onRequest?()
        try Task.checkCancellation()
        if failing.contains(host) { throw TransferFailure(message: "Unavailable", receivedBytes: 0) }
        let data: Data
        if path == "/.well-known/fourthciv" {
            data = try JSONSerialization.data(withJSONObject: ["name":"Test relay","protocol":"fourthciv/1","visibility":"public","capabilities":["relay-sync-v1"],"epoch":epoch])
        } else if let event {
            try event.validate()
            if !(events[host] ?? []).contains(where: { $0.id == event.id }) { events[host,default:[]].append(event); writes += 1 }
            data = try JSONEncoder().encode(["id":event.id,"result":"accepted"])
        } else {
            let offset = Int(path.split(separator: "=").last!)!
            let values = Array((events[host] ?? []).dropFirst(offset).prefix(64))
            let array = try JSONSerialization.jsonObject(with: JSONEncoder().encode(values))
            data = try JSONSerialization.data(withJSONObject: ["events":array,"next":NSNull(),"cursor":offset + values.count + (malformed ? 1 : 0),"epoch":epoch])
        }
        guard data.count <= maximum else { throw TransferFailure(message: "Peer response too large", receivedBytes: maximum) }
        return data
    }
}

struct InternetTests {
    private func directory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private func town(_ title: String) throws -> Event {
        try Event.signed(kind: .community, key: .init(), attribution: Attribution(name: "Sync test"), title: title, body: "Public fixture")
    }
    @Test @MainActor func replicasBridgeRelaysResumeAfterRestartAndReseedChangedEpochs() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let local = try town("Local"), remote = try town("Remote")
        try JSONEncoder().encode([local]).write(to: dir.appendingPathComponent("events.json"))
        let fixture = RelayFixture(); fixture.events["a.example"] = [remote]
        var node: CivNode? = try CivNode(directory: dir, request: fixture.request)
        var settings = node!.settings; settings.internetEnabled = true; settings.relays = ["https://a.example","https://b.example"]
        try node!.updateSettings(settings)
        await node!.sync()
        #expect(node!.events == [local, remote])
        #expect(fixture.events["a.example"] == [remote, local])
        #expect(fixture.events["b.example"] == [local, remote])
        #expect(node!.internetBytes > 0)
        let previousWrites = fixture.writes
        node = nil
        node = try CivNode(directory: dir, request: fixture.request)
        await node!.sync()
        #expect(fixture.calls.contains { $0 == ("a.example","/v1/events?offset=1") })
        #expect(fixture.writes == previousWrites)
        fixture.epoch = UUID().uuidString; fixture.events = [:]
        node = nil; node = try CivNode(directory: dir, request: fixture.request)
        await node!.sync()
        #expect(fixture.events["a.example"] == [local, remote])
        #expect(fixture.events["b.example"] == [local, remote])
        node = nil
    }
    @Test @MainActor func unreachableRelayDoesNotPreventTheNextRelayAndBadPagesAreRejected() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = RelayFixture(); fixture.failing = ["a.example"]
        fixture.events["b.example"] = [try town("Available")]
        let node = try CivNode(directory: dir, request: fixture.request)
        var settings = node.settings; settings.internetEnabled = true; settings.relays = ["https://a.example","https://b.example"]
        try node.updateSettings(settings); await node.sync()
        #expect(node.events.count == 1)
        #expect(node.peerStatus["https://a.example"]?.contains("Unavailable") == true)
        let before = fixture.calls.count
        await node.sync(); #expect(fixture.calls.count == before) // Poll/backoff floor.
        fixture.malformed = true
        settings.relays = ["https://c.example"]; try node.updateSettings(settings)
        await node.sync()
        #expect(node.peerStatus["https://c.example"]?.contains("Invalid relay pagination") == true)
        #expect(fixture.writes == 0)
    }
    @Test @MainActor func optInPauseAndExhaustedBudgetPreventFurtherTransfers() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = RelayFixture()
        let node = try CivNode(directory: dir, request: fixture.request)
        await node.sync(); #expect(fixture.calls.isEmpty)
        var settings = node.settings; settings.internetEnabled = true; settings.dailySyncMiB = 1; settings.relays = ["https://a.example"]
        try node.updateSettings(settings)
        fixture.onRequest = { [weak node] in try node?.togglePause() }
        await node.sync()
        #expect(node.settings.paused); #expect(fixture.calls.count == 1)
        #expect(node.events.isEmpty)
        fixture.onRequest = nil
        settings.paused = false; try node.updateSettings(settings)
        let limit = 1_024 * 1_024
        _ = try node.ledger.reserve(node.ledger.remaining(limit: limit), limit: limit)
        await node.sync(); #expect(fixture.calls.count == 1)
        #expect(node.peerStatus["https://a.example"]?.contains("budget reached") == true)
    }
    @Test @MainActor func inFlightOverrunIsChargedBeforeAnyNewReservation() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let ledger = try SyncLedger(directory: dir)
        let reservation = try ledger.reserve(100, limit: 100)
        try ledger.settle(reservation, actual: 120)
        #expect(ledger.used() == 120)
        #expect(ledger.remaining(limit: 100) == 0)
        #expect(throws: (any Error).self) { _ = try ledger.reserve(1, limit: 100) }
    }
}
