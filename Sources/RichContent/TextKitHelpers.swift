import UIKit

extension NSAttributedString.Key {
    /// Int quote nesting level; drawn as vertical bars by `QuoteBarLayoutManager`.
    public static let richQuoteDepth = NSAttributedString.Key("RichContent.quoteDepth")
}

extension UIFont {
    func adding(_ traits: UIFontDescriptor.SymbolicTraits) -> UIFont {
        guard !traits.isEmpty,
              let descriptor = fontDescriptor.withSymbolicTraits(fontDescriptor.symbolicTraits.union(traits))
        else { return self }
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}

extension UIColor {
    private var rgba: (CGFloat, CGFloat, CGFloat, CGFloat)? {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        return getRed(&r, green: &g, blue: &b, alpha: &a) ? (r, g, b, a) : nil
    }
    /// Black or a dark neutral gray (`#333`, `#555` …), the usual "body text"
    /// colors in emails, including slightly tinted ones like `#2c3e50`.
    /// Clearly colored dark text (navy, maroon, dark green) is not included.
    var isNearBlack: Bool {
        guard let (r, g, b, a) = rgba else { return false }
        let hi = max(r, g, b), lo = min(r, g, b)
        return a > 0.9 && (hi < 0.2 || (hi < 0.42 && hi - lo < 0.15))
    }
    var isNearWhite: Bool {
        guard let (r, g, b, a) = rgba else { return false }
        return a > 0.9 && r > 0.94 && g > 0.94 && b > 0.94
    }
    var cssHex: String {
        guard let (r, g, b, a) = rgba else { return "#000000" }
        let c = { (v: CGFloat) in Int((max(0, min(1, v)) * 255).rounded()) }
        return a < 0.999
            ? "rgba(\(c(r)),\(c(g)),\(c(b)),\(String(format: "%.3f", a)))"
            : String(format: "#%02X%02X%02X", c(r), c(g), c(b))
    }
}

enum TextKitHelpers {

    static func paragraphStyle(_ style: RichContentStyle, spacing: CGFloat? = nil) -> NSMutableParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = style.lineSpacing
        p.paragraphSpacing = spacing ?? style.paragraphSpacing
        p.lineBreakMode = .byWordWrapping
        return p
    }

    static func baseAttributes(_ style: RichContentStyle) -> [NSAttributedString.Key: Any] {
        [.font: style.font, .foregroundColor: style.textColor, .paragraphStyle: paragraphStyle(style)]
    }

    /// Indents whole paragraphs in `range` by `depth` quote levels, tags them
    /// for bar drawing and optionally dims their text.
    static func applyQuote(_ s: NSMutableAttributedString, range: NSRange, depth: Int, style: RichContentStyle) {
        guard depth > 0, range.length > 0 else { return }
        s.addAttribute(.richQuoteDepth, value: depth, range: range)

        let offset = CGFloat(depth) * style.quoteIndent
        s.enumerateAttribute(.paragraphStyle, in: range) { value, r, _ in
            let p = ((value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle)
                ?? paragraphStyle(style)
            p.headIndent += offset
            p.firstLineHeadIndent += offset
            p.tabStops = p.tabStops.map {
                NSTextTab(textAlignment: $0.alignment, location: $0.location + offset, options: $0.options)
            }
            s.addAttribute(.paragraphStyle, value: p, range: r)
        }

        guard style.dimsQuotedText else { return }
        s.enumerateAttribute(.foregroundColor, in: range) { value, r, _ in
            let color = value as? UIColor
            if color == nil || color == style.textColor || color?.isNearBlack == true {
                s.addAttribute(.foregroundColor, value: style.secondaryTextColor, range: r)
            }
        }
    }

    /// Gives runs without a font / color the style's defaults.
    static func fillDefaults(_ s: NSMutableAttributedString, style: RichContentStyle) {
        let full = NSRange(location: 0, length: s.length)
        s.enumerateAttribute(.font, in: full) { value, r, _ in
            if value == nil { s.addAttribute(.font, value: style.font, range: r) }
        }
        s.enumerateAttribute(.foregroundColor, in: full) { value, r, _ in
            if value == nil { s.addAttribute(.foregroundColor, value: style.textColor, range: r) }
        }
        s.enumerateAttribute(.paragraphStyle, in: full) { value, r, _ in
            if value == nil { s.addAttribute(.paragraphStyle, value: paragraphStyle(style), range: r) }
        }
    }

    private static let linkDetector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func linkify(_ s: NSMutableAttributedString) {
        guard let detector = linkDetector, s.length > 0 else { return }
        let string = s.string
        for match in detector.matches(in: string, range: NSRange(location: 0, length: s.length)) {
            guard let url = match.url,
                  s.attribute(.link, at: match.range.location, effectiveRange: nil) == nil
            else { continue }
            s.addAttribute(.link, value: url, range: match.range)
        }
    }

    private static let blankRun = try! NSRegularExpression(
        pattern: #"[\n ][ \t ]*([\n ][ \t ]*){2,}"#)

    /// Collapses 2+ blank lines into one and trims leading / trailing whitespace.
    static func tidyWhitespace(_ s: NSMutableAttributedString) {
        let matches = blankRun.matches(in: s.string, range: NSRange(location: 0, length: s.length))
        for match in matches.reversed() {
            s.replaceCharacters(in: match.range, with: "\n\n")
        }
        let ws = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{2028}\u{00A0}"))
        while let last = s.string.unicodeScalars.last, ws.contains(last) {
            s.deleteCharacters(in: NSRange(location: s.length - last.utf16.count, length: last.utf16.count))
        }
        while let first = s.string.unicodeScalars.first, ws.contains(first) {
            s.deleteCharacters(in: NSRange(location: 0, length: first.utf16.count))
        }
    }

    /// Appends `next` after a newline that carries `base`'s last attributes,
    /// so the paragraph break belongs to the paragraph before it.
    static func appendParagraph(_ next: NSAttributedString, to base: NSMutableAttributedString) {
        guard base.length > 0 else { base.append(next); return }
        guard next.length > 0 else { return }
        let attrs = base.attributes(at: base.length - 1, effectiveRange: nil)
        base.append(NSAttributedString(string: "\n", attributes: attrs))
        base.append(next)
    }
}
