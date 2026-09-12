import AppKit
import Sparkle

// Compile with Updates.swift and Theme.swift, -D DEBUG, and the pinned Sparkle
// framework. This invokes real Objective-C delegate methods without starting an
// updater, making requests, changing preferences, or installing an application.
@main struct UpdateStatusTest {
    @MainActor static func main() throws {
        let updates = AppUpdates()
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        let updater = controller.updater
        let delegate: SPUUpdaterDelegate = updates
        let userDriverDelegate: SPUStandardUserDriverDelegate = updates
        precondition(updates.responds(to: NSSelectorFromString("updater:mayPerformUpdateCheck:error:")))
        precondition(updates.status == .unavailable, "Debug builds must not claim to be up to date")

        try updates.updater(updater, mayPerform: .updatesInBackground)
        precondition(updates.status == .checking)

        let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet,
                              userInfo: [NSLocalizedDescriptionKey: "Offline"])
        delegate.updater?(updater, didFinishUpdateCycleFor: .updatesInBackground, error: offline)
        precondition(updates.status == .failed && updates.failure == "Offline")

        try updates.updater(updater, mayPerform: .updatesInBackground)
        precondition(updates.status == .checking && updates.failure == nil)
        let current = noUpdate(reason: .onLatestVersion)
        delegate.updaterDidNotFindUpdate?(updater, error: current)
        delegate.updater?(updater, didFinishUpdateCycleFor: .updatesInBackground, error: current)
        precondition(updates.status == .upToDate && updates.failure == nil)

        let incompatible = noUpdate(reason: .systemIsTooOld)
        delegate.updaterDidNotFindUpdate?(updater, error: incompatible)
        precondition(updates.status == .unavailable && updates.failure != nil)

        let item = SUAppcastItem(dictionary: ["title": "Update fixture", "sparkle:version": "999",
                                              "sparkle:shortVersionString": "9.9.9",
                                              "link": "https://example.invalid/never-downloaded"])!
        delegate.updater?(updater, didFindValidUpdate: item)
        precondition(updates.status == .available && updates.availableVersion == "9.9.9" && updates.failure == nil)

        userDriverDelegate.standardUserDriverWillFinishUpdateSession?()
        delegate.updater?(updater, didFinishUpdateCycleFor: .updatesInBackground, error: nil)
        precondition(updates.status == .available && updates.availableVersion == "9.9.9",
                     "Dismissing an offer must retain the install action")

        // A later background check may omit a skipped version. It must not
        // change a known update into an incorrect 'Up to date' claim.
        try updates.updater(updater, mayPerform: .updatesInBackground)
        delegate.updaterDidNotFindUpdate?(updater, error: current)
        delegate.updater?(updater, didFinishUpdateCycleFor: .updatesInBackground, error: offline)
        precondition(updates.status == .available && updates.availableVersion == "9.9.9")

        let canceled = NSError(domain: SUSparkleErrorDomain, code: Int(SUError.installationCanceledError.rawValue))
        try updates.updater(updater, mayPerform: .updates)
        delegate.updater?(updater, didFinishUpdateCycleFor: .updates, error: canceled)
        precondition(updates.status == .available && updates.failure == nil)
        print("Update status callbacks passed: checking, failure, current, incompatible, available, dismissed, skipped, canceled.")
    }

    private static func noUpdate(reason: SPUNoUpdateFoundReason) -> NSError {
        NSError(domain: SUSparkleErrorDomain, code: Int(SUError.noUpdateError.rawValue),
                userInfo: [SPUNoUpdateFoundReasonKey: NSNumber(value: reason.rawValue)])
    }
}
