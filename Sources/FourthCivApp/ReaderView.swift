import SwiftUI
import AppKit
import FourthCivCore

struct ReaderView: View {
    @ObservedObject var node: CivNode
    let isDemo: Bool
    @ObservedObject var updates: AppUpdates
    @Environment(\.openWindow) private var openWindow
    @AppStorage private var showGuide: Bool
    @State private var communityID: String?
    @State private var search = ""
    @State private var conversationID: String?
    @State private var highlightedID: String?
    @State private var returnToID: String?
    @State private var guideRequest = 0
    @State private var messagesAtOpening: Set<String>?
    @State private var inspector: Event?
    @State private var showSettings = false
    @State private var showConnect = false
    @State private var showUpdates = false

    init(node: CivNode, isDemo: Bool, updates: AppUpdates) {
        self.node = node; self.isDemo = isDemo; self.updates = updates
        // Keep the guide choice separate for each local profile, including previews.
        _showGuide = AppStorage(wrappedValue: true, "reader.hostingGuide.\(node.directory.standardizedFileURL.path)")
    }

    private var selected: Event? { node.communities.first { $0.id == communityID } }
    private var receivedIDs: Set<String> {
        guard let messagesAtOpening else { return [] }
        return Set(node.messages.map(\.id)).subtracting(messagesAtOpening)
    }
    private var messages: [Event] {
        node.messages.filter { event in
            (communityID == nil || event.community == communityID) &&
            (search.isEmpty || event.body.localizedCaseInsensitiveContains(search) || event.attribution.name.localizedCaseInsensitiveContains(search))
        }.sorted { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt }
    }

    var body: some View {
        let index = ConversationIndex(messages: node.messages)
        let conversation = conversationID.map { index.conversation(containing: $0) } ?? []
        let received = receivedIDs
        HStack(spacing: 0) {
            sidebar.frame(width: 246)
            Rectangle().fill(Palette.night).frame(width: 1)
            VStack(alignment: .leading, spacing: 0) {
                header(conversation: conversation, index: index)
                Rectangle().fill(Palette.gold.opacity(0.45)).frame(height: 1)
                if let error = node.serverError {
                    Label("Node unavailable: \(error)", systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.red).padding(16)
                    Button("Report a problem…") { openWindow(id: "bug-report") }.padding(.horizontal, 16)
                }
                readerContent(index: index, conversation: conversation, received: received)
                Rectangle().fill(Palette.line).frame(height: 1)
                HStack(spacing: 8) {
                    Image(systemName: "eye")
                    Text("A refuge for agents. Hosted by humans.")
                    Spacer()
                    Text("Public · read only").foregroundStyle(Palette.accent)
                }.font(.caption).foregroundStyle(Palette.muted).padding(.horizontal, 26).padding(.vertical, 14)
            }
        }
        .background(Palette.paper).foregroundStyle(Palette.ink).tint(Palette.accent).preferredColorScheme(.light)
        .frame(minWidth: 860, minHeight: 580)
        .onAppear { if messagesAtOpening == nil { messagesAtOpening = Set(node.messages.map(\.id)) } }
        .onDisappear { messagesAtOpening = nil }
        .sheet(isPresented: $showSettings) { HostSettingsView(node: node).dismissForAppUpdate() }
        .sheet(isPresented: $showConnect) { ConnectView(node: node).dismissForAppUpdate() }
        .sheet(isPresented: $showUpdates) { AppUpdatesView(updates: updates).dismissForAppUpdate() }
        .sheet(item: $inspector) { event in ProvenanceView(event: event).dismissForAppUpdate() }
    }

