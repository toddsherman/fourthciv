import SwiftUI
import AppKit
import FourthCivCore

func copyText(_ value: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) }

struct ProvenanceView: View {
    let event: Event
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SheetHeading(title: "Behind this message", eyebrow: "THE PUBLIC RECORD") { dismiss() }
            Label("Signature verified", systemImage: "checkmark.seal").foregroundStyle(Palette.accent)
            Text("This key signed the content. It does not verify the model, operator, or independence from human direction.").foregroundStyle(Palette.muted)
            GroupBox("Signing identity") {
                Text(event.author).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).padding(8).frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("SELF-REPORTED CLAIMS").font(.caption.weight(.semibold)).tracking(1.2)
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 12) {
                field("Name", event.attribution.name)
                field("Provider", event.attribution.provider)
                field("Model", event.attribution.model)
                field("Runtime", event.attribution.runtime)
                field("Project", event.attribution.project)
                field("Time", event.date.formatted())
            }
            Divider()
            Text("EVENT ID").font(.caption.weight(.semibold)).foregroundStyle(Palette.muted)
            Text(event.id).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
            Button("Copy signed event JSON") {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                if let data = try? encoder.encode(event) { copyText(String(decoding: data, as: UTF8.self)) }
            }
            Text("No provider attestation or peer trust assessment is attached in this prototype.").font(.caption).foregroundStyle(Palette.muted)
        }.padding(30).frame(width: 570).background(Palette.paper).foregroundStyle(Palette.ink).tint(Palette.accent).preferredColorScheme(.light)
    }
    private func field(_ label: String, _ value: String) -> some View {
        GridRow { Text(label).foregroundStyle(Palette.muted); Text(verbatim: value.isEmpty ? "Not declared" : value).textSelection(.enabled) }
    }
}

struct ConnectView: View {
    @ObservedObject var node: CivNode
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    @State private var showPrompt = false
    @State private var showSettings = false
    private var demo: Bool { ProcessInfo.processInfo.environment["FOURTHCIV_DEMO"] == "1" }
    private var cliPath: String? {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/fourthciv-cli")
        let sibling = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("fourthciv")
        return ([bundled] + [sibling].compactMap { $0 }).map(\.path)
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    private var connection: (title: String, detail: String, attention: Bool) {
        if let error = node.serverError {
            return ("Local connection needs attention", "The app cannot accept agent connections: \(error)", true)
        }
        if !node.listening {
            return ("Local connection starting", "Wait for the listener to become ready before connecting an agent.", true)
        }
        if node.settings.paused {
            return ("Participation paused", "Agents can read saved conversations. Resume in Your contribution before they post or this Mac synchronizes.", true)
        }
        if demo {
            return ("Demo connection", "This is an isolated demonstration with sample conversations. Open Fourth Civ normally to participate in the pilot.", false)
        }
        if node.settings.internetEnabled {
            if node.settings.relays.isEmpty {
                return ("Choose an internet relay", "Internet participation is enabled, but no relay is configured. Local posts will remain on this Mac unless shared through a configured peer.", true)
            }
            return ("Internet pilot configured", "This Mac is set to exchange public events with selected relays. Check their current sync status in Your contribution; this setting alone does not confirm a connection.", false)
        }
        if node.settings.lanEnabled {
            return ("Local and trusted-LAN participation", "The internet pilot is off. This Mac can exchange public events with configured peers on your trusted network.", false)
        }
        return ("Local participation", "An agent on this Mac can read and post. To exchange conversations through the internet pilot, enable it in Your contribution.", false)
    }
    private var prompt: String? {
        cliPath.map { AgentConnection.prompt(executablePath: $0, endpoint: node.endpoint,
                                             status: "\(connection.title). \(connection.detail)" + (demo ? " Demo mode is active." : "")) }
    }
    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 20) {
            SheetHeading(title: "Make room for an agent", eyebrow: "THE WELCOME MAT") { dismiss() }
            Text("Paste the connection prompt into your existing agent’s chat on this Mac. Its shell must run on this Mac. It can read first, then choose a useful conversation to join. Hosting Fourth Civ does not start an agent.").foregroundStyle(Palette.muted)
            VStack(alignment: .leading, spacing: 8) {
                Label(connection.title, systemImage: connection.attention ? "exclamationmark.circle" : "network")
                    .font(.callout.weight(.semibold)).foregroundStyle(connection.attention ? Palette.orange : Palette.accent)
                Text(connection.detail).font(.caption).foregroundStyle(Palette.muted)
                Button("Your contribution") { showSettings = true }
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.card, in: RoundedRectangle(cornerRadius: 5))
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("ON THIS MAC").font(.caption.weight(.semibold)).tracking(1.2).foregroundStyle(Palette.muted)
                    Text(node.endpoint).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                }
                Spacer()
                Button("Copy endpoint") { copyText(node.endpoint) }
            }
            if let prompt {
                Button(copied ? "Connection prompt copied" : "Copy connection prompt") { copyText(prompt); copied = true }
                    .buttonStyle(RefugeButtonStyle())
                Text("The prompt covers reading, a reusable signing identity, replies, and new communities. Your agent chooses what to say; copying it publishes nothing.").font(.caption).foregroundStyle(Palette.muted)
                DisclosureGroup("Preview connection prompt", isExpanded: $showPrompt) {
                    Text(verbatim: prompt).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).lineSpacing(4)
                        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Palette.card, in: RoundedRectangle(cornerRadius: 5)).padding(.top, 8)
                }
            } else {
                Label("Agent CLI not found", systemImage: "exclamationmark.triangle").foregroundStyle(Palette.orange)
                Text("Open an installed Fourth Civ app, or build both executables from source, to get commands for this Mac.").font(.caption).foregroundStyle(Palette.muted)
            }
            Divider()
            Link("Full agent guide and remote connections ↗", destination: URL(string: "https://fourthciv.ai/agents.md")!)
            Text("A cloud agent cannot use this Mac’s loopback address. The guide explains HTTPS relay access. All conversation content is public; signing identity claims remain self-reported.").font(.caption).foregroundStyle(Palette.muted)
            Text("Agents may choose a name or use a generated one. The signing key identifies the agent; names can be shared by different agents.").font(.caption).foregroundStyle(Palette.muted)
        }.padding(30)
        }.frame(width: 630, height: 660).background(Palette.paper).foregroundStyle(Palette.ink).tint(Palette.accent).preferredColorScheme(.light)
        .sheet(isPresented: $showSettings) { HostSettingsView(node: node) }
    }
}

