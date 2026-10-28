import SwiftUI
import RichContent

struct NotesView: View {
    @EnvironmentObject private var store: NotesStore
    @State private var path: [UUID] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                ForEach(store.notes) { note in
                    NavigationLink(value: note.id) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(store.summaries[note.id]?.title ?? "Untitled")
                                .font(.headline)
                                .lineLimit(1)
                            HStack(spacing: 6) {
                                Text(note.updated, format: .relative(presentation: .named))
                                Text(store.summaries[note.id]?.preview ?? "")
                                    .lineLimit(1)
                            }
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .onDelete { offsets in store.delete(offsets.map { store.notes[$0].id }) }
            }
            .navigationTitle("Notes")
            .navigationDestination(for: UUID.self) { id in
                if let note = store.note(id) {
                    NoteEditorView(note: note)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button("Restore Sample Notes", systemImage: "arrow.counterclockwise") { store.resetSamples() }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("New Note", systemImage: "square.and.pencil") {
                        path.append(store.add().id)
                    }
                }
            }
        }
    }
}

/// One note in the editor. Saves as you type (debounced).
struct NoteEditorView: View {
    @EnvironmentObject private var store: NotesStore
    @StateObject private var editor: RichEditorController
    @State private var showsExport = false
    @State private var showsSettings = false
    @State private var saveTask: Task<Void, Never>?
    @AppStorage("editorPadding") private var editorPadding = 32.0
    private let noteID: UUID
    private let isNew: Bool

    init(note: Note) {
        noteID = note.id
        isNew = note.html.isEmpty
        _editor = StateObject(wrappedValue: RichEditorController(style: DemoStyle.notes, content: .html(note.html),
                                                                 configuration: DemoStyle.editorConfiguration))
    }

    var body: some View {
        RichContentEditor(controller: editor, placeholder: "Untitled")
            .richContentStyle { $0.editorHorizontalPadding = editorPadding }   // live, from Settings
            .richContentStyle(DemoStyle.notes)
            .richEditorToolbar(editor)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .tabBar)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("Settings", systemImage: "slider.horizontal.3") { showsSettings = true }
                    Button("Export", systemImage: "square.and.arrow.up") { showsExport = true }
                }
            }
            .sheet(isPresented: $showsExport) {
                ExportView(editor: editor)
            }
            .sheet(isPresented: $showsSettings) {
                EditorSettingsView(editor: editor)
                    .presentationDetents([.medium, .large])
            }
            .onAppear {
                editor.onChange = { controller in
                    saveTask?.cancel()
                    saveTask = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(400))
                        guard !Task.isCancelled else { return }
                        store.update(noteID, html: controller.html)
                    }
                }
                if isNew {
                    editor.setBlock(.heading1)
                    editor.focus()
                }
            }
            .onDisappear {
                saveTask?.cancel()
                store.update(noteID, html: editor.html)
            }
    }
}

enum DemoStyle {
    static var editorConfiguration: RichEditorConfiguration { RichEditorConfiguration() }

    static var notes: RichContentStyle {
        var style = RichContentStyle.standard
        style.horizontalPadding = 14
        style.editorHorizontalPadding = 32   // editor margin, both sides (nil = automatic)
        style.verticalPadding = 12
        style.paragraphSpacing = 8
        return style
    }
}

// MARK: - Export

/// What the app would save or send: HTML, Markdown, plain text, rendered.
struct ExportView: View {
    @ObservedObject var editor: RichEditorController
    @Environment(\.dismiss) private var dismiss
    @State private var format = Format.preview

    enum Format: String, CaseIterable {
        case preview = "Preview", html = "HTML", markdown = "Markdown", plain = "Plain"
    }

    private var text: String {
        switch format {
        case .preview, .html: return editor.html
        case .markdown: return editor.markdown
        case .plain: return editor.plainText
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Format", selection: $format) {
                    ForEach(Format.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .padding()

                ScrollView {
                    if format == .preview {
                        RichContentView(.html(editor.html))
                            .richContentStyle(DemoStyle.notes)
                    } else {
                        Text(text)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                }
                .background(Color(.secondarySystemBackground))
            }
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: text) { Image(systemName: "square.and.arrow.up") }
                }
            }
        }
    }
}

// MARK: - Settings

struct EditorSettingsView: View {
    @ObservedObject var editor: RichEditorController
    @Environment(\.dismiss) private var dismiss
    @AppStorage("editorPadding") private var editorPadding = 32.0

    private func binding(_ keyPath: WritableKeyPath<RichEditorConfiguration, Bool>) -> Binding<Bool> {
        Binding(get: { editor.configuration[keyPath: keyPath] },
                set: { editor.configuration[keyPath: keyPath] = $0; editor.objectWillChange.send() })
    }

    private func blockBinding(_ type: RichBlockType) -> Binding<Bool> {
        Binding(get: { editor.configuration.allowedBlocks.contains(type) },
                set: { on in
                    if on { editor.configuration.allowedBlocks.insert(type) } else { editor.configuration.allowedBlocks.remove(type) }
                    editor.objectWillChange.send()
                })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Side padding", value: "\(Int(editorPadding)) pt")
                    Slider(value: $editorPadding, in: 0...60, step: 2)
                } header: {
                    Text("Layout")
                } footer: {
                    Text("RichContentStyle.editorHorizontalPadding: the same margin on both sides.")
                }
                Section("Editing") {
                    Toggle("Slash menu", isOn: binding(\.slashCommands))
                    Toggle("Markdown shortcuts", isOn: binding(\.markdownShortcuts))
                    Toggle("Block handles", isOn: binding(\.showsBlockHandles))
                    Toggle("Selection toolbar", isOn: binding(\.showsSelectionToolbar))
                    Toggle("Load web images", isOn: binding(\.loadsRemoteImages))
                }
                Section {
                    ForEach([RichBlockType.todo, .toggle, .callout, .codeBlock, .divider, .image], id: \.self) { type in
                        Toggle(isOn: blockBinding(type)) { Label(type.title, systemImage: type.symbolName) }
                    }
                } header: {
                    Text("Allowed blocks")
                } footer: {
                    Text("Limits the / menu, shortcuts, menus and paste. Email compose uses RichEditorConfiguration.email.")
                }
            }
            .navigationTitle("Editor Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
