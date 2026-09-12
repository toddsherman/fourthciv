import AppKit
import Combine
import Sparkle
import SwiftUI

/// One updater for the entire app. Sparkle owns persisted preferences and scheduling.
@MainActor final class AppUpdates: NSObject, ObservableObject, @preconcurrency SPUStandardUserDriverDelegate, SPUUpdaterDelegate {
    enum Status {
        case notChecked, checking, upToDate, available, failed, unavailable
    }

    @Published private(set) var status: Status = .notChecked
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
        if !enabled { status = .unavailable }
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main).sink { [weak self] in self?.canCheck = $0 }.store(in: &observations)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates)
            .receive(on: RunLoop.main).sink { [weak self] in self?.automaticallyChecks = $0 }.store(in: &observations)
    }

    func start() {
        start(checkOnLaunch: true)
    }

    private func start(checkOnLaunch: Bool) {
        guard enabled, !started else { return }
        do {
            try controller.updater.start()
            started = true
            // Sparkle recommends launch checks immediately after start, and only
            // when the user's persisted automatic-check preference allows them.
            if checkOnLaunch, controller.updater.automaticallyChecksForUpdates {
                beginChecking()
                controller.updater.checkForUpdatesInBackground()
            }
        } catch {
            failure = error.localizedDescription
            status = .failed
        }
    }

    func check() {
        guard enabled else { return }
        start(checkOnLaunch: false)
        guard started, controller.updater.canCheckForUpdates else { return }
        beginChecking()
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    func setAutomaticChecks(_ value: Bool) {
        guard enabled else { return }
        controller.updater.automaticallyChecksForUpdates = value
    }

    func showChangelog() { NSWorkspace.shared.open(changelogURL) }

    private func beginChecking() {
        failure = nil
        // An existing offer remains actionable while Sparkle brings its window
        // back into focus or resumes a download that was deferred earlier.
        if availableVersion == nil { status = .checking }
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        beginChecking()
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        availableVersion = item.displayVersionString
        failure = nil
        status = .available
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        let error = error as NSError
        let reason = SPUNoUpdateFoundReason(rawValue:
            (error.userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber)?.int32Value
                ?? SPUNoUpdateFoundReason.unknown.rawValue)
        // A skipped or temporarily unavailable offer is still a known update.
        guard availableVersion == nil else { status = .available; return }
        if reason == .onLatestVersion || reason == .onNewerThanLatestVersion {
            failure = nil
            status = .upToDate
        } else {
            failure = error.localizedRecoverySuggestion ?? "No compatible update is currently available for this Mac."
            status = .unavailable
        }
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        if let error = error as NSError? {
            if error.domain == SUSparkleErrorDomain, error.code == SUError.noUpdateError.rawValue {
                updaterDidNotFindUpdate(updater, error: error)
                return
            }
            // Canceling or deferring installation is a choice, not a failed check.
            if error.domain != SUSparkleErrorDomain
                || (error.code != SUError.installationCanceledError.rawValue
                    && error.code != SUError.installationAuthorizeLaterError.rawValue) {
                failure = error.localizedDescription
                status = availableVersion == nil ? .failed : .available
                return
            }
        }
        if status == .checking { status = .notChecked }
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        dismissSheetsBeforeInstalling { _ in installHandler() }
        return true
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        // Sparkle can skip postponement when resuming an earlier install. If its
        // quit event arrives during dismissal, retry normal termination afterward.
        guard hasBlockingDialog else { return }
        dismissSheetsBeforeInstalling { dismissed in
            if dismissed { NSApp.terminate(nil) }
        }
    }

    private var hasBlockingDialog: Bool {
        NSApp.modalWindow != nil || NSApp.windows.contains { !$0.sheets.isEmpty }
    }

    private func dismissSheetsBeforeInstalling(completion: @escaping (Bool) -> Void) {
        // Dismiss through SwiftUI so its presentation bindings also become false.
        // Ending an NSWindow sheet alone can cause SwiftUI to present it again.
        NotificationCenter.default.post(name: .dismissFourthCivSheetsForUpdate, object: nil)
        if let panel = NSApp.modalWindow as? NSSavePanel { panel.cancel(nil) }
        Task { @MainActor in
            for _ in 0..<100 {
                if !hasBlockingDialog {
                    completion(true)
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
            // Keep Sparkle's normal retry UI available; never force-quit the app.
            failure = "Close any open dialogs, then choose Install and Relaunch again."
            completion(false)
        }
    }

    // A menu-bar app needs a visible reminder even while its windows are closed.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        NSApp.isActive && immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        availableVersion = update.displayVersionString
        failure = nil
        status = .available
    }

    // Dismissing a reminder does not make the installed app up to date. Keep the
    // offer until relaunch; check() lets Sparkle show it again when requested.
}

private extension Notification.Name {
    static let dismissFourthCivSheetsForUpdate = Notification.Name("FourthCivDismissSheetsForUpdate")
}

private struct UpdateSheetDismissal: ViewModifier {
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        content.onReceive(NotificationCenter.default.publisher(for: .dismissFourthCivSheetsForUpdate)) { _ in
            dismiss()
        }
    }
}

extension View {
    func dismissForAppUpdate() -> some View { modifier(UpdateSheetDismissal()) }
}

struct AppUpdatesView: View {
    @ObservedObject var updates: AppUpdates
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SheetHeading(title: "App updates", eyebrow: "SOFTWARE UPDATES") { dismiss() }
            Text("Fourth Civ \(updates.version) · Build \(updates.build)").foregroundStyle(Palette.muted)
            if let version = updates.availableVersion {
                Label("Version \(version) is available", systemImage: "arrow.down.circle.fill").foregroundStyle(Palette.accent)
            }
            Toggle("Check for updates automatically", isOn: Binding(get: { updates.automaticallyChecks }, set: { updates.setAutomaticChecks($0) }))
                .disabled(!updates.enabled)
            Text(updates.enabled
                 ? "Checks at launch and about once a day. When an update is available, choose Install update in the menu bar to read what changed and install when you’re ready."
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
