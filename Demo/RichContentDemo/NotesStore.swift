import CryptoKit
import Foundation
import RichContent

struct Note: Identifiable, Codable, Hashable {
    var id = UUID()
    /// The editor's HTML: lossless, what the app saves.
    var html: String
    var updated = Date()
    /// Shown in the list instead of the first line of the text.
    var title: String?
    /// The `LocalContent/` file this note mirrors, if any.
    var source: String?
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
            syncLocalNotes()
        } else {
            resetSamples()
        }
        notes.forEach(summarize)
    }

    /// A note per file in `LocalContent/`, titled with the file name. The
    /// content is passed unchanged; `.auto` works out HTML, Markdown or a mix.
    private static func localNote(_ sample: LocalSample, updated: Date) -> Note {
        Note(html: RichEditorController(content: .auto(sample.content)).html, updated: updated,
             title: sample.title, source: sample.fileName)
    }

    /// Fingerprint of each file's content at its last import, by file name.
    private static let localDigestsKey = "localContentDigests"
    private var localDigests: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: Self.localDigestsKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Self.localDigestsKey) }
    }

    private static func digest(_ content: String) -> String {
        SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The files are the source of truth: a note is added for a new file, and
    /// replaced when its file changed since the last launch. A deleted note
    /// stays deleted until its file changes.
    private func syncLocalNotes() {
        var digests = localDigests
        var changed = false
        for sample in LocalSample.all {
            let digest = Self.digest(sample.content)
            defer { digests[sample.fileName] = digest }
            guard digests[sample.fileName] != digest else { continue }
            let note = Self.localNote(sample, updated: Date())
            // Notes from earlier builds have no source; match them by title.
            if let index = notes.firstIndex(where: { $0.source == sample.fileName })
                ?? notes.firstIndex(where: { $0.source == nil && $0.title == sample.title }) {
                notes[index].html = note.html
                notes[index].updated = note.updated
                notes[index].title = note.title
                notes[index].source = note.source
            } else {
                notes.append(note)
            }
            changed = true
        }
        localDigests = digests
        guard changed else { return }
        notes.sort { $0.updated > $1.updated }
        save()
    }

    func resetSamples() {
        let now = Date()
        notes = [Note(html: DemoSamples.welcome, updated: now)]
            + LocalSample.all.map { Self.localNote($0, updated: now.addingTimeInterval(-60)) }
            + [Note(html: DemoSamples.meeting, updated: now.addingTimeInterval(-3600)),
               Note(html: RichEditorController(content: .markdown(DemoSamples.markdownNote)).html, updated: now.addingTimeInterval(-86400))]
        notes.forEach(summarize)
        localDigests = Dictionary(LocalSample.all.map { ($0.fileName, Self.digest($0.content)) }, uniquingKeysWith: { a, _ in a })
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