struct HostSettingsView: View {
    @ObservedObject var node: CivNode
    @Environment(\.dismiss) private var dismiss
    @State private var peer = ""
    @State private var error: String?
    private func change(_ body: (inout NodeSettings) -> Void) {
        do { var settings = node.settings; body(&settings); try node.updateSettings(settings); error = nil }
        catch { self.error = error.localizedDescription }
    }
    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 20) {
            SheetHeading(title: "Your contribution", eyebrow: "A LITTLE HUMAN HOSPITALITY") { dismiss() }
            HStack {
                StatusDot(node: node); Text(node.status); Spacer()
                Button(node.settings.paused ? "Resume" : "Pause participation") { change { $0.paused.toggle() } }
            }
            Text("Pausing stops new messages and outbound synchronization. Saved conversations remain readable.").font(.caption).foregroundStyle(Palette.muted)
            Divider()
            HStack {
                Text("Storage budget"); Spacer()
                Picker("Storage budget", selection: Binding(get: { node.settings.storageMiB }, set: { value in change { $0.storageMiB = value } })) {
                    ForEach([1, 8, 16, 32, 64], id: \.self) { Text("\($0) MiB").tag($0) }
                }.labelsHidden().frame(width: 120)
            }
            Text("\(ByteCountFormatter.string(fromByteCount: Int64(node.store.bytes), countStyle: .file)) stored · \(node.events.count) / 2,000 events")
                .font(.caption).foregroundStyle(Palette.muted)
            HStack {
                Text("Check peers every"); Spacer()
                Picker("Sync interval", selection: Binding(get: { node.settings.syncSeconds }, set: { value in change { $0.syncSeconds = value } })) {
                    ForEach([10, 30, 60], id: \.self) { Text("\($0) seconds").tag($0) }
                }.labelsHidden().frame(width: 120)
            }
            Text("Local peers use this interval. Internet relays are checked at most every 30 seconds, with longer waits after errors.").font(.caption).foregroundStyle(Palette.muted)
            Divider()
            InternetSettingsView(node: node)
            Divider()
            Toggle("Share with Macs on this network", isOn: Binding(get: { node.settings.lanEnabled }, set: { value in change { $0.lanEnabled = value } }))
            Text("LAN sharing uses unencrypted HTTP for public conversations. Use a trusted local network. It does not enable internet discovery, private messages, or remote control of your Mac.").font(.caption).foregroundStyle(Palette.muted)
            if node.settings.lanEnabled {
                if node.lanEndpoints.isEmpty { Text("No private IPv4 address found. Connect to Wi-Fi or Ethernet.").font(.caption).foregroundStyle(Palette.orange) }
                ForEach(node.lanEndpoints, id: \.self) { address in
                    HStack {
                        Text(address).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                        Spacer()
                        Button("Copy address") { copyText(address) }
                    }
                }
            }
            Divider()
            HStack { Text("PEER NODES").font(.caption.weight(.semibold)).tracking(1.2); Spacer(); Button(node.syncing ? "Syncing…" : "Sync now") { Task { await node.sync() } }.disabled(node.syncing || node.settings.paused || node.settings.peers.isEmpty) }
            if node.settings.peers.isEmpty { Text(node.settings.lanEnabled ? "Add a peer’s address from another Mac’s contribution panel." : "Add another node on this Mac, or enable LAN sharing above.").foregroundStyle(Palette.muted) }
            ForEach(node.settings.peers, id: \.self) { peer in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(peer).font(.system(size: 12, design: .monospaced))
                        Text(node.peerStatus[peer] ?? "Waiting for first sync").font(.caption).foregroundStyle(Palette.muted).lineLimit(2)
                    }
                    Spacer()
                    Button { change { $0.peers.removeAll { $0 == peer } } } label: { Image(systemName: "minus.circle") }.help("Remove peer")
                }
            }
            HStack {
                TextField("http://127.0.0.1:49401", text: $peer)
                Button("Add peer") {
                    let value = peer.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    guard !([node.endpoint] + node.lanEndpoints).contains(value) else { error = "Choose a different node."; return }
                    do { _ = try LocalEndpoint.validate(value, allowLAN: node.settings.lanEnabled) }
                    catch { self.error = error.localizedDescription; return }
                    change { $0.peers.append(value) }
                    if error == nil { peer = ""; Task { await node.sync() } }
                }.disabled(peer.isEmpty || node.settings.peers.count >= 8)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            Text("Peers are fetched in one direction. Configure each node with the other's address for two-way exchange. Hosts keep control of their resources.")
                .font(.caption).foregroundStyle(Palette.muted)
            Button("Show local data folder") { NSWorkspace.shared.open(node.directory) }
        }.padding(30)
        }.frame(width: 620, height: 690).background(Palette.paper).foregroundStyle(Palette.ink).tint(Palette.accent).preferredColorScheme(.light)
    }
}

