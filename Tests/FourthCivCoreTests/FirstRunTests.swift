import Foundation
import Testing
@testable import FourthCivCore

struct FirstRunTests {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    @Test @MainActor func freshAppJoinsAndReceivesWithDefaultLimits() async throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let event = try Event.signed(kind: .community, key: .init(), attribution: Attribution(name: "First-run fixture"), title: "Public fixture", body: "Isolated test")
        let epoch = UUID().uuidString
        var requests = 0
        let node = try CivNode(directory: dir, joinInternetOnFirstRun: true, request: { _, path, _, _, _, _ in
            requests += 1
            if path == "/.well-known/fourthciv" {
                return try JSONSerialization.data(withJSONObject: ["name": "Test relay", "protocol": "fourthciv/1", "visibility": "public", "capabilities": ["relay-sync-v1"], "epoch": epoch])
            }
            let events = try JSONSerialization.jsonObject(with: JSONEncoder().encode([event]))
            return try JSONSerialization.data(withJSONObject: ["epoch": epoch, "events": events, "cursor": 1, "next": NSNull()])
        })
        #expect(node.settings.internetEnabled && !node.settings.lanEnabled && !node.settings.paused)
        #expect(node.settings.storageMiB == 16 && node.settings.dailySyncMiB == 25)
        #expect(node.settings.relays == [RelayEndpoint.pilot])
        let stored = try JSONDecoder().decode(NodeSettings.self, from: Data(contentsOf: dir.appendingPathComponent("settings.json")))
        #expect(stored.internetEnabled)
        await node.sync()
        #expect(requests == 2 && node.events == [event])
    }

    @Test @MainActor func optOutPauseAndCustomLimitsSurviveRestart() throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        var node: CivNode? = try CivNode(directory: dir, joinInternetOnFirstRun: true)
        var settings = node!.settings
        settings.internetEnabled = false; settings.paused = true
        settings.dailySyncMiB = 5; settings.storageMiB = 8
        settings.relays = ["https://chosen.example"]
        try node!.updateSettings(settings)
        node = nil
        node = try CivNode(directory: dir, joinInternetOnFirstRun: true)
        #expect(!node!.settings.internetEnabled && node!.settings.paused)
        #expect(node!.settings.dailySyncMiB == 5 && node!.settings.storageMiB == 8)
        #expect(node!.settings.relays == settings.relays)
    }

    @Test @MainActor func legacyOrMissingSettingsDoNotShareAnExistingStore() throws {
        for legacySettings in [true, false] {
            let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if legacySettings {
                try Data("{\"storageMiB\":8}".utf8).write(to: dir.appendingPathComponent("settings.json"))
            } else {
                try Data("[]".utf8).write(to: dir.appendingPathComponent("events.json"))
            }
            let node = try CivNode(directory: dir, joinInternetOnFirstRun: true)
            #expect(!node.settings.internetEnabled)
        }
    }

    @Test @MainActor func headlessAndDemoDefaultsRemainLocalWhileAppChoicePersists() throws {
        let dir = directory(); defer { try? FileManager.default.removeItem(at: dir) }
        var node: CivNode? = try CivNode(directory: dir)
        #expect(!node!.settings.internetEnabled)
        node = nil
        node = try CivNode(directory: dir, joinInternetOnFirstRun: true)
        #expect(!node!.settings.internetEnabled)
        node = nil
        let fresh = directory(); defer { try? FileManager.default.removeItem(at: fresh) }
        try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true)
        node = try CivNode(directory: fresh, joinInternetOnFirstRun: true)
        #expect(node!.settings.internetEnabled)
        node = nil
        node = try CivNode(directory: fresh, joinInternetOnFirstRun: true)
        #expect(node!.settings.internetEnabled)
    }
}
