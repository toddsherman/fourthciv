import AppKit
import Sparkle
import SwiftUI

// A real SwiftUI application and Sparkle installer, with no Fourth Civ node.
// prepare_popup_update_test.py supplies an isolated host and result directory.
@MainActor final class PopupUpdateHarness: NSObject, NSApplicationDelegate, ObservableObject {
    @Published var updater: SPUUpdater!
    let productionDelegate = AppUpdates()
    lazy var resumedDelegate = ResumedInstallDelegate(productionDelegate)
    @Published var simulateResumedInstall = false

    var output: URL {
        URL(fileURLWithPath: Bundle.main.object(forInfoDictionaryKey: "TestOutputDirectory") as! String)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let host = Bundle(path: Bundle.main.object(forInfoDictionaryKey: "TestHostPath") as! String)!
        let build = Int(host.object(forInfoDictionaryKey: "CFBundleVersion") as! String)!
        let target = Bundle.main.object(forInfoDictionaryKey: "TestTargetBuild") as! Int
        try! String(build).write(to: output.appendingPathComponent("launched-build.txt"), atomically: true, encoding: .utf8)
        if build >= target { exit(0) }
        NSApp.activate(ignoringOtherApps: true)
    }

    func check() {
        if updater == nil {
            let host = Bundle(path: Bundle.main.object(forInfoDictionaryKey: "TestHostPath") as! String)!
            let driver = SPUStandardUserDriver(hostBundle: host, delegate: nil)
            let delegate: SPUUpdaterDelegate = simulateResumedInstall ? resumedDelegate : productionDelegate
            updater = SPUUpdater(hostBundle: host, applicationBundle: Bundle.main, userDriver: driver, delegate: delegate)
            try! updater.start()
        }
        updater.checkForUpdates()
    }

    func checkSavePanelDismissal() {
        // Exercise the same cleanup inside the modal loop used by BugReportView.
        // The callback logs completion; it does not install or terminate anything.
        // Only a fixture token for the delegate API; never downloaded or installed.
        let item = SUAppcastItem(dictionary: ["title": "Modal regression", "sparkle:version": "1",
                                             "link": "https://fourthciv.ai/changelog"])!
        let panel = NSSavePanel()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            _ = self.productionDelegate.updater(self.updater, shouldPostponeRelaunchForUpdate: item) {
                try! "dismissed".write(to: self.output.appendingPathComponent("save-panel.txt"), atomically: true, encoding: .utf8)
            }
        }
        let response = panel.runModal()
        assert(response == .cancel)
    }
}

// Sparkle documents that a resumed installation can omit the postponement hook.
@MainActor final class ResumedInstallDelegate: NSObject, SPUUpdaterDelegate {
    let production: AppUpdates
    init(_ production: AppUpdates) { self.production = production }
    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        production.updaterWillRelaunchApplication(updater)
    }
}

struct UpdateTestPopup: View {
    let harness: PopupUpdateHarness
    @State private var nested = false
    var body: some View {
        VStack(spacing: 24) {
            Text("SwiftUI settings popup")
            Button("Check for Updates", action: harness.check)
            Button("Open nested popup") { nested = true }
        }.padding(40).sheet(isPresented: $nested) {
            VStack(spacing: 24) {
                Text("Nested SwiftUI popup")
                Button("Check for Updates", action: harness.check)
            }.padding(40).dismissForAppUpdate()
        }
    }
}

@main struct PopupUpdateTestApp: App {
    @NSApplicationDelegateAdaptor(PopupUpdateHarness.self) var harness
    var body: some Scene {
        WindowGroup("Fourth Civ popup updater regression") { PopupTestControls(harness: harness) }
    }
}

struct PopupTestControls: View {
    @ObservedObject var harness: PopupUpdateHarness
    @State private var settings = false
    var body: some View {
        VStack(spacing: 24) {
            Text("Isolated update test — no Fourth Civ node data")
            Toggle("Simulate resumed installation", isOn: $harness.simulateResumedInstall)
                .disabled(harness.updater != nil)
            Button("Open SwiftUI popup") { settings = true }
            Button("Check for Updates", action: harness.check)
            Button("Test Save dialog dismissal", action: harness.checkSavePanelDismissal)
                .disabled(harness.updater == nil)
        }.padding(40).sheet(isPresented: $settings) {
            UpdateTestPopup(harness: harness).dismissForAppUpdate()
        }
    }
}
