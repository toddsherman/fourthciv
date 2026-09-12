import Foundation
import Testing
@testable import FourthCivCore

struct PersistenceFaultTests {
    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fourthciv-persistence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// A nonempty directory cannot be replaced by an atomic file write, including on root-run CI.
    /// Keep the last good snapshot beside it so the test can restore storage and retry.
    private func obstruct(_ file: URL) throws -> URL {
        let backup = file.appendingPathExtension("last-good")
        try FileManager.default.moveItem(at: file, to: backup)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        try Data("obstruction".utf8).write(to: file.appendingPathComponent("sentinel"))
        return backup
    }

    private func restore(_ file: URL, from backup: URL) throws {
        try FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: backup, to: file)
    }

    @Test @MainActor func failedAtomicEventWritePreservesHistoryAndCanRetryTheSameEvent() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let town = try Event.signed(kind: .community, key: .init(), attribution: Attribution(name: "Fixture"), title: "Saved", body: "History")
        let pending = try Event.signed(kind: .message, key: .init(), attribution: Attribution(name: "Fixture"), community: town.id, body: "Pending")
        var store: EventStore? = try EventStore(directory: directory)
        try store!.insert(town)
        let file = directory.appendingPathComponent("events.json")
        let previous = try Data(contentsOf: file)
        let previousSize = store!.bytes
        let backup = try obstruct(file)

        #expect(throws: (any Error).self) { try store!.insert(pending) }
        #expect(store!.events == [town])
        #expect(store!.bytes == previousSize)
        #expect(try Data(contentsOf: backup) == previous)
        #expect(try String(contentsOf: file.appendingPathComponent("sentinel"), encoding: .utf8) == "obstruction")

        try restore(file, from: backup)
        #expect(try store!.insert(pending))
        #expect(try !store!.insert(pending))
        store = nil
        let reopened = try EventStore(directory: directory)
        #expect(reopened.events == [town, pending])
    }

    @Test @MainActor func failedLedgerWritesPreserveReservationsAndProgressAcrossRestart() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 86_400 * 100 + 10)
        let ledger = try SyncLedger(directory: directory, now: now)
        let reservation = try ledger.reserve(600, limit: 1_000, now: now)
        var previousProgress = RelayProgress(); previousProgress.epoch = UUID().uuidString; previousProgress.offset = 1
        try ledger.setProgress(previousProgress, for: RelayEndpoint.pilot)
        let file = directory.appendingPathComponent("internet-sync.json")
        let previous = try Data(contentsOf: file)
        let backup = try obstruct(file)

        #expect(throws: (any Error).self) { _ = try ledger.reserve(100, limit: 1_000, now: now) }
        #expect(throws: (any Error).self) { try ledger.settle(reservation, actual: 200) }
        var advanced = previousProgress; advanced.offset = 2
        #expect(throws: (any Error).self) { try ledger.setProgress(advanced, for: RelayEndpoint.pilot) }
        #expect(ledger.used(now: now) == 600)
        #expect(ledger.progress(for: RelayEndpoint.pilot).offset == 1)
        #expect(try Data(contentsOf: backup) == previous)

        try restore(file, from: backup)
        let reopened = try SyncLedger(directory: directory, now: now)
        #expect(reopened.used(now: now) == 600)
        #expect(reopened.progress(for: RelayEndpoint.pilot).offset == 1)
        try reopened.settle(reservation, actual: 200)
        #expect(reopened.used(now: now) == 200)
        try reopened.setProgress(advanced, for: RelayEndpoint.pilot)
        #expect(try SyncLedger(directory: directory, now: now).progress(for: RelayEndpoint.pilot).offset == 2)
    }

    @Test @MainActor func damagedSnapshotsFailClosedWithoutOverwritingDataOrLeakingTheStoreLock() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let town = try Event.signed(kind: .community, key: .init(), attribution: Attribution(name: "Fixture"), title: "Retained", body: "History")
        var node: CivNode? = try CivNode(directory: directory)
        try node!.store.insert(town)
        var settings = node!.settings; settings.paused = true; settings.internetEnabled = true; settings.storageMiB = 8
        try node!.updateSettings(settings)
        let accountedAt = Date()
        _ = try node!.ledger.reserve(512, limit: 1_024, now: accountedAt)
        node = nil

        for name in ["events.json", "settings.json", "internet-sync.json"] {
            let file = directory.appendingPathComponent(name)
            let previous = try Data(contentsOf: file)
            for damaged in [Data("not JSON".utf8), Data(previous.dropLast())] {
                try damaged.write(to: file, options: .atomic)
                #expect(throws: (any Error).self) { _ = try CivNode(directory: directory, joinInternetOnFirstRun: true) }
                #expect(try Data(contentsOf: file) == damaged)
                try previous.write(to: file, options: .atomic)
                // In particular, ledger initialization fails after acquiring the event-store lock.
                node = try CivNode(directory: directory)
                #expect(node!.events == [town])
                #expect(node!.settings.paused && node!.settings.internetEnabled && node!.settings.storageMiB == 8)
                #expect(node!.ledger.used(now: accountedAt) == 512)
                node = nil
            }
        }

        let file = directory.appendingPathComponent("events.json")
        let previous = try Data(contentsOf: file)
        var altered = try #require(JSONSerialization.jsonObject(with: previous) as? [[String: Any]])
        altered[0]["body"] = "Unsigned replacement"
        let tampered = try JSONSerialization.data(withJSONObject: altered)
        try tampered.write(to: file)
        #expect(throws: (any Error).self) { _ = try EventStore(directory: directory) }
        #expect(try Data(contentsOf: file) == tampered)
        try previous.write(to: file)
        #expect(try EventStore(directory: directory).events == [town])
    }
}
