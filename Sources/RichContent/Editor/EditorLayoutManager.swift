import UIKit

/// Draws everything in the editor that isn't text: list bullets / numbers,
/// to-do checkboxes, toggle arrows, quote bars, callout and code boxes,
/// placeholder hints and the image focus ring. Markers are never stored as
/// text, so editing and export stay clean and numbering updates live.
final class EditorLayoutManager: NSLayoutManager {

    var style = RichContentStyle.standard
    var accentColor: UIColor = .tintColor

    /// The paragraph under the caret, for hints and focus rings.
    struct Focus {
        var paragraphLocation: Int
        var isEmptyLastLine: Bool
        var info: BlockInfo
        var showsHint: Bool
    }
    var focus: (() -> Focus?)?
    /// Block info for the empty last line (it has no characters to carry it).
    var trailingLineInfo: (() -> BlockInfo)?
    var commandHint = "Type '/' for commands"

    private var metrics: EditorStyling.Metrics { EditorStyling.Metrics(style) }

    // MARK: Geometry

    struct ParagraphGeometry {
        var first: CGRect      // first line fragment
        var last: CGRect       // last line fragment
        var baseline: CGFloat  // of the first line, in container coordinates
        var font: UIFont
        /// Top of the first line's text and bottom of the last line's text,
        /// without paragraph spacing (the last block in a document has none
        /// after it, so line fragments can't be used for boxes).
        var textTop: CGFloat
        var textBottom: CGFloat
    }

