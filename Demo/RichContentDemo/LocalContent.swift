import Foundation

/// Your own test content: every `.html`, `.md` or `.txt` file in
/// `Demo/RichContentDemo/LocalContent/` becomes a note and a Viewer sample,
/// titled with its file name. Contents are passed unchanged to `.auto`, which
/// works out HTML, Markdown, a mix of both, or JSON-escaped HTML. Empty files
/// are skipped. New files in the folder are ignored by git (see its README).
struct LocalSample: Hashable {
    /// File name with extension, e.g. "htmlcontent.html".
    let fileName: String
    let content: String

    var title: String { (fileName as NSString).deletingPathExtension }

    static let all: [LocalSample] = {
        let extensions = ["html", "htm", "md", "markdown", "txt"]
        // Xcode may copy the folder's files to the bundle root or keep the folder.
        let urls = extensions.flatMap { ext in
            [nil, "LocalContent"].flatMap { Bundle.main.urls(forResourcesWithExtension: ext, subdirectory: $0) ?? [] }
        }
        var seen = Set<String>()
        return urls
            .filter { $0.lastPathComponent.lowercased() != "readme.md" && seen.insert($0.lastPathComponent).inserted }
            .compactMap { url in
                guard let content = try? String(contentsOf: url, encoding: .utf8),
                      !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return LocalSample(fileName: url.lastPathComponent, content: content)
            }
            .sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
    }()
}
