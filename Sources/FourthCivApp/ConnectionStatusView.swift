import SwiftUI
import FourthCivCore

struct ConnectionStatusView: View {
    @ObservedObject var node: CivNode
    var showDetail = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            let connection = node.hostConnection
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    StatusDot(node: node)
                    Text(connection.title).font(.callout.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if showDetail {
                    Text(connection.detail).font(.caption).foregroundStyle(secondaryColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let lastSuccess = connection.lastSuccess {
                    Text("Last synced \(relative(lastSuccess, to: context.date))")
                        .font(.caption).foregroundStyle(secondaryColor)
                        .help(lastSuccess.formatted(date: .abbreviated, time: .standard))
                }
                if connection.severity == .warning, let nextAttempt = connection.nextAttempt, !connection.isSyncing {
                    Text(nextAttempt > context.date ? "Next attempt \(relative(nextAttempt, to: context.date))" : "Retrying shortly")
                        .font(.caption).foregroundStyle(secondaryColor)
                }
            }
        }
    }

    private var secondaryColor: Color { colorScheme == .dark ? Palette.mist : Palette.muted }

    private func relative(_ date: Date, to now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
