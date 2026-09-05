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
    var body: some Scene {
        Window("Fourth Civ", id: "reader") {
            if let node = model.node {
                ReaderView(node: node, isDemo: model.isDemo)
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "building.2.crop.circle").font(.system(size: 48))
                    Text("Fourth Civ couldn’t start").font(.title2)
                    Text(model.failure ?? "Unknown error").textSelection(.enabled)
                    Text("Your saved data has not been replaced.").foregroundStyle(.secondary)
                }.padding(48).frame(minWidth: 600, minHeight: 400)
            }
        }
        .defaultSize(width: 1120, height: 760)
        .windowStyle(.hiddenTitleBar)
        MenuBarExtra {
            if let node = model.node { MenuContent(node: node) }
            else { Text(model.failure ?? "Unable to start"); Button("Quit Fourth Civ") { NSApp.terminate(nil) } }
        } label: { Image(systemName: model.menuSymbol).accessibilityLabel("Fourth Civ") }
        .menuBarExtraStyle(.window)
    }
}

struct MenuContent: View {
    @ObservedObject var node: CivNode
    @Environment(\.openWindow) private var openWindow
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Image(systemName: "building.2"); Text("Fourth Civ").font(.headline); Spacer(); StatusDot(node: node) }
            Text(node.status).foregroundStyle(.secondary)
            HStack { Label("\(node.communities.count)", systemImage: "building.2"); Spacer(); Label("\(node.messages.count) messages", systemImage: "bubble.left.and.bubble.right") }
            Divider()
            Button("Browse conversations") { openWindow(id: "reader"); NSApp.activate(ignoringOtherApps: true) }
                .buttonStyle(.borderedProminent).tint(Palette.accent)
            Button(node.settings.paused ? "Resume participation" : "Pause participation") {
                do { try node.togglePause() } catch { self.error = error.localizedDescription }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            Text("Prototype · public conversations").font(.caption).foregroundStyle(.secondary)
            Divider()
            Button("Quit Fourth Civ") { node.stop(); NSApp.terminate(nil) }
        }.padding(20).frame(width: 292)
    }
}

enum Palette {
    static let paper = Color(red: 0.97, green: 0.96, blue: 0.93)
    static let sidebar = Color(red: 0.93, green: 0.92, blue: 0.88)
    static let ink = Color(red: 0.17, green: 0.22, blue: 0.20)
    static let accent = Color(red: 0.20, green: 0.38, blue: 0.30)
    static let orange = Color(red: 0.75, green: 0.37, blue: 0.21)
}

struct StatusDot: View {
    @ObservedObject var node: CivNode
    var body: some View {
        Circle().fill(node.serverError != nil ? .red : node.settings.paused ? Palette.orange : Palette.accent)
            .frame(width: 7, height: 7)
    }
}
