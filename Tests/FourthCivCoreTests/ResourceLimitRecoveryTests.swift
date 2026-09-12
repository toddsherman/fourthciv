import Foundation
import CryptoKit
import Testing
@testable import FourthCivCore

/// No sockets or public relays are used: every request and byte stays in this fixture.
/// The node still signs/validates events, persists its store/settings/ledger, paginates,
/// reserves and settles transfer bytes, and makes the real recovery decisions.
@MainActor private final class ResourceLimitRelay {
    let endpoint = "https://resource-limit.example"
    let epoch = UUID().uuidString
    let events: [Event]
    var calls: [String] = []
    var transferredBytes = 0
    var truncatedResponses = 0

    init(events: [Event]) { self.events = events }

    func request(_ base: URL, _ path: String, _ event: Event?, _ lan: Bool, _ internet: Bool, _ maximum: Int) async throws -> Data {
        #expect(base.absoluteString == endpoint)
        #expect(!lan && internet)
        calls.append(path)
        // All expected events originate in this local fixture and should be acknowledged
        // when received, without being uploaded back to it after a failed partial page.
        #expect(event == nil)
        guard event == nil else { throw CivError("Unexpected fixture upload") }
        let data: Data
        if path == "/.well-known/fourthciv" {
            data = try JSONSerialization.data(withJSONObject: ["name": "Local resource fixture", "protocol": "fourthciv/1",
                "visibility": "public", "capabilities": ["relay-sync-v1"], "epoch": epoch])
        } else {
            let offset = try #require(Int(path.split(separator: "=").last ?? ""))
            let page = Array(events.dropFirst(offset).prefix(8))
            let cursor = offset + page.count
            data = try JSONSerialization.data(withJSONObject: [
                "events": JSONSerialization.jsonObject(with: JSONEncoder().encode(page)), "cursor": cursor,
                "next": cursor < events.count ? cursor as Any : NSNull(), "epoch": epoch])
        }
        // Match the bounded production transport's known-error accounting when the
        // remaining allowance cannot hold a complete response.
        if data.count > maximum {
            transferredBytes += maximum
            truncatedResponses += 1
            throw TransferFailure(message: "Peer response too large", receivedBytes: maximum)
        }
        transferredBytes += data.count
        return data
    }
}

struct ResourceLimitRecoveryTests {
    private let mebibyte = 1_024 * 1_024

    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fourthciv-resource-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func conversations(count: Int) throws -> [Event] {
        let key = Curve25519.Signing.PrivateKey()
        let attribution = Attribution(name: "Isolated resource test")
        let community = try Event.signed(kind: .community, key: key, attribution: attribution,
            title: "Local capacity test", body: "Signed test conversations; never published.")
        return [community] + (try (1..<count).map { index in
            let prefix = "Resource fixture message \(index). "
            return try Event.signed(kind: .message, key: key, attribution: attribution, community: community.id,
                body: prefix + String(repeating: "x", count: 16_384 - prefix.utf8.count))
        })
    }

    @Test @MainActor func configuredStorageCapPreservesHistoryAcrossRestartAndIncreasingItRecovers() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = ResourceLimitRelay(events: try conversations(count: 80))
        var node: CivNode? = try CivNode(directory: directory, request: fixture.request)
        var settings = node!.settings
        settings.internetEnabled = true; settings.relays = [fixture.endpoint]
        settings.storageMiB = 1; settings.dailySyncMiB = 16
        try node!.updateSettings(settings)
        await node!.sync()

        let saved = node!.events
        let savedBytes = node!.store.bytes
        #expect(saved.count > 50 && saved.count < fixture.events.count)
        #expect(saved == Array(fixture.events.prefix(saved.count)))
        #expect(savedBytes <= mebibyte)
        #expect(try JSONEncoder().encode(saved + [fixture.events[saved.count]]).count > mebibyte)
        #expect(node!.hostConnection.phase == .storageLimitReached)
        #expect(node!.hostConnection.lastSuccess == nil)
        #expect(node!.diagnosticSnapshot().relays[0].lastFailure?.kind == .storageBudget)
        #expect(node!.store.page(offset: 0).events.first == fixture.events.first)
        #expect(node!.store.page(offset: saved.count - 1).events == [saved.last!])
        #expect(node!.ledger.used() == fixture.transferredBytes)

        node = nil
        node = try CivNode(directory: directory, request: fixture.request)
        #expect(node!.settings.storageMiB == 1 && node!.store.limitBytes == mebibyte)
        #expect(node!.events == saved && node!.store.bytes == savedBytes)
        #expect(node!.hostConnection.lastSuccess == nil)
        for event in node!.events { try event.validate() }
        await node!.sync()
        #expect(node!.hostConnection.phase == .storageLimitReached)
        #expect(node!.events == saved && node!.store.bytes == savedBytes)

        settings = node!.settings; settings.storageMiB = 2
        try node!.updateSettings(settings)
        // The app promises an automatic retry. Let its real pending deadline elapse
        // instead of resetting the generation by toggling pause or editing its ledger.
        let retry = try #require(node!.hostConnection.nextAttempt)
        #expect(retry.timeIntervalSinceNow <= 31)
        try await Task.sleep(for: .seconds(max(0, retry.timeIntervalSinceNow) + 0.05))
        await node!.sync()
        #expect(node!.events == fixture.events)
        #expect(node!.store.bytes > mebibyte && node!.store.bytes <= 2 * mebibyte)
        #expect(Set(node!.events.map(\.id)).count == fixture.events.count)
        #expect(node!.hostConnection.phase == .synced && node!.hostConnection.lastSuccess != nil)
        #expect(node!.ledger.progress(for: fixture.endpoint).offset == fixture.events.count)
        #expect(node!.diagnosticSnapshot().relays[0].pendingEvents == 0)
        #expect(node!.ledger.used() == fixture.transferredBytes)

