import SwiftUI
import RichContent

/// Email reply: the editor with the email preset, the original below, and
/// the HTML that would be sent.
struct ComposeView: View {
    @StateObject private var editor: RichEditorController = {
        var config = RichEditorConfiguration.email
        config.assetColors = DemoStyle.brandColors
        return RichEditorController(style: .email, configuration: config)
    }()
    @State private var to = "alex@example.com"
    @State private var subject = "Re: Launch plan"
    @State private var showsQuoted = false
    @State private var sentHTML: String?

    private let original: RichContent = .html(DemoSamples.originalEmail)
    private let attribution = "On Oct 28, 2026 at 9:41 AM, Alex Kim <alex@example.com> wrote:"

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    field("To", text: $to)
                    Divider()
                    field("Subject", text: $subject)
                    Divider()
                }
                .padding(.horizontal, 16)

                RichContentEditor(controller: editor, placeholder: "Write your reply…")

                VStack(spacing: 0) {
                    Button {
                        withAnimation(.snappy) { showsQuoted.toggle() }
                    } label: {
                        Label(showsQuoted ? "Hide original" : "Show original", systemImage: "text.quote")
                            .font(.footnote.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .padding(.vertical, 8)

                    if showsQuoted {
                        ScrollView { RichContentView(original) }
                            .frame(maxHeight: 240)
                            .background(Color(.secondarySystemBackground))
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
            .navigationTitle("Reply")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send", systemImage: "paperplane.fill") {
                        sentHTML = editor.replyHTML(quoting: original, attribution: attribution)
                    }
                    .disabled(editor.isEmpty)
                }
            }
            .richContentStyle(.email)
            .richEditorToolbar(editor)
            .sheet(item: Binding(get: { sentHTML.map(SentMail.init) }, set: { sentHTML = $0?.html })) { mail in
                SentMailView(mail: mail, to: to, subject: subject)
            }
        }
    }

    private func field(_ label: String, text: Binding<String>) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            TextField(label, text: text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .padding(.vertical, 10)
    }
}

struct SentMail: Identifiable {
    let html: String
    var id: String { html }
}

/// The message as a mail client would show it, and its HTML source.
private struct SentMailView: View {
    let mail: SentMail
    let to: String
    let subject: String
    @Environment(\.dismiss) private var dismiss
    @State private var showsSource = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(subject).font(.title3.bold())
                        Text("To: \(to)").font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                    Divider()
                    if showsSource {
                        Text(mail.html)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(.horizontal, 16)
                    } else {
                        RichContentView(.html(mail.html))
                    }
                }
                .padding(.vertical)
            }
            .richContentStyle(.email)
            .navigationTitle("Sent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Toggle(isOn: $showsSource) { Image(systemName: "chevron.left.forwardslash.chevron.right") }
                        .toggleStyle(.button)
                        .accessibilityLabel("Show HTML")
                }
            }
        }
    }
}