    /// Line geometry of the paragraph starting at `location` (`nil` for the
    /// empty last line, see `trailingGeometry`).
    func geometry(ofParagraphAt location: Int) -> ParagraphGeometry? {
        guard let storage = textStorage, location < storage.length else { return nil }
        let ns = storage.string as NSString
        let paragraph = ns.paragraphRange(for: NSRange(location: location, length: 0))
        ensureLayout(forCharacterRange: paragraph)
        let glyphs = glyphRange(forCharacterRange: paragraph, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return nil }
        let first = lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        let last = lineFragmentRect(forGlyphAt: NSMaxRange(glyphs) - 1, effectiveRange: nil)
        let font = storage.attribute(.font, at: paragraph.location, effectiveRange: nil) as? UIFont ?? style.font
        let baseline = first.minY + self.location(forGlyphAt: glyphs.location).y
        let spacingBefore = (storage.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil) as? NSParagraphStyle)?
            .paragraphSpacingBefore ?? 0
        let lastUsed = lineFragmentUsedRect(forGlyphAt: NSMaxRange(glyphs) - 1, effectiveRange: nil)
        return ParagraphGeometry(first: first, last: last, baseline: baseline, font: font,
                                 textTop: first.minY + (paragraph.location == 0 ? 0 : spacingBefore),
                                 textBottom: lastUsed.maxY)
    }

    /// Geometry of the empty line after a trailing newline.
    func trailingGeometry() -> ParagraphGeometry? {
        guard let storage = textStorage else { return nil }
        let extra = extraLineFragmentRect
        guard !extra.isEmpty || storage.length == 0 else { return nil }
        let info = trailingLineInfo?() ?? BlockInfo()
        let font = EditorStyling.baseFont(for: info.type, style: style)
        let p = EditorStyling.paragraphStyle(for: info, style: style)
        let rect = storage.length == 0
            ? CGRect(x: 0, y: 0, width: textContainers.first?.size.width ?? 0, height: font.lineHeight + p.paragraphSpacingBefore)
            : extra
        // The extra fragment has no paragraph spacing before; mirror the real one.
        let top = storage.length == 0 ? rect.minY + p.paragraphSpacingBefore : rect.minY
        return ParagraphGeometry(first: rect, last: rect, baseline: top + font.ascender, font: font,
                                 textTop: top, textBottom: top + font.lineHeight)
    }

    /// Union of the line fragments of a paragraph, in container coordinates.
    func blockRect(ofParagraphAt location: Int) -> CGRect? {
        if let storage = textStorage, location >= storage.length {
            return trailingGeometry().map { $0.first }
        }
        guard let g = geometry(ofParagraphAt: location) else { return nil }
        return g.first.union(g.last)
    }

    /// Tap target of a checkbox / toggle arrow / callout emoji.
    func markerRect(ofParagraphAt location: Int) -> CGRect? {
        guard let storage = textStorage else { return nil }
        let isTrailing = location >= storage.length
        let info = isTrailing ? (trailingLineInfo?() ?? BlockInfo()) : EditorStyling.info(in: storage, at: location)
        guard info.type == .todo || info.type == .toggle || info.type == .callout,
              let g = isTrailing ? trailingGeometry() : geometry(ofParagraphAt: location)
        else { return nil }
        let base = metrics.base(info.level)
        let center = g.baseline - g.font.capHeight / 2
        if info.type == .callout {
            let x = base + metrics.boxPadding
            return CGRect(x: x - 4, y: center - 16, width: metrics.calloutEmojiWidth + 4, height: 32)
        }
        return CGRect(x: base - 4, y: center - 16, width: metrics.markerWidth + 4, height: 32)
    }

    // MARK: Drawing

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        guard let storage = textStorage else {
            super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
            return
        }
        let ns = storage.string as NSString
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let focus = self.focus?()

        // Boxes first, so text background (highlights, inline code) sits on top.
        if ns.length > 0 {
            let expanded = ns.paragraphRange(for: characters)
            ns.enumerateSubstrings(in: expanded, options: [.byParagraphs, .substringNotRequired]) { _, _, enclosing, _ in
                let info = EditorStyling.info(in: storage, at: enclosing.location)
                guard let g = self.geometry(ofParagraphAt: enclosing.location) else { return }
                self.drawBlockBackground(info, g, origin)
            }
        }
        if let g = trailingGeometry(), storage.length == 0 || ns.character(at: storage.length - 1) == 10 {
            drawBlockBackground(trailingLineInfo?() ?? BlockInfo(), g, origin)
        }

        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)

        if ns.length > 0 {
            let expanded = ns.paragraphRange(for: characters)
            ns.enumerateSubstrings(in: expanded, options: [.byParagraphs, .substringNotRequired]) { _, content, enclosing, _ in
                let info = EditorStyling.info(in: storage, at: enclosing.location)
                guard let g = self.geometry(ofParagraphAt: enclosing.location) else { return }
                self.drawDecorations(info, g, origin, paragraphStart: enclosing.location)
                if let focus, !focus.isEmptyLastLine, focus.paragraphLocation == enclosing.location {
                    if content.length == 0, focus.showsHint { self.drawHint(info, g, origin) }
                    if info.type == .image { self.drawFocusRing(enclosing, origin) }
                }
            }
        }
        if let g = trailingGeometry(), storage.length == 0 || ns.character(at: storage.length - 1) == 10 {
            let info = trailingLineInfo?() ?? BlockInfo()
            drawDecorations(info, g, origin, paragraphStart: storage.length)
            if let focus, focus.isEmptyLastLine, focus.showsHint { drawHint(info, g, origin) }
        }
    }

    private func drawBlockBackground(_ info: BlockInfo, _ g: ParagraphGeometry, _ origin: CGPoint) {
        guard info.type == .callout || info.type == .codeBlock,
              let width = textContainers.first?.size.width else { return }
        let m = metrics
        let x = origin.x + m.base(info.level)
        let top = origin.y + g.textTop - m.boxPadding
        let bottom = origin.y + g.textBottom + m.boxPadding
        let rect = CGRect(x: x, y: top, width: width - m.base(info.level), height: max(bottom - top, g.font.lineHeight))
        let color = info.type == .codeBlock ? style.codeBackgroundColor : (info.color ?? .gray).backgroundColor
        color.setFill()
        UIBezierPath(roundedRect: rect, cornerRadius: 6).fill()
    }

    private func drawDecorations(_ info: BlockInfo, _ g: ParagraphGeometry, _ origin: CGPoint, paragraphStart: Int) {
        let m = metrics
        let base = origin.x + m.base(info.level)
        let baseline = origin.y + g.baseline
        let center = baseline - g.font.capHeight / 2
        let markerFont = g.font.isMonospaced ? style.font : g.font

        switch info.type {
        case .bulletList:
            let d = max(markerFont.pointSize * 0.34, 5)
            let rect = CGRect(x: base + (m.markerWidth - d) / 2 - 3, y: center - d / 2, width: d, height: d)
            style.textColor.setFill()
            style.textColor.setStroke()
            switch (info.level - 1) % 3 {
            case 0: UIBezierPath(ovalIn: rect).fill()
            case 1:
                let path = UIBezierPath(ovalIn: rect.insetBy(dx: 0.6, dy: 0.6))
                path.lineWidth = 1.2
                path.stroke()
            default: UIRectFill(rect.insetBy(dx: 0.4, dy: 0.4))
            }
        case .numberedList:
            let n = ordinal(before: paragraphStart, level: info.level)
            let marker = Self.numberMarker(n, level: info.level)
            let attrs: [NSAttributedString.Key: Any] = [.font: markerFont, .foregroundColor: style.textColor]
            let size = (marker as NSString).size(withAttributes: attrs)
            let right = base + m.markerWidth - 5
            (marker as NSString).draw(at: CGPoint(x: right - size.width, y: baseline - markerFont.ascender), withAttributes: attrs)
        case .todo:
            let side = min(max(markerFont.pointSize, 14), 18)
            let rect = CGRect(x: base + (m.markerWidth - side) / 2 - 3, y: center - side / 2, width: side, height: side)
            let path = UIBezierPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), cornerRadius: 3)
            if info.checked {
                accentColor.setFill()
                UIBezierPath(roundedRect: rect, cornerRadius: 3).fill()
                let check = UIBezierPath()
                check.move(to: CGPoint(x: rect.minX + side * 0.24, y: rect.minY + side * 0.52))
                check.addLine(to: CGPoint(x: rect.minX + side * 0.42, y: rect.minY + side * 0.7))
                check.addLine(to: CGPoint(x: rect.minX + side * 0.77, y: rect.minY + side * 0.3))
                check.lineWidth = 1.8
                check.lineCapStyle = .round
                check.lineJoinStyle = .round
                UIColor.white.setStroke()
                check.stroke()
            } else {
                path.lineWidth = 1.5
                style.textColor.withAlphaComponent(0.7).setStroke()
                path.stroke()
            }
        case .toggle:
            let name = info.collapsed == nil ? "arrowtriangle.down.fill" : "arrowtriangle.right.fill"
            let config = UIImage.SymbolConfiguration(pointSize: max(markerFont.pointSize * 0.55, 8), weight: .regular)
            if let image = UIImage(systemName: name, withConfiguration: config)?
                .withTintColor(style.textColor, renderingMode: .alwaysOriginal) {
                image.draw(at: CGPoint(x: base + (m.markerWidth - image.size.width) / 2 - 3, y: center - image.size.height / 2))
            }
        case .quote:
            let top = origin.y + g.textTop
            let bottom = origin.y + g.textBottom
            let rect = CGRect(x: base + 1, y: top, width: 3, height: max(bottom - top, g.font.lineHeight))
            style.textColor.setFill()
            UIRectFill(rect)
        case .callout:
            let emoji = info.emoji ?? "💡"
            let font = UIFont.systemFont(ofSize: style.font.pointSize * 1.15)
            let attrs: [NSAttributedString.Key: Any] = [.font: font]
            (emoji as NSString).draw(at: CGPoint(x: base + m.boxPadding, y: baseline - font.ascender), withAttributes: attrs)
        default:
            break
        }
    }

    private func drawHint(_ info: BlockInfo, _ g: ParagraphGeometry, _ origin: CGPoint) {
        let text = info.type == .paragraph ? commandHint : info.type.hint
        guard !text.isEmpty else { return }
        let font = EditorStyling.baseFont(for: info.type, style: style)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.placeholderText]
        let x = origin.x + metrics.textIndent(info)
        (text as NSString).draw(at: CGPoint(x: x, y: origin.y + g.baseline - font.ascender), withAttributes: attrs)
    }

    private func drawFocusRing(_ paragraph: NSRange, _ origin: CGPoint) {
        guard let storage = textStorage,
              let r = EditorStyling.attachmentRange(inParagraph: paragraph, of: storage),
              let container = textContainers.first else { return }
        let glyphs = glyphRange(forCharacterRange: r, actualCharacterRange: nil)
        var rect = boundingRect(forGlyphRange: glyphs, in: container)
        rect = rect.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -3, dy: -3)
        let path = UIBezierPath(roundedRect: rect, cornerRadius: 8)
        path.lineWidth = 2.5
        accentColor.setStroke()
        path.stroke()
    }

    // MARK: Lists

    /// 1-based number of a numbered item: counts earlier items at the same
    /// level, skipping deeper nested blocks, stopping at anything else.
    func ordinal(before start: Int, level: Int) -> Int {
        guard let storage = textStorage, storage.length > 0 else { return 1 }
        let ns = storage.string as NSString
        var n = 1
        var index = min(start, ns.length)
        while index > 0 {
            let previous = ns.paragraphRange(for: NSRange(location: index - 1, length: 0))
            let info = EditorStyling.info(in: storage, at: previous.location)
            if info.type == .numberedList && info.level == level {
                n += 1
            } else if info.level <= level {
                break
            }
            index = previous.location
        }
        return n
    }

    /// Notion-style numbering: 1. → a. → i. by level.
    static func numberMarker(_ n: Int, level: Int) -> String {
        switch (level - 1) % 3 {
        case 1: return alphabetic(n) + "."
        case 2: return roman(n) + "."
        default: return "\(n)."
        }
    }

    private static func alphabetic(_ number: Int) -> String {
        var n = max(number, 1)
        var result = ""
        while n > 0 {
            n -= 1
            result = String(UnicodeScalar(UInt8(97 + n % 26))) + result
            n /= 26
        }
        return result
    }

    private static func roman(_ number: Int) -> String {
        let table: [(Int, String)] = [(1000, "m"), (900, "cm"), (500, "d"), (400, "cd"), (100, "c"), (90, "xc"),
                                      (50, "l"), (40, "xl"), (10, "x"), (9, "ix"), (5, "v"), (4, "iv"), (1, "i")]
        var n = max(number, 1)
        var result = ""
        for (value, symbol) in table {
            while n >= value { result += symbol; n -= value }
        }
        return result
    }
}
