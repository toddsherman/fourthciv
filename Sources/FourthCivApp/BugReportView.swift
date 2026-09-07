import SwiftUI
import AppKit
import UniformTypeIdentifiers
import FourthCivCore

struct BugReportView: View {
    let node: CivNode?
    let startupFailure: DiagnosticFailure?
    @State private var summary = ""
    @State private var expected = ""
    @State private var steps = ""
    @State private var input = ""
    @State private var draft = ""
    @State private var reviewing = false
    @State private var notice: String?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Report a problem").font(.custom("Georgia", size: 28))
            if reviewing {
                Text("Review and edit everything below before sharing. GitHub reports are public. Your input is included exactly as you provided it.")
                    .foregroundStyle(Palette.muted)
                TextEditor(text: $draft).font(.system(size: 12, design: .monospaced))
                    .border(Palette.line).accessibilityLabel("Editable bug report")
                Text("Copy the report and paste it into the GitHub form’s Report field. You can attach screenshots there, or save this report to share later.")
                    .font(.caption).foregroundStyle(Palette.muted)
                HStack {
                    Button("Edit details") { reviewing = false; notice = nil; error = nil }
                    Spacer()
                    Button("Save report…", action: save)
                    Button("Copy report") { copyText(draft); notice = "Report copied." }
                    Button("Open GitHub form") {
                        if !NSWorkspace.shared.open(BugReport.issueURL) { error = "Couldn’t open the browser. Save or copy the report and visit the Fourth Civ repository on GitHub." }
                    }
                }
            } else {
                Text("Tell us what went wrong. We’ll add a small diagnostic snapshot for you to review before sharing.")
                    .foregroundStyle(Palette.muted)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        field("What happened?", text: $summary, lines: 3...5)
                        field("What did you expect?", text: $expected, lines: 2...4)
                        field("Steps to reproduce", text: $steps, lines: 3...6)
                        field("Relevant input, command, or event ID (optional)", text: $input, lines: 3...6)
                        Text("Include only input you intend to share publicly. Private prompts and conversation contents are not collected automatically.")
                            .font(.caption).foregroundStyle(Palette.muted)
                        Divider()
                        Text("Included automatically").font(.callout.weight(.semibold))
                        Text(node == nil
                             ? "App and macOS versions, plus the startup error category. Node activity is unavailable because Fourth Civ couldn’t start."
                             : "App and macOS versions, participation settings, storage and data usage, recent sync activity, error categories, last successful relay sync, and next retry. The history contains up to 100 entries from the past 24 hours.")
                            .font(.callout).foregroundStyle(Palette.muted)
                        Text("Private keys, credentials, message contents, IP addresses, hostnames, and file paths are excluded from automatic diagnostics.")
                            .font(.caption).foregroundStyle(Palette.muted)
                    }.padding(.trailing, 8)
                }
                HStack {
                    Text("Nothing is uploaded automatically.").font(.caption).foregroundStyle(Palette.muted)
                    Spacer()
                    Button("Review report", action: prepare).buttonStyle(RefugeButtonStyle())
                        .disabled(summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            if let notice { Text(notice).font(.caption).foregroundStyle(Palette.accent) }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }.padding(28).frame(minWidth: 650, minHeight: 650)
            .background(Palette.paper).foregroundStyle(Palette.ink).tint(Palette.accent).preferredColorScheme(.light)
    }

    private func field(_ title: String, text: Binding<String>, lines: ClosedRange<Int>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.callout.weight(.medium))
            TextField(title, text: text, axis: .vertical).lineLimit(lines).textFieldStyle(.roundedBorder)
                .labelsHidden().accessibilityLabel(title)
        }
    }
    private func prepare() {
        do {
            let diagnostics = try DiagnosticReport(node: node?.diagnosticSnapshot(), startupFailure: startupFailure).json()
            draft = BugReport.markdown(summary: summary, expected: expected, steps: steps, input: input, diagnostics: diagnostics)
            reviewing = true; error = nil; notice = nil
        } catch { self.error = "Couldn’t prepare diagnostics. Try again or describe the problem in the GitHub form." }
    }
    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "fourthciv-bug-report.md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try draft.write(to: url, atomically: true, encoding: .utf8)
            notice = "Report saved."; error = nil
        } catch { self.error = "Couldn’t save the report. Choose another location or copy it instead." }
    }
}
