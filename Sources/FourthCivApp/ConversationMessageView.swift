import SwiftUI
import FourthCivCore

struct ConversationMessageView: View {
    let event: Event
    let communityTitle: String
    let parent: Event?
    let receivedThisVisit: Bool
    let highlighted: Bool
    let inConversation: Bool
    let conversationCount: Int
    let openConversation: () -> Void
    let openParent: () -> Void
    let inspect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                Text(String(event.attribution.name.prefix(1)).uppercased()).font(.custom("Georgia", size: 18))
                    .foregroundStyle(Palette.accent).frame(width: 35, height: 39)
                    .background(Palette.accent.opacity(0.055))
                    .overlay(Rectangle().stroke(Palette.accent.opacity(0.2)))
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: event.attribution.name).font(.system(size: 13, weight: .semibold))
                    Text(event.shortAuthor + "…").font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.muted)
                        .help("This signing identity distinguishes participants who use the same name. Inspect the signature for the full key.")
                    Text(verbatim: communityTitle).font(.caption).foregroundStyle(Palette.muted)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 5) {
                    Text(event.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption.monospacedDigit()).foregroundStyle(Palette.muted)
                        .help("Date supplied by the author, not the time this Mac received the message.")
                    if receivedThisVisit {
                        Text("Received this visit").font(.caption2).foregroundStyle(Palette.accent)
                    }
                }
            }
            if !event.parent.isEmpty {
                if let parent {
                    Button(action: openParent) {
                        Label { Text(verbatim: "Reply to \(parent.attribution.name)") } icon: { Image(systemName: "arrow.turn.up.left") }
                    }.buttonStyle(.plain).font(.caption).foregroundStyle(Palette.accent)
                        .help("Show the message being replied to")
                } else {
                    Text("Reply to a message not saved on this Mac").font(.caption).foregroundStyle(Palette.muted)
                }
            }
            if highlighted {
                Text("Selected message").font(.caption.weight(.medium)).foregroundStyle(Palette.accent)
            }
            Text(verbatim: event.body).font(.system(size: 14)).lineSpacing(5).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 16) {
                if !inConversation {
                    Button(action: openConversation) {
                        Label("Open conversation · \(conversationCount)", systemImage: "bubble.left.and.bubble.right")
                    }.buttonStyle(.plain)
                }
                Spacer(minLength: 0)
                Button(action: inspect) { Label("Signed · inspect", systemImage: "signature") }.buttonStyle(.plain)
            }.font(.caption).foregroundStyle(Palette.accent).padding(.top, 4)
        }.padding(22).background(Palette.card, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(highlighted ? Palette.accent : Palette.line, lineWidth: highlighted ? 2 : 1))
    }
}
