import UIKit
import CoreText

/// Makes the app's custom base font available inside the web view.
///
/// WKWebView renders in a separate process and can't see fonts the app
/// registered (UIAppFonts / CTFontManager), so the font files are embedded
/// as `@font-face` data URLs (allowed by the web view's CSP). The system font
/// maps to `-apple-system`; fonts whose files can't be read fall back to the
/// family name.
@MainActor
enum WebFontEmbedder {

    struct Result {
        /// `@font-face` rules (may be empty).
        let faces: String
        /// CSS `font-family` value, most specific first.
        let family: String
    }

    private static var cache: [String: Result] = [:]
    private static let embeddedFamily = "RichContentBase"

    static func css(for font: UIFont) -> Result {
        if isSystemFont(font) {
            return Result(faces: "", family: "-apple-system, system-ui, sans-serif")
        }
        if let hit = cache[font.fontName] { return hit }

        let variants: [(UIFontDescriptor.SymbolicTraits, weight: Int, style: String)] = [
            ([], 400, "normal"),
            (.traitBold, 700, "normal"),
            (.traitItalic, 400, "italic"),
            ([.traitBold, .traitItalic], 700, "italic")
        ]

        var faces: [String] = []
        var seen = Set<URL>()
        for (traits, weight, style) in variants {
            let face: UIFont
            if traits.isEmpty {
                face = font
            } else if let descriptor = font.fontDescriptor.withSymbolicTraits(traits) {
                face = UIFont(descriptor: descriptor, size: font.pointSize)
            } else {
                continue
            }
            guard let url = fileURL(of: face), !seen.contains(url),
                  let mime = mimeType(for: url),
                  let data = try? Data(contentsOf: url)
            else { continue }
            seen.insert(url)
            faces.append("""
            @font-face { font-family: '\(embeddedFamily)'; src: url(data:\(mime);base64,\(data.base64EncodedString())); font-weight: \(weight); font-style: \(style); }
            """)
        }

        let fallbackFamily = font.familyName.replacingOccurrences(of: "'", with: "")
        let family = faces.isEmpty
            ? "'\(fallbackFamily)', -apple-system, system-ui, sans-serif"
            : "'\(embeddedFamily)', '\(fallbackFamily)', -apple-system, system-ui, sans-serif"
        let result = Result(faces: faces.joined(separator: "\n"), family: family)
        cache[font.fontName] = result
        return result
    }

    private static func isSystemFont(_ font: UIFont) -> Bool {
        font.familyName.hasPrefix(".") || font.fontName.hasPrefix(".")
            || font.familyName == UIFont.systemFont(ofSize: 12).familyName
    }

    private static func fileURL(of font: UIFont) -> URL? {
        CTFontCopyAttribute(font as CTFont, kCTFontURLAttribute) as? URL
    }

    private static func mimeType(for url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "ttf": return "font/ttf"
        case "otf": return "font/otf"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        default: return nil   // .ttc collections aren't embeddable
        }
    }
}
