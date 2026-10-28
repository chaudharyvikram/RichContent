import Foundation
import RichContent

struct Note: Identifiable, Codable, Hashable {
    var id = UUID()
    /// The editor's HTML: lossless, what the app saves.
    var html: String
    var updated = Date()
    /// Shown in the list instead of the first line of the text.
    var title: String?
}

/// Notes saved as JSON in Documents. Seeded with the demo notes.
@MainActor
final class NotesStore: ObservableObject {
    @Published private(set) var notes: [Note] = []
    /// Title / preview cache, so the list doesn't re-parse HTML on every redraw.
    @Published private(set) var summaries: [UUID: (title: String, preview: String)] = [:]

    private let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("notes.json")

    init() {
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([Note].self, from: data), !saved.isEmpty {
            notes = saved
            addNewLocalNotes()
        } else {
            resetSamples()
        }
        notes.forEach(summarize)
    }

    /// A note per file in `LocalContent/`, titled with the file name. The
    /// content is passed unchanged; `.auto` works out HTML, Markdown or a mix.
    private static func localNote(_ sample: LocalSample, updated: Date) -> Note {
        Note(html: RichEditorController(content: .auto(sample.content)).html, updated: updated, title: sample.title)
    }

    /// File names already turned into notes, so each is added once and
    /// deleting its note sticks.
    private static let addedLocalFilesKey = "addedLocalContentFiles"
    private var addedLocalFiles: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.addedLocalFilesKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: Self.addedLocalFilesKey) }
    }

    /// Adds notes for files added to `LocalContent/` since the last launch.
    private func addNewLocalNotes() {
        let added = addedLocalFiles
        let new = LocalSample.all.filter { !added.contains($0.fileName) }
        guard !new.isEmpty else { return }
        notes.insert(contentsOf: new.map { Self.localNote($0, updated: Date()) }, at: 0)
        addedLocalFiles = added.union(new.map(\.fileName))
        save()
    }

    func resetSamples() {
        let now = Date()
        notes = [Note(html: DemoSamples.welcome, updated: now)]
            + LocalSample.all.map { Self.localNote($0, updated: now.addingTimeInterval(-60)) }
            + [Note(html: DemoSamples.meeting, updated: now.addingTimeInterval(-3600)),
               Note(html: RichEditorController(content: .markdown(DemoSamples.markdownNote)).html, updated: now.addingTimeInterval(-86400))]
        notes.forEach(summarize)
        addedLocalFiles = Set(LocalSample.all.map(\.fileName))
        save()
    }

    func note(_ id: UUID) -> Note? { notes.first { $0.id == id } }

    @discardableResult
    func add() -> Note {
        let note = Note(html: "")
        notes.insert(note, at: 0)
        summarize(note)
        save()
        return note
    }

    func update(_ id: UUID, html: String) {
        guard let index = notes.firstIndex(where: { $0.id == id }), notes[index].html != html else { return }
        notes[index].html = html
        notes[index].updated = Date()
        summarize(notes[index])
        notes.sort { $0.updated > $1.updated }
        save()
    }

    func delete(_ ids: [UUID]) {
        notes.removeAll { ids.contains($0.id) }
        save()
    }

    /// First two non-empty lines of the plain-text export.
    private func summarize(_ note: Note) {
        let lines = RichEditorController(content: .html(note.html)).plainText
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "———" }
        if let title = note.title {
            summaries[note.id] = (title, lines.first ?? "")
        } else {
            summaries[note.id] = (lines.first ?? "Untitled", lines.dropFirst().first ?? "")
        }
    }

    private func save() {
        try? JSONEncoder().encode(notes).write(to: url, options: .atomic)
    }
}
