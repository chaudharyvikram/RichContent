import Foundation

extension DemoSamples {

    /// Your own test content, kept out of git (see .gitignore). Paste a server
    /// response into `Demo/RichContentDemo/htmlcontent.html` exactly as received
    /// (HTML, Markdown, a mix, even JSON-escaped) and it shows up as the "HTML"
    /// note and Viewer sample. `nil` when the file is missing or empty.
    static let htmlContent: String? = {
        guard let url = Bundle.main.url(forResource: "htmlcontent", withExtension: "html"),
              let content = try? String(contentsOf: url, encoding: .utf8), !content.isEmpty else { return nil }
        return content
    }()
}
