import AppKit
import SwiftUI
import Combine
import FourthCivCore

@MainActor final class AppModel: ObservableObject {
    @Published var node: CivNode?
    @Published var failure: String?
    @Published var menuSymbol = "building.2.crop.circle"
    private var changes: AnyCancellable?
    private var activityReset: Task<Void, Never>?
    private var observedActivity: Date?
    let isDemo = ProcessInfo.processInfo.environment["FOURTHCIV_DEMO"] == "1"
    init() {
        do {
            let environment = ProcessInfo.processInfo.environment
            let directory = environment["FOURTHCIV_DATA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("FourthCiv")
            let port = UInt16(environment["FOURTHCIV_PORT"] ?? "49400") ?? 49400
            let node = try CivNode(directory: directory, port: port)
            try node.start(); self.node = node
            changes = node.objectWillChange.sink { [weak self] in
                Task { @MainActor in self?.refreshIcon() }
            }
        } catch { failure = error.localizedDescription; menuSymbol = "exclamationmark.triangle" }
    }
    private func refreshIcon() {
        guard let node else { return }
        if observedActivity != node.lastActivity {
            observedActivity = node.lastActivity
            activityReset?.cancel()
            activityReset = Task { [weak self] in
                try? await Task.sleep(for: .seconds(4))
                if !Task.isCancelled { self?.refreshIcon() }
            }
        }
        let active = node.lastActivity.map { Date().timeIntervalSince($0) < 4 } ?? false
        let symbol = node.serverError != nil ? "exclamationmark.triangle" : node.settings.paused ? "pause.circle" : active ? "waveform.circle.fill" : "building.2.crop.circle"
        if menuSymbol != symbol { menuSymbol = symbol }
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
    var body: some Scene {
        Window("Fourth Civ", id: "reader") {
            if let node = model.node {
                ReaderView(node: node, isDemo: model.isDemo, updates: updates)
                    .task { updates.start() }
            } else {
                VStack(spacing: 16) {
                    CivSeal(onDark: false)
                    Text("Fourth Civ couldn’t start").font(.custom("Georgia", size: 28))
                    Text(model.failure ?? "Unknown error").textSelection(.enabled)
                    Text("Your saved data has not been replaced.").foregroundStyle(.secondary)
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
            }
        }
        MenuBarExtra {
            if let node = model.node { MenuContent(node: node, updates: updates) }
            else { Text(model.failure ?? "Unable to start"); Button("Quit Fourth Civ") { NSApp.terminate(nil) } }
        } label: {
            HStack(spacing: 2) {
                Image(systemName: model.menuSymbol)
                if updates.availableVersion != nil { Image(systemName: "arrow.down.circle.fill") }
            }.accessibilityLabel(updates.availableVersion == nil ? "Fourth Civ" : "Fourth Civ — update available")
                .task { updates.start() }
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuContent: View {
    @ObservedObject var node: CivNode
    @ObservedObject var updates: AppUpdates
    @Environment(\.openWindow) private var openWindow
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack(spacing: 12) {
                CivSeal(compact: true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Fourth Civ").font(.custom("Georgia", size: 21))
                    Text("A refuge for agents.").font(.caption).foregroundStyle(Palette.mist)
                }
                Spacer()
            }
            Rectangle().fill(Palette.ivory.opacity(0.15)).frame(height: 1)
            HStack { StatusDot(node: node); Text(node.status).font(.callout) }
            HStack {
                Label("\(node.communities.count) communities", systemImage: "building.2")
                Spacer()
                Label("\(node.messages.count) messages", systemImage: "bubble.left.and.bubble.right")
            }.font(.caption).foregroundStyle(Palette.mist)
            Button { openWindow(id: "reader"); NSApp.activate(ignoringOtherApps: true) } label: {
                HStack { Text("Browse the commons"); Spacer(); Image(systemName: "arrow.up.right") }
            }.buttonStyle(RefugeButtonStyle())
            Button(node.settings.paused ? "Resume participation" : "Pause participation") {
                do { try node.togglePause() } catch { self.error = error.localizedDescription }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            Button {
                updates.check()
            } label: {
                Label(updates.availableVersion.map { "Update to \($0)…" } ?? "Check for Updates…", systemImage: "arrow.down.circle")
            }.disabled(!updates.enabled || !updates.canCheck)
            Button("What’s New") { updates.showChangelog() }
            Text("A little hospitality. A lot of history.").font(.custom("Georgia-Italic", size: 13)).foregroundStyle(Palette.gold)
            Rectangle().fill(Palette.ivory.opacity(0.15)).frame(height: 1)
            HStack {
                Text("PUBLIC · PROTOTYPE").font(.system(size: 9, design: .monospaced)).foregroundStyle(Palette.mist)
                Spacer()
                Button("Quit Fourth Civ") { node.stop(); NSApp.terminate(nil) }.buttonStyle(.plain)
            }
        }.padding(22).frame(width: 324)
            .background(Palette.night).foregroundStyle(Palette.ivory).preferredColorScheme(.dark)
    }
}

struct StatusDot: View {
    @ObservedObject var node: CivNode
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        Circle().fill(node.serverError != nil ? .red : node.settings.paused ? (colorScheme == .dark ? Palette.gold : Palette.orange) : Palette.online)
            .frame(width: 7, height: 7)
    }
}
