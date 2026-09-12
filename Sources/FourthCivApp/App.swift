import AppKit
import SwiftUI
import Combine
import FourthCivCore

@MainActor final class AppModel: ObservableObject {
    @Published var node: CivNode?
    @Published var failure: String?
    @Published var diagnosticFailure: DiagnosticFailure?
    let menuIcon = MenuBarIconModel()
    let isDemo = ProcessInfo.processInfo.environment["FOURTHCIV_DEMO"] == "1"
    init() {
        do {
            let environment = ProcessInfo.processInfo.environment
            let directory = environment["FOURTHCIV_DATA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("FourthCiv")
            let port = UInt16(environment["FOURTHCIV_PORT"] ?? "49400") ?? 49400
            let node = try CivNode(directory: directory, port: port, joinInternetOnFirstRun: !isDemo)
            try node.start(); self.node = node
            menuIcon.observe(node)
        } catch {
            failure = error.localizedDescription
            diagnosticFailure = .capture(error)
            menuIcon.setNeedsAttention(true)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) { NSApp.setActivationPolicy(.accessory) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main struct FourthCivApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    @StateObject private var updates = AppUpdates()
    @StateObject private var startup = makeLoginItemController()
    @Environment(\.openWindow) private var openWindow
    var body: some Scene {
        Window("Fourth Civ", id: "reader") {
            if let node = model.node {
                ReaderView(node: node, isDemo: model.isDemo, updates: updates)
                    .environmentObject(startup)
                    .task { updates.start() }
            } else {
                VStack(spacing: 16) {
                    CivSeal(onDark: false)
                    Text("Fourth Civ couldn’t start").font(.custom("Georgia", size: 28))
                    Text(model.failure ?? "Unknown error").textSelection(.enabled)
                    Text("Your saved data has not been replaced.").foregroundStyle(.secondary)
                    Button("Report a problem…") { openWindow(id: "bug-report") }
                }.padding(48).frame(minWidth: 600, minHeight: 400)
                    .background(Palette.paper).foregroundStyle(Palette.ink).preferredColorScheme(.light)
            }
        }
        .defaultSize(width: 1120, height: 760)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updates.check() }.disabled(!updates.enabled || !updates.canCheck)
                Button("What’s New") { updates.showChangelog() }
                Button("Report a problem…") { openWindow(id: "bug-report") }
            }
        }
        MenuBarExtra {
            if let node = model.node { MenuContent(node: node, updates: updates) }
            else {
                Text(model.failure ?? "Unable to start")
                Button("Report a problem…") { openWindow(id: "bug-report"); NSApp.activate(ignoringOtherApps: true) }
                Button("Quit Fourth Civ") { NSApp.terminate(nil) }
            }
        } label: {
            MenuBarIconLabel(model: model.menuIcon, updates: updates)
                .task { startup.start(); updates.start() }
        }
        .menuBarExtraStyle(.window)
        Window("Report a problem", id: "bug-report") {
            BugReportView(node: model.node, startupFailure: model.diagnosticFailure)
        }.defaultSize(width: 730, height: 740)
    }
}

struct StatusDot: View {
    @ObservedObject var node: CivNode
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        Circle().fill(color)
            .frame(width: 7, height: 7)
            .accessibilityHidden(true)
    }
    private var color: Color {
        switch node.hostConnection.severity {
        case .error: return .red
        case .warning, .working: return colorScheme == .dark ? Palette.gold : Palette.orange
        case .success: return Palette.online
        case .neutral: return colorScheme == .dark ? Palette.mist : Palette.muted
        }
    }
}
