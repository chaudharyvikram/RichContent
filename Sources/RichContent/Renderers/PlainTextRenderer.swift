import UIKit

/// Plain strings. Understands email-style "> " quoting (any depth) and keeps
/// blank lines short so long replies stay compact.
enum PlainTextRenderer {

    static func render(_ text: String, style: RichContentStyle) -> NSMutableAttributedString {
        let result = NSMutableAttributedString()
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")

        for (index, rawLine) in lines.enumerated() {
            var line = Substring(rawLine)
            var depth = 0
            while line.hasPrefix(">") {
                depth += 1
                line = line.dropFirst()
                if line.hasPrefix(" ") { line = line.dropFirst() }
            }

            let isBlank = line.trimmingCharacters(in: .whitespaces).isEmpty
            let paragraph = TextKitHelpers.paragraphStyle(style, spacing: 0)
            if isBlank {
                // A blank line becomes a short gap instead of a full text line.
                paragraph.maximumLineHeight = style.paragraphSpacing
                paragraph.minimumLineHeight = style.paragraphSpacing
            }

            let string = String(line) + (index < lines.count - 1 ? "\n" : "")
            let piece = NSMutableAttributedString(string: string, attributes: [
                .font: style.font,
                .foregroundColor: style.textColor,
                .paragraphStyle: paragraph
            ])
            TextKitHelpers.applyQuote(piece, range: NSRange(location: 0, length: piece.length), depth: depth, style: style)
            result.append(piece)
        }

        TextKitHelpers.tidyWhitespace(result)
        return result
    }
}
