import Foundation
import RichContent

struct Note: Identifiable, Codable, Hashable {
    var id = UUID()
    /// The editor's HTML: lossless, what the app saves.
    var html: String
    var updated = Date()
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
        } else {
            resetSamples()
        }
        notes.forEach(summarize)
    }

    func resetSamples() {
        let now = Date()
        notes = [
            Note(html: DemoSamples.welcome, updated: now),
            Note(html: DemoSamples.meeting, updated: now.addingTimeInterval(-3600)),
            Note(html: RichEditorController(content: .markdown(DemoSamples.markdownNote)).html, updated: now.addingTimeInterval(-86400))
        ]
        notes.forEach(summarize)
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
        summaries[note.id] = (lines.first ?? "Untitled", lines.dropFirst().first ?? "")
    }

    private func save() {
        try? JSONEncoder().encode(notes).write(to: url, options: .atomic)
    }
}
