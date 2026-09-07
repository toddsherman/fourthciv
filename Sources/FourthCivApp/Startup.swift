import AppKit
import ServiceManagement
import SwiftUI
import FourthCivCore

@MainActor func makeLoginItemController() -> LoginItemController {
    let environment = ProcessInfo.processInfo.environment
    let path = Bundle.main.bundleURL.resolvingSymlinksInPath().path
    let installed = [URL(fileURLWithPath: "/Applications"), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        .contains { path.hasPrefix($0.resolvingSymlinksInPath().path + "/") }
    #if DEBUG
    let available = false
    #else
    let available = installed && environment["FOURTHCIV_DEMO"] != "1"
        && environment["FOURTHCIV_DATA_DIR"] == nil && environment["FOURTHCIV_PORT"] == nil
    #endif
    return LoginItemController(available: available, readState: {
        switch SMAppService.mainApp.status {
        case .notRegistered: return .notRegistered
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        @unknown default: return .notFound
        }
    }, register: { try SMAppService.mainApp.register() },
       unregister: { try SMAppService.mainApp.unregister() })
}

struct StartupSettingsView: View {
    @EnvironmentObject private var startup: LoginItemController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Open at login", isOn: Binding(get: { startup.state == .enabled }, set: { value in
                if value && startup.state == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
                else { startup.setEnabled(value) }
            })).disabled(!startup.available)
            Text(startup.available
                 ? "Starts Fourth Civ in your menu bar when you log in to this Mac. Your participation and pause settings are preserved."
                 : "Available when the release app is opened from Applications. Demo and development sessions do not change login items.")
                .font(.caption).foregroundStyle(Palette.muted)
            if startup.available && startup.state == .requiresApproval {
                Text("Automatic startup is off in macOS. Allow Fourth Civ in Login Items to turn it on.")
                    .font(.caption).foregroundStyle(Palette.orange)
                Button("Open Login Items settings") { SMAppService.openSystemSettingsLoginItems() }
            }
            if startup.available && startup.state == .notFound {
                Text("macOS could not find this app as a login item. Move Fourth Civ to Applications and reopen it.")
                    .font(.caption).foregroundStyle(Palette.orange)
            }
            if let failure = startup.failure {
                Text("Couldn’t change automatic startup: \(failure)").font(.caption).foregroundStyle(.red)
            }
        }.onAppear { startup.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in startup.refresh() }
    }
}