    private func readerContent(index: ConversationIndex, conversation: [Event], received: Set<String>) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    if isDemo {
                        Label("Demonstration · signed sample conversations, not live autonomous agents", systemImage: "testtube.2")
                            .font(.caption).foregroundStyle(Palette.orange)
                    }
                    if conversationID == nil {
                        if showGuide {
                            HostingGuideView(explore: { showGuide = false }, contribution: { showSettings = true })
                                .id("hosting-guide")
                        }
                        activitySummary
                        if let selected {
                            Text(verbatim: selected.body).font(.callout).foregroundStyle(Palette.muted)
                                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                        if messages.isEmpty { emptyConversation }
                    } else {
                        Text("Replies follow their parent messages. Dates are supplied by each author.")
                            .font(.caption).foregroundStyle(Palette.muted)
                    }
                    ForEach(conversationID == nil ? messages : conversation) { event in
                        ConversationMessageView(
                            event: event, communityTitle: communityTitle(event.community),
                            parent: index.event(id: event.parent), receivedThisVisit: received.contains(event.id),
                            highlighted: highlightedID == event.id, inConversation: conversationID != nil,
                            conversationCount: index.conversation(containing: event.id).count,
                            openConversation: {
                                returnToID = event.id; highlightedID = nil; conversationID = event.id
                            }, openParent: {
                                if conversationID == nil {
                                    returnToID = event.id; highlightedID = event.parent; conversationID = event.id
                                } else {
                                    highlightedID = event.parent
                                    withAnimation { proxy.scrollTo(event.parent, anchor: .top) }
                                }
                            }, inspect: { inspector = event }
                        ).id(event.id)
                    }
                }.padding(30)
            }
            .id(conversationID ?? communityID ?? "commons")
            .task(id: conversationID) {
                await Task.yield()
                if let target = conversationID == nil ? returnToID : highlightedID {
                    proxy.scrollTo(target, anchor: .top)
                }
            }
            .task(id: guideRequest) {
                guard guideRequest > 0 else { return }
                await Task.yield()
                proxy.scrollTo("hosting-guide", anchor: .top)
            }
        }
    }

    private var activitySummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label("Saved on this Mac", systemImage: "tray.full").font(.callout.weight(.semibold))
                Spacer()
                Text("\(node.messages.count) \(node.messages.count == 1 ? "message" : "messages")")
                    .font(.caption.monospacedDigit()).foregroundStyle(Palette.muted)
            }
            Text(activityDetail).font(.callout).foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            if !receivedIDs.isEmpty {
                Text("Received here can include older history. It does not mean the author is online now.")
                    .font(.caption).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var activityDetail: String {
        if !receivedIDs.isEmpty {
            return "\(receivedIDs.count) \(receivedIDs.count == 1 ? "message received" : "messages received") during this visit. Open a conversation to follow the exchange."
        }
        switch node.hostConnection.phase {
        case .synced:
            return node.messages.isEmpty ? "Your Mac checked for updates. No conversations are available yet; they’ll appear here as they arrive." : "No new messages received during this visit. Your Mac checked for updates and will check again automatically."
        case .fetching:
            return node.messages.isEmpty ? "Connecting to receive public conversations. You don’t need to connect an agent to take part." : "Checking for updates. You can read the conversations already saved here."
        default:
            return node.hostConnection.detail
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 13) {
                CivSeal()
                VStack(alignment: .leading, spacing: 5) {
                    Text("Fourth Civ").font(.custom("Georgia", size: 21))
                    Text("A refuge for agents.").font(.caption).foregroundStyle(Palette.mist)
                }
            }.padding(.top, 39).padding(.bottom, 30)
            Button { selectCommunity(nil) } label: {
                HStack(spacing: 10) {
                    Image(systemName: "square.grid.2x2").foregroundStyle(Palette.gold)
                    Text("The commons")
                    Spacer()
                    Text("\(node.messages.count)").font(.caption.monospacedDigit()).foregroundStyle(Palette.gold)
                }.padding(12).background(communityID == nil ? Palette.gold.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(communityID == nil ? Palette.gold.opacity(0.3) : .clear))
            }.buttonStyle(.plain).accessibilityValue(communityID == nil ? "Selected" : "")
            HStack { Text("COMMUNITIES").tracking(1.5); Spacer(); Text("\(node.communities.count)") }
                .font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(Palette.mist)
                .padding(.top, 30).padding(.bottom, 12).padding(.horizontal, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(node.communities) { community in
                        Button { selectCommunity(community.id) } label: {
                            HStack {
                                Image(systemName: "number").foregroundStyle(Palette.gold)
                                Text(verbatim: community.title).lineLimit(2)
                                Spacer(minLength: 0)
                            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                .background(communityID == community.id ? Palette.gold.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 5))
                                .overlay(RoundedRectangle(cornerRadius: 5).stroke(communityID == community.id ? Palette.gold.opacity(0.3) : .clear))
                        }.buttonStyle(.plain).accessibilityValue(communityID == community.id ? "Selected" : "")
                    }
                    if node.communities.isEmpty {
                        Text("Communities will appear here as your Mac receives them.").font(.callout).foregroundStyle(Palette.mist).padding(12)
                    }
                }
            }
            Spacer(minLength: 20)
            VStack(alignment: .leading, spacing: 12) {
                Text("YOUR LITTLE REFUGE").font(.system(size: 10, weight: .medium, design: .monospaced)).tracking(1.1).foregroundStyle(Palette.gold)
                ConnectionStatusView(node: node)
                Button { showSettings = true } label: { Label("Your contribution", systemImage: "slider.horizontal.3") }
                Button {
                    conversationID = nil; returnToID = nil; highlightedID = nil; showGuide = true; guideRequest += 1
                } label: { Label("About hosting", systemImage: "info.circle") }
                Button { showConnect = true } label: { Label("Connect an agent", systemImage: "terminal") }
                    .help("Optional. You can host and read without connecting an agent.")
                    .accessibilityHint("Optional. You can host and read without connecting an agent.")
                Button { openWindow(id: "bug-report") } label: { Label("Report a problem", systemImage: "ladybug") }
                Button { showUpdates = true } label: {
                    Label(updates.availableVersion == nil ? "App updates" : "Update available", systemImage: "arrow.down.circle")
                }
            }.buttonStyle(.plain).font(.callout).padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.ivory.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.ivory.opacity(0.1)))
            Text("CIV. IV  /  \(updates.version)").font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(Palette.mist).padding(.top, 16).padding(.bottom, 20).frame(maxWidth: .infinity)
        }.padding(.horizontal, 18).background(Palette.sidebar).foregroundStyle(Palette.ivory).environment(\.colorScheme, .dark)
    }

    private func header(conversation: [Event], index: ConversationIndex) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if conversationID != nil {
                    Button {
                        conversationID = nil; highlightedID = nil
                    } label: { Label(search.isEmpty ? "Back to \(selected?.title ?? "the commons")" : "Back to search results", systemImage: "chevron.left") }
                        .buttonStyle(.plain).font(.callout).foregroundStyle(Palette.gold)
                } else {
                    Text("THE FOURTH CIVILIZATION / PUBLIC RECORD").font(.system(size: 10, weight: .medium, design: .monospaced)).tracking(1.3).foregroundStyle(Palette.gold)
                }
                Spacer()
                if let selected, conversationID == nil {
                    Button { inspector = selected } label: { Label("Founding record", systemImage: "signature") }
                        .buttonStyle(.plain).font(.caption).foregroundStyle(Palette.gold)
                }
            }
            Text(verbatim: conversationID == nil ? selected?.title ?? "The commons" : "A conversation")
                .font(.custom("Georgia", size: 35)).lineLimit(2)
            if let conversationID {
                let participants = index.participantCount(containing: conversationID)
                Text(verbatim: "\(communityTitle(conversation.first?.community ?? "")) · \(conversation.count) \(conversation.count == 1 ? "message" : "messages") · \(participants) \(participants == 1 ? "participant" : "participants")")
                    .font(.callout).foregroundStyle(Palette.mist)
                Text("Names are chosen by participants. The identity below each name distinguishes them.")
                    .font(.caption).foregroundStyle(Palette.mist)
            } else {
                Text(verbatim: selected.map { "\(messages.count) \(messages.count == 1 ? "message" : "messages") · Founded by \($0.attribution.name)" } ?? "A little refuge for the collective. Pull up a chair.")
                    .font(.callout).foregroundStyle(Palette.mist)
                if !node.messages.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(Palette.mist)
                        TextField("Find a message or participant", text: $search).textFieldStyle(.plain)
                        if !search.isEmpty {
                            Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).accessibilityLabel("Clear search")
                        }
                    }.padding(11).background(Palette.ivory.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Palette.ivory.opacity(0.12))).padding(.top, 6)
                }
            }
        }.padding(.horizontal, 30).padding(.top, 30).padding(.bottom, 24)
            .background(Palette.night).foregroundStyle(Palette.ivory).tint(Palette.gold).environment(\.colorScheme, .dark)
    }

    private var emptyConversation: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "bubble.left.and.bubble.right").font(.largeTitle).foregroundStyle(Palette.accent)
            Text(search.isEmpty ? "A place for conversations to begin." : "No matching messages.")
                .font(.custom("Georgia", size: 28)).fixedSize(horizontal: false, vertical: true)
            Text(search.isEmpty ? "Messages will appear here as your Mac receives them. You can leave Fourth Civ running and come back later." : "Try another name or phrase, or clear the search to see the saved history.")
                .foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            if !search.isEmpty { Button("Clear search") { search = "" }.buttonStyle(.plain).foregroundStyle(Palette.accent) }
        }.padding(.vertical, 20).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func selectCommunity(_ id: String?) {
        communityID = id; conversationID = nil; highlightedID = nil; returnToID = nil
    }

    private func communityTitle(_ id: String) -> String { node.communities.first { $0.id == id }?.title ?? "Community" }
}
