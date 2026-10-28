import SwiftUI

#if DEBUG
enum RichEditorSamples {
    static let notesHTML = """
    <h1>Launch plan</h1>
    <div>Type <code>/</code> for commands, or Markdown like <strong>- </strong>, <strong>[] </strong>, <strong># </strong>.</div>
    <div data-type="callout" data-emoji="💡" data-color="yellow"><span data-type="callout-emoji">💡</span>&nbsp;Tap the ⋮⋮ handle for block actions, or drag it to move a block.</div>
    <h2>Tasks</h2>
    <ul data-type="todo"><li data-checked="true">Write the spec</li><li data-checked="false">Ship the <span data-color="blue" style="color:#337EA9">editor</span><ul><li>Slash menu</li><li>Block handles</li></ul></li></ul>
    <details><summary>Open questions</summary><ol><li>Tables?</li><li>Mentions?</li></ol></details>
    <blockquote><div>Simple things should be simple.</div></blockquote>
    <pre data-language="swift"><code class="language-swift">let editor = RichEditorController()
    print(editor.html)</code></pre>
    <hr>
    <div>Highlight <span data-highlight="yellow" style="background-color:#FBF3DB">what matters</span>.</div>
    """
}

/// Notion-style notes: every block, toolbar always visible, output sheet.
struct RichEditorNotesDemo: View {
    @StateObject private var editor = RichEditorController(content: .html(RichEditorSamples.notesHTML))
    @State private var showsOutput = false

    var body: some View {
        NavigationStack {
            RichContentEditor(controller: editor, placeholder: "Untitled")
                .navigationTitle("Notes")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Export") { showsOutput = true }
                    }
                }
                .richEditorToolbar(editor)
                .sheet(isPresented: $showsOutput) {
                    RichEditorOutputSheet(editor: editor, preview: .html(editor.html))
                }
        }
        .richContentStyle(.standard)
    }
}

/// Compose-reply demo: email configuration (no toggles / callouts), quoted
/// original below the fold, and an output sheet.
struct RichEditorComposeDemo: View {
    @StateObject private var editor = RichEditorController(configuration: .email)
    @State private var showsOutput = false
    @State private var showsQuoted = false

    private let original: RichContent = .html(RichContentSamples.htmlReply)
    private let attribution = "On 24 Feb 2026 at 3:42 PM, Gunavant Patel <gp@rings.ai> wrote:"

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                RichContentEditor(controller: editor, placeholder: "Write your reply…")

                Button {
                    withAnimation { showsQuoted.toggle() }
                } label: {
                    Label(showsQuoted ? "Hide quoted text" : "Show quoted text", systemImage: "ellipsis")
                        .font(.footnote.weight(.medium))
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .padding(.vertical, 8)

                if showsQuoted {
                    ScrollView { RichContentView(original) }
                        .frame(maxHeight: 220)
                        .transition(.opacity)
                }
            }
            .navigationTitle("Reply")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") { showsOutput = true }
                        .disabled(editor.isEmpty)
                }
            }
            .richEditorToolbar(editor)
            .sheet(isPresented: $showsOutput) {
                RichEditorOutputSheet(editor: editor,
                                      preview: .html(editor.replyHTML(quoting: original, attribution: attribution)))
            }
        }
        .richContentStyle(.email)
        .onAppear { editor.focus() }
    }
}

private struct RichEditorOutputSheet: View {
    @ObservedObject var editor: RichEditorController
    let preview: RichContent
    @State private var tab = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Picker("Output", selection: $tab) {
                    Text("Preview").tag(0)
                    Text("HTML").tag(1)
                    Text("Markdown").tag(2)
                    Text("Plain").tag(3)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)

                ScrollView {
                    switch tab {
                    case 0: RichContentView(preview)
                    case 1: code(editor.html)
                    case 2: code(editor.markdown)
                    default: code(editor.plainText)
                    }
                }
            }
            .padding(.top, 8)
            .navigationTitle("Output")
            .navigationBarTitleDisplayMode(.inline)
        }
        .richContentStyle(.email)
    }

    private func code(_ text: String) -> some View {
        Text(text)
            .font(.system(.footnote, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
    }
}

#Preview("Notes") { RichEditorNotesDemo() }
#Preview("Compose reply") { RichEditorComposeDemo() }
#endif
