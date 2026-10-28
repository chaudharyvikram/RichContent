import Foundation

/// Any body content an email / meeting / note can carry.
///
/// ```swift
/// RichContentView(.html(email.bodyHTML))
/// RichContentView(.markdown("**Agenda**\n- Intro\n- Demo"))
/// RichContentView(.mixed([.attributed(header), .html(body), .plain(signature)]))
/// RichContentView(.auto(unknownString))   // sniffs html / markdown / plain
/// ```
public indirect enum RichContent: Hashable {
    case plain(String)
    case markdown(String)
    case html(String)
    case attributed(AttributedString)
    case nsAttributed(NSAttributedString)
    /// Detects HTML, then Markdown, otherwise plain text.
    case auto(String)
    /// Renders each part in order. Adjacent native parts are merged into one
    /// selectable text view.
    case mixed([RichContent])
}

extension RichContent: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .auto(value) }
}

public enum RichContentFormat: Hashable {
    case plain, markdown, html
}

public enum RichContentDetector {
    private static let htmlTag = try! NSRegularExpression(
        pattern: #"<\s*/?\s*(html|head|body|div|p|br|span|a|b|i|u|s|strong|em|table|tr|td|th|blockquote|ul|ol|li|h[1-6]|img|font|pre|code|hr|center)\b[^>]*>"#,
        options: [.caseInsensitive]
    )

    private static let markdownSignals: [NSRegularExpression] = [
        #"(?m)^#{1,6}\s+\S"#,          // # Heading
        #"(?m)^\s*[-*+]\s+\S"#,        // - bullet
        #"(?m)^\s*\d+\.\s+\S"#,        // 1. ordered
        #"\*\*[^*\n]+\*\*"#,           // **bold**
        #"__[^_\n]+__"#,               // __bold__
        #"\[[^\]\n]+\]\([^)\s]+\)"#,   // [link](url)
        #"!\[[^\]\n]*\]\([^)\s]+"#,      // ![image](url)
        #"(?m)^```"#,                  // code fence
        #"`[^`\n]+`"#                  // `code`
    ].map { try! NSRegularExpression(pattern: $0) }

    public static func detect(_ string: String) -> RichContentFormat {
        if containsHTMLTags(string) { return .html }
        if looksLikeMarkdown(string) { return .markdown }
        return .plain
    }

    public static func containsHTMLTags(_ string: String) -> Bool {
        htmlTag.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) != nil
    }

    public static func looksLikeMarkdown(_ string: String) -> Bool {
        let range = NSRange(string.startIndex..., in: string)
        return markdownSignals.contains { $0.firstMatch(in: string, range: range) != nil }
    }
}

/// HTML that is still JSON-escaped (`<a href=\"https:\/\/…\">…<\/a>`), e.g. a
/// raw API payload pasted into a raw string literal or double-encoded by a
/// backend. `<\/` never occurs in real HTML, and closing tags written that way
/// aren't recognised by any HTML parser, so lists, bold and links break.
public enum JSONEscapedHTML {

    private static let signal = try! NSRegularExpression(pattern: #"<\\/[a-zA-Z]|=\\"[^"]|\\u003[cC]"#)

    public static func isEscaped(_ string: String) -> Bool {
        signal.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) != nil
    }

    public static func unescapeIfNeeded(_ string: String) -> String {
        guard string.contains("\\"), isEscaped(string) else { return string }

        // A fully escaped string decodes as a JSON string literal
        // (handles \" \/ \\ \n \t \uXXXX in one go).
        if let data = "\"\(string)\"".data(using: .utf8),
           let decoded = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? String {
            return decoded
        }
        // Partly escaped: fix the sequences that break HTML.
        return string
            .replacingOccurrences(of: "\\/", with: "/")
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\u003c", with: "<", options: .caseInsensitive)
            .replacingOccurrences(of: "\\u003e", with: ">", options: .caseInsensitive)
            .replacingOccurrences(of: "\\u0026", with: "&", options: .caseInsensitive)
    }
}

extension RichContent {
    /// Leaf parts in display order, with `.auto` resolved.
    var flattened: [RichContent] {
        switch self {
        case .mixed(let parts):
            return parts.flatMap(\.flattened)
        case .auto(let raw):
            // One string may hold several formats back to back
            // (HTML document + Markdown notes + plain reply).
            return MixedContentSegmenter.segments(of: JSONEscapedHTML.unescapeIfNeeded(raw))
                .flatMap(\.splittingMarkdownImages)
        case .html(let raw):
            // Explicit HTML that also carries Markdown sections gets split;
            // pure HTML stays one part.
            let string = JSONEscapedHTML.unescapeIfNeeded(raw)
            let parts = MixedContentSegmenter.segments(of: string)
            return parts.contains(where: \.isMarkdown) ? parts.flatMap(\.splittingMarkdownImages) : [.html(string)]
        case .markdown(let string):
            // Markdown with whole HTML blocks (a pasted email) gets split.
            let parts = MixedContentSegmenter.segments(of: string)
            return parts.contains(where: \.isHTML)
                ? parts.flatMap(\.splittingMarkdownImages)
                : MixedContentSegmenter.splittingImages(MixedContentSegmenter.dedent(string))
        default:
            return [self]
        }
    }

    /// Markdown images become `<img>` HTML parts (see `splittingImages`).
    private var splittingMarkdownImages: [RichContent] {
        if case .markdown(let string) = self { return MixedContentSegmenter.splittingImages(string) }
        return [self]
    }

    var isMarkdown: Bool { if case .markdown = self { return true }; return false }
    var isHTML: Bool { if case .html = self { return true }; return false }

    /// `NSAttributedString` hashes weakly (by length), so content holding one
    /// is rendered fresh instead of cached.
    var isCacheable: Bool {
        switch self {
        case .nsAttributed: return false
        case .mixed(let parts): return parts.allSatisfy(\.isCacheable)
        default: return true
        }
    }
}
