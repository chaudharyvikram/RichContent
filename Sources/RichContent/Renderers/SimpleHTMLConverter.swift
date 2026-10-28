import Foundation

/// Dependency-free HTML → Markdown conversion for the common subset
/// (paragraphs, line breaks, lists, headings, quotes, bold / italic /
/// strike / code, links). Used when UIKit's HTML importer returns nothing,
/// which happens in Xcode Previews, during some run-loop modes and on
/// background launches. The result goes through `MarkdownRenderer`.
enum SimpleHTMLConverter {

    static func markdown(from html: String) -> String {
        var s = html

        // Drop non-content.
        s = replace(#"<!--[\s\S]*?-->"#, in: s, with: "")
        s = replace(#"<(head|style|script|title)\b[\s\S]*?</\1\s*>"#, in: s, with: "")
        s = replace(#"\r\n?|\n"#, in: s, with: " ")           // HTML whitespace is not layout

        // Clean-ups that would break Markdown emphasis.
        s = replace(#"<(b|strong|i|em|u|s|strike|span|font)\b[^>]*>\s*</\1\s*>"#, in: s, with: "")
        s = replace(#"(?:<br\s*/?>\s*)+((?:</[a-z]+>\s*)*</(?:li|p|div|h[1-6]|blockquote)\s*>)"#, in: s, with: "$1")
        s = replace(#"(?:<br\s*/?>\s*)+((?:</(?:b|strong|i|em|u|s|span|font)>\s*)+)"#, in: s, with: "$1<br>")

        // Ordered lists first (non-nested), then any remaining items as bullets.
        s = replaceOrderedLists(s)
        s = replace(#"<li\b[^>]*>"#, in: s, with: "\n- ")
        s = replace(#"</li\s*>"#, in: s, with: "")
        s = replace(#"</?(ul|ol)\b[^>]*>"#, in: s, with: "\n\n")

        // Headings, quotes, block boundaries.
        for level in 1...6 {
            s = replace("<h\(level)\\b[^>]*>", in: s, with: "\n\n" + String(repeating: "#", count: level) + " ")
        }
        s = replace(#"</h[1-6]\s*>"#, in: s, with: "\n\n")
        s = replace(#"<blockquote\b[^>]*>"#, in: s, with: "\n\n> ")
        s = replace(#"</blockquote\s*>"#, in: s, with: "\n\n")
        s = replace(#"</?(p|div|table|tr|section|article|header|footer|center)\b[^>]*>"#, in: s, with: "\n\n")
        s = replace(#"<hr\b[^>]*>"#, in: s, with: "\n\n---\n\n")

        // Inline tags → Markdown (shared with the Markdown renderer), then strip the rest.
        s = MarkdownRenderer.convertInlineHTML(s)
        s = replace(#"<[^>]+>"#, in: s, with: "")
        s = decodeEntities(s)

        // Tidy whitespace.
        s = replace(#"[ \t]+\n"#, in: s, with: "\n")
        s = replace(#"\n[ \t]+(?=\S)"#, in: s, with: "\n")
        s = replace(#"[ \t]{2,}"#, in: s, with: " ")
        s = replace(#"[  ]+\n"#, in: s, with: "\n")          // <br> right before a block end
        s = replace(#"\n[  ]+"#, in: s, with: "\n")          // <br> right after a block start
        s = replace(#"\n{3,}"#, in: s, with: "\n\n")
        return s.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{2028}")))
    }

    private static func replaceOrderedLists(_ html: String) -> String {
        let regex = try! NSRegularExpression(pattern: #"<ol\b[^>]*>([\s\S]*?)</ol\s*>"#, options: [.caseInsensitive])
        var s = html
        for match in regex.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
            guard let whole = Range(match.range, in: s), let inner = Range(match.range(at: 1), in: s) else { continue }
            let items = replace(#"<li\b[^>]*>"#, in: String(s[inner]), with: "\n1. ")
            s.replaceSubrange(whole, with: "\n\n" + items + "\n\n")
        }
        return s
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var s = text
        let named: [String: String] = [
            "&nbsp;": " ", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'",
            "&ndash;": "–", "&mdash;": "—", "&hellip;": "…", "&rsquo;": "’", "&lsquo;": "‘",
            "&rdquo;": "”", "&ldquo;": "“", "&bull;": "•", "&copy;": "©", "&reg;": "®", "&trade;": "™"
        ]
        for (entity, value) in named { s = s.replacingOccurrences(of: entity, with: value) }

        let numeric = try! NSRegularExpression(pattern: #"&#(x[0-9a-fA-F]+|\d+);"#)
        for match in numeric.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
            guard let whole = Range(match.range, in: s), let body = Range(match.range(at: 1), in: s) else { continue }
            let token = s[body]
            let value = token.hasPrefix("x") ? UInt32(token.dropFirst(), radix: 16) : UInt32(token)
            if let value, let scalar = Unicode.Scalar(value) {
                s.replaceSubrange(whole, with: String(Character(scalar)))
            }
        }
        // Last, so "&amp;lt;" becomes "&lt;" and not "<".
        return s.replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func replace(_ pattern: String, in string: String, with template: String) -> String {
        let regex = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        return regex.stringByReplacingMatches(in: string, range: NSRange(string.startIndex..., in: string),
                                              withTemplate: template)
    }
}
