import AppKit
import SwiftUI
import FourthCivCore

struct MenuContent: View {
    @ObservedObject var node: CivNode
    @ObservedObject var updates: AppUpdates
    @Environment(\.openWindow) private var openWindow
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            connection
            VStack(spacing: 10) {
                Button { openReader() } label: {
                    HStack {
                        Text("Browse the commons")
                        Spacer()
                        Image(systemName: "arrow.up.right").font(.system(size: 12, weight: .semibold))
                    }
                }.buttonStyle(RefugeButtonStyle())
                Text("\(node.communities.count) \(node.communities.count == 1 ? "community" : "communities") · \(node.messages.count) \(node.messages.count == 1 ? "message" : "messages")")
                    .font(.system(size: 11).monospacedDigit()).foregroundStyle(Palette.mist)
            }
            VStack(spacing: 12) {
                Rectangle().fill(Palette.ivory.opacity(0.12)).frame(height: 1)
                HStack {
                    updateStatus
                    Spacer(minLength: 12)
                    Button("Quit") { node.stop(); NSApp.terminate(nil) }
                        .buttonStyle(MenuUtilityButtonStyle())
                        .help("Quit Fourth Civ")
                        .accessibilityLabel("Quit Fourth Civ")
                }
            }
        }
        .padding(20).frame(width: 336)
        .background(Palette.night).foregroundStyle(Palette.ivory).preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(spacing: 11) {
            CivSeal(compact: true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Fourth Civ").font(.custom("Georgia", size: 21))
                Text(updates.version).font(.system(size: 10)).foregroundStyle(Palette.mist)
            }
            Spacer()
            Menu {
                Button("What’s New") { updates.showChangelog() }
                Button("Report a problem…") {
                    openWindow(id: "bug-report")
                    NSApp.activate(ignoringOtherApps: true)
                }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Palette.mist).frame(width: 28, height: 28)
                    .contentShape(RoundedRectangle(cornerRadius: 5))
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("More options").help("More options")
        }
    }

    private var connection: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    HStack(spacing: 7) {
                        StatusDot(node: node)
                        Text(connectionTitle).font(.system(size: 12, weight: .semibold))
                            .fixedSize(horizontal: false, vertical: true)
                    }.help(node.hostConnection.detail)
                    Spacer(minLength: 0)
                    Button {
                        do { try node.togglePause(); error = nil }
                        catch { self.error = error.localizedDescription }
                    } label: {
                        Label(node.settings.paused ? "Resume" : "Pause",
                              systemImage: node.settings.paused ? "play.fill" : "pause.fill")
                    }
                    .buttonStyle(MenuUtilityButtonStyle(bordered: true))
                    .fixedSize()
                    .accessibilityLabel(node.settings.paused ? "Resume participation" : "Pause participation")
                }
                Text(connectionSummary(at: context.date))
                    .font(.system(size: 11)).foregroundStyle(Palette.mist)
                    .fixedSize(horizontal: false, vertical: true)
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.ivory.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.ivory.opacity(0.08)))
        }
    }

    @ViewBuilder private var updateStatus: some View {
        switch updates.status {
        case .available:
            Button { updates.check() } label: {
                Label("Install update", systemImage: "arrow.down.circle")
            }
            .buttonStyle(MenuUtilityButtonStyle(accented: true))
            .disabled(!updates.enabled || !updates.canCheck)
            .help(updates.availableVersion.map { "Version \($0) is available" } ?? "Install the available update")
        case .checking:
            Label("Checking for updates…", systemImage: "arrow.triangle.2.circlepath")
                .font(.system(size: 11)).foregroundStyle(Palette.mist)
        case .upToDate:
            Label("Up to date", systemImage: "checkmark.circle")
                .font(.system(size: 11)).foregroundStyle(Palette.mist)
        case .failed:
            Button { updates.check() } label: {
                Label("Retry update check", systemImage: "arrow.clockwise")
            }
            .buttonStyle(MenuUtilityButtonStyle())
            .disabled(!updates.canCheck)
            .help(updates.failure ?? "Unable to check for updates")
        case .notChecked:
            Label(updates.automaticallyChecks ? "Updates scheduled" : "Update checks off", systemImage: "clock")
                .font(.system(size: 11)).foregroundStyle(Palette.mist)
        case .unavailable:
            Label(updates.enabled ? "Update unavailable" : "Development build",
                  systemImage: updates.enabled ? "exclamationmark.circle" : "hammer")
                .font(.system(size: 11)).foregroundStyle(Palette.mist)
                .help(updates.failure ?? "In-app updates are available in release builds.")
        }
    }

    private var connectionTitle: String {
        switch node.hostConnection.phase {
        case .fetching: return node.hostConnection.isSyncing ? "Syncing conversations" : "Connecting"
        case .synced: return "Conversations synced"
        case .retrying: return "Reconnecting"
        case .partiallyConnected: return "Partially connected"
        case .paused: return "Participation paused"
        case .internetDisabled: return "Internet sharing off"
        case .noRelays: return "No relay configured"
        case .dataLimitReached: return "Daily sync limit reached"
        case .storageLimitReached: return "Storage limit reached"
        case .needsAttention: return "Connection needs attention"
        }
    }

    private func connectionSummary(at date: Date) -> String {
        let connection = node.hostConnection
        switch connection.phase {
        case .synced:
            guard let lastSuccess = connection.lastSuccess else { return connection.detail }
            if date.timeIntervalSince(lastSuccess) < 10 { return "Last synced just now" }
            return "Last synced \(relative(lastSuccess, to: date))"
        case .fetching: return "Receiving and sharing public conversations."
        case .paused: return "Saved conversations remain available."
        case .retrying:
            guard let nextAttempt = connection.nextAttempt, nextAttempt > date else { return "Retrying automatically. Saved conversations are available." }
            return "Retrying \(relative(nextAttempt, to: date)). Saved conversations are available."
        default: return connection.detail
        }
    }

    private func relative(_ date: Date, to now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }

    private func openReader() {
        openWindow(id: "reader")
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct MenuUtilityButtonStyle: ButtonStyle {
    var bordered = false
    var accented = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: bordered || accented ? .medium : .regular))
            .foregroundStyle(accented ? Palette.gold : Palette.mist)
            .padding(.horizontal, bordered ? 8 : 3).padding(.vertical, 5)
            .background(Palette.ivory.opacity(configuration.isPressed ? 0.14 : bordered ? 0.06 : 0),
                        in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Palette.ivory.opacity(bordered ? 0.1 : 0)))
            .contentShape(RoundedRectangle(cornerRadius: 5))
            .opacity(isEnabled ? 1 : 0.45)
    }
}