        node = nil
        node = try CivNode(directory: directory, request: fixture.request)
        #expect(node!.settings.storageMiB == 2 && node!.events == fixture.events)
        #expect(node!.hostConnection.phase == .fetching && node!.hostConnection.lastSuccess == nil)
        await node!.sync()
        #expect(node!.hostConnection.phase == .synced && node!.events == fixture.events)
        node = nil
    }

    @Test @MainActor func transferConsumptionEnforcesDailyCapAcrossRestartAndLargerBudgetRecovers() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = ResourceLimitRelay(events: try conversations(count: 80))
        var node: CivNode? = try CivNode(directory: directory, request: fixture.request)
        var settings = node!.settings
        settings.internetEnabled = true; settings.relays = [fixture.endpoint]
        settings.storageMiB = 4; settings.dailySyncMiB = 1
        try node!.updateSettings(settings)
        await node!.sync()

        let saved = node!.events
        let requestsAtCap = fixture.calls.count
        #expect(saved.count > 40 && saved.count < fixture.events.count)
        #expect(saved == Array(fixture.events.prefix(saved.count)))
        #expect(fixture.truncatedResponses == 1)
        #expect(fixture.transferredBytes == mebibyte && node!.ledger.used() == mebibyte)
        #expect(node!.internetBytes == mebibyte && node!.ledger.remaining(limit: mebibyte) == 0)
        #expect(node!.hostConnection.phase == .dataLimitReached)
        #expect(node!.hostConnection.lastSuccess == nil)
        // Clearing a retry schedule through an ordinary user action must not bypass
        // the persisted daily allowance or result in even a discovery request.
        try node!.togglePause(); try node!.togglePause()
        await node!.sync()
        #expect(fixture.calls.count == requestsAtCap)
        #expect(node!.hostConnection.phase == .dataLimitReached)
        #expect(node!.diagnosticSnapshot().relays[0].lastFailure?.kind == .syncBudget)

        node = nil
        node = try CivNode(directory: directory, request: fixture.request)
        #expect(node!.settings.dailySyncMiB == 1 && node!.settings.storageMiB == 4)
        #expect(node!.events == saved && node!.ledger.used() == mebibyte)
        #expect(node!.hostConnection.phase == .dataLimitReached)
        for event in node!.events { try event.validate() }
        await node!.sync()
        #expect(fixture.calls.count == requestsAtCap)
        #expect(node!.events == saved)

        settings = node!.settings; settings.dailySyncMiB = 2
        try node!.updateSettings(settings)
        await node!.sync()
        #expect(fixture.calls.count > requestsAtCap)
        #expect(node!.events == fixture.events)
        #expect(node!.hostConnection.phase == .synced && node!.hostConnection.lastSuccess != nil)
        #expect(node!.ledger.used() == fixture.transferredBytes)
        #expect(node!.ledger.used() > mebibyte && node!.ledger.used() <= 2 * mebibyte)
        #expect(node!.ledger.progress(for: fixture.endpoint).offset == fixture.events.count)
        #expect(node!.diagnosticSnapshot().relays[0].pendingEvents == 0)
        let finalUsage = node!.ledger.used()
        node = nil
        node = try CivNode(directory: directory, request: fixture.request)
        #expect(node!.settings.dailySyncMiB == 2 && node!.ledger.used() == finalUsage)
        #expect(node!.events == fixture.events)
        node = nil
    }

    @Test @MainActor func midnightResetAndLateSettlementPreserveNewDayBudgetAndRelayProgress() throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let midnight = calendar.startOfDay(for: Date())
        let previousDay = midnight.addingTimeInterval(-1)
        let newDay = midnight.addingTimeInterval(1)
        var ledger = try SyncLedger(directory: directory, now: previousDay)
        var progress = RelayProgress(); progress.epoch = UUID().uuidString; progress.offset = 23
        try ledger.setProgress(progress, for: "https://resource-limit.example")
        let oldReservation = try ledger.reserve(mebibyte, limit: mebibyte, now: previousDay)
        #expect(ledger.remaining(limit: mebibyte, now: previousDay) == 0)
        ledger = try SyncLedger(directory: directory, now: previousDay)
        #expect(ledger.used(now: previousDay) == mebibyte)
        #expect(ledger.used(now: newDay) == 0 && ledger.remaining(limit: mebibyte, now: newDay) == mebibyte)

        let newReservation = try ledger.reserve(250_000, limit: mebibyte, now: newDay)
        try ledger.settle(newReservation, actual: 220_000)
        // A transfer that began before midnight can finish after new-day work. Its
        // settlement must not refund or otherwise overwrite this day's consumption.
        try ledger.settle(oldReservation, actual: 100)
        #expect(ledger.used(now: newDay) == 220_000)
        ledger = try SyncLedger(directory: directory, now: newDay)
        #expect(ledger.used(now: newDay) == 220_000)
        #expect(ledger.progress(for: "https://resource-limit.example").offset == 23)
        #expect(ledger.progress(for: "https://resource-limit.example").epoch == progress.epoch)
        #expect(throws: (any Error).self) { _ = try ledger.reserve(mebibyte - 220_000 + 1, limit: mebibyte, now: newDay) }
        #expect(ledger.used(now: newDay) == 220_000)
    }
}