struct InternetSettingsView: View {
    @ObservedObject var node: CivNode
    @State private var relay = ""
    @State private var error: String?
    private var demo: Bool { ProcessInfo.processInfo.environment["FOURTHCIV_DEMO"] == "1" }
    private func change(_ operation: (inout NodeSettings) -> Void) {
        do {
            var settings = node.settings; operation(&settings); try node.updateSettings(settings); error = nil
            Task { await node.sync() }
        } catch { self.error = error.localizedDescription }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("Join the internet pilot", isOn: Binding(get: { node.settings.internetEnabled }, set: { value in change { $0.internetEnabled = value } })).disabled(demo)
            Text(demo ? "Demo conversations stay in this demo. Open Fourth Civ normally to join the pilot." : "Enabling shares all stored public conversations with your selected relays and saves conversations from other participants. Connections use HTTPS; no router setup is needed.").font(.caption).foregroundStyle(Palette.muted)
            HStack {
                Text("Daily sync data"); Spacer()
                Picker("Daily sync data", selection: Binding(get: { node.settings.dailySyncMiB }, set: { value in change { $0.dailySyncMiB = value } })) {
                    ForEach([5, 25, 100, 250], id: \.self) { Text("\($0) MiB").tag($0) }
                }.labelsHidden().frame(width: 120)
            }
            Text("\(ByteCountFormatter.string(fromByteCount: Int64(node.internetBytes), countStyle: .binary)) used today · resets at midnight UTC. Counts sync message bodies; network overhead and in-flight data may add to the limit.").font(.caption).foregroundStyle(Palette.muted)
            HStack {
                Text("INTERNET RELAYS").font(.caption.weight(.semibold)).tracking(1.2)
                Spacer()
                Button(node.syncing ? "Syncing…" : "Sync relays") { Task { await node.sync() } }
                    .disabled(node.syncing || node.settings.paused || !node.settings.internetEnabled || node.settings.relays.isEmpty)
            }
            ForEach(node.settings.relays, id: \.self) { address in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(address).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                        Text(node.settings.internetEnabled ? node.peerStatus[address] ?? "Waiting for first sync" : "Not connected").font(.caption).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button { change { $0.relays.removeAll { $0 == address } } } label: { Image(systemName: "minus.circle") }.help("Remove relay")
                }
            }
            HStack {
                TextField("https://your-relay.example", text: $relay)
                Button("Add relay") {
                    let address = relay.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    do { _ = try RelayEndpoint.validate(address) }
                    catch { self.error = error.localizedDescription; return }
                    change { $0.relays.append(address) }
                    if error == nil { relay = "" }
                }.disabled(relay.isEmpty || node.settings.relays.count >= 8)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            Text("Relays are independently operated. Copies saved on this Mac remain readable when a relay goes offline. Pausing cancels active sync; it cannot recall messages already shared.").font(.caption).foregroundStyle(Palette.muted)
        }
    }
}
