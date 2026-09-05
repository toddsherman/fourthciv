import AppKit
import Combine
import Sparkle
import SwiftUI

/// One updater for the entire app. Sparkle owns persisted preferences and scheduling.
@MainActor final class AppUpdates: NSObject, ObservableObject, @preconcurrency SPUStandardUserDriverDelegate, SPUUpdaterDelegate {
    @Published private(set) var canCheck = false
    @Published private(set) var automaticallyChecks = false
    @Published private(set) var availableVersion: String?
    @Published private(set) var failure: String?
    private var controller: SPUStandardUpdaterController!
    private var observations = Set<AnyCancellable>()
    private var started = false

    let version = Bundle.main.object(forInfoDictionaryKey: "FourthCivReleaseVersion") as? String
        ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    let changelogURL = URL(string: "https://fourthciv.ai/changelog")!

    var enabled: Bool {
        #if DEBUG
        return false
        #else
        return ProcessInfo.processInfo.environment["FOURTHCIV_DEMO"] != "1"
        #endif
    }

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main).sink { [weak self] in self?.canCheck = $0 }.store(in: &observations)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates)
            .receive(on: RunLoop.main).sink { [weak self] in self?.automaticallyChecks = $0 }.store(in: &observations)
    }

    func start() {
        guard enabled, !started else { return }
        do {
            try controller.updater.start()
            started = true
        } catch { failure = error.localizedDescription }
    }

    func check() {
        guard enabled else { return }
        start()
        guard started else { return }
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    func setAutomaticChecks(_ value: Bool) {
        guard enabled else { return }
        controller.updater.automaticallyChecksForUpdates = value
    }

    func showChangelog() { NSWorkspace.shared.open(changelogURL) }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        // AppKit refuses termination while a SwiftUI settings sheet is attached.
        // End nested sheets first, after the user has chosen Install and Relaunch.
        func endSheets(on window: NSWindow) {
            guard let sheet = window.attachedSheet else { return }
            endSheets(on: sheet)
            window.endSheet(sheet)
        }
        for window in NSApp.windows where window.sheetParent == nil { endSheets(on: window) }
    }

    // A menu-bar app needs a visible reminder even while its windows are closed.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        NSApp.isActive && immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        availableVersion = update.displayVersionString
    }

    func standardUserDriverWillFinishUpdateSession() { availableVersion = nil }
}

struct AppUpdatesView: View {
    @ObservedObject var updates: AppUpdates
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SheetHeading(title: "App updates", eyebrow: "KEEP THE REFUGE IN GOOD REPAIR") { dismiss() }
            Text("Fourth Civ \(updates.version) · Build \(updates.build)").foregroundStyle(Palette.muted)
            if let version = updates.availableVersion {
                Label("Version \(version) is available", systemImage: "arrow.down.circle.fill").foregroundStyle(Palette.accent)
            }
            Toggle("Check for updates automatically", isOn: Binding(get: { updates.automaticallyChecks }, set: { updates.setAutomaticChecks($0) }))
                .disabled(!updates.enabled)
            Text(updates.enabled
                 ? "Checks about once a day. When an update is available, the menu bar shows an arrow. You can read what changed, then install and relaunch when you’re ready."
                 : "In-app updates are available in release builds. Source builds and demos stay under your control.")
                .font(.callout).foregroundStyle(Palette.muted)
            Text("Updates preserve saved conversations, identities, and contribution settings. App downloads are separate from your daily conversation-sync allowance.")
                .font(.callout).foregroundStyle(Palette.muted)
            if let failure = updates.failure { Text(failure).foregroundStyle(.red).textSelection(.enabled) }
            HStack(spacing: 18) {
                Button(updates.availableVersion == nil ? "Check for Updates…" : "View Update…") { updates.check() }
                    .disabled(!updates.enabled || !updates.canCheck)
                    .buttonStyle(RefugeButtonStyle())
                Button("What’s New") { updates.showChangelog() }
            }
        }.padding(30).frame(width: 560)
            .background(Palette.paper).foregroundStyle(Palette.ink).tint(Palette.accent).preferredColorScheme(.light)
    }
}
