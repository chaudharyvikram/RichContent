import UIKit

/// Block type of a paragraph. Stored on every character of the paragraph as
/// `.richBlock` (raw value), so it survives editing, undo and copy/paste.
public enum RichBlockType: String, Hashable, CaseIterable {
    case paragraph, heading1, heading2, heading3
    case bulletList, numberedList, todo, toggle
    case quote, callout, codeBlock, divider, image

    /// Blocks drawn with a marker in front (bullet, number, checkbox, chevron).
    public var hasMarker: Bool { self == .bulletList || self == .numberedList || self == .todo || self == .toggle }
    public var isList: Bool { self == .bulletList || self == .numberedList }
    public var isHeading: Bool { self == .heading1 || self == .heading2 || self == .heading3 }
    /// Blocks that hold one attachment instead of text.
    public var isAttachment: Bool { self == .divider || self == .image }
    /// Return inserts a line break inside the block instead of a new block.
    var keepsLineBreaks: Bool { self == .codeBlock || self == .callout }

    public var title: String {
        switch self {
        case .paragraph: return "Text"
        case .heading1: return "Heading 1"
        case .heading2: return "Heading 2"
        case .heading3: return "Heading 3"
        case .bulletList: return "Bulleted list"
        case .numberedList: return "Numbered list"
        case .todo: return "To-do list"
        case .toggle: return "Toggle list"
        case .quote: return "Quote"
        case .callout: return "Callout"
        case .codeBlock: return "Code"
        case .divider: return "Divider"
        case .image: return "Image"
        }
    }

    public var symbolName: String {
        switch self {
        case .paragraph: return "textformat"
        case .heading1: return "textformat.size.larger"
        case .heading2: return "textformat.size"
        case .heading3: return "textformat.size.smaller"
        case .bulletList: return "list.bullet"
        case .numberedList: return "list.number"
        case .todo: return "checklist"
        case .toggle: return "chevron.right.square"
        case .quote: return "text.quote"
        case .callout: return "lightbulb"
        case .codeBlock: return "chevron.left.forwardslash.chevron.right"
        case .divider: return "minus"
        case .image: return "photo"
        }
    }

    /// Placeholder shown in an empty block under the caret.
    var hint: String {
        switch self {
        case .heading1: return "Heading 1"
        case .heading2: return "Heading 2"
        case .heading3: return "Heading 3"
        case .bulletList, .numberedList: return "List"
        case .todo: return "To-do"
        case .toggle: return "Toggle"
        case .quote: return "Empty quote"
        case .callout: return "Type something…"
        case .codeBlock: return "Code"
        default: return ""
        }
    }

    var headingLevel: Int? {
        switch self {
        case .heading1: return 1
        case .heading2: return 2
        case .heading3: return 3
        default: return nil
        }
    }

    /// Blocks offered by "Turn into" (attachments can't be turned into text).
    public static var textBlocks: [RichBlockType] {
        [.paragraph, .heading1, .heading2, .heading3, .bulletList, .numberedList, .todo, .toggle, .quote, .callout, .codeBlock]
    }
}

/// Character-level format.
public enum RichInlineFormat: String, Hashable, CaseIterable {
    case bold, italic, underline, strikethrough, code, link

    public var title: String {
        switch self {
        case .bold: return "Bold"
        case .italic: return "Italic"
        case .underline: return "Underline"
        case .strikethrough: return "Strikethrough"
        case .code: return "Code"
        case .link: return "Link"
        }
    }

    public var symbolName: String {
        switch self {
        case .bold: return "bold"
        case .italic: return "italic"
        case .underline: return "underline"
        case .strikethrough: return "strikethrough"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .link: return "link"
        }
    }

    var key: NSAttributedString.Key? {
        switch self {
        case .bold: return .richBold
        case .italic: return .richItalic
        case .underline: return .richUnderline
        case .strikethrough: return .richStrike
        case .code: return .richCode
        case .link: return nil
        }
    }
}

/// A text / highlight color: one of Notion's palette (adapts to dark mode),
/// or a named color from an asset catalog (`.asset("Brand")`).
///
/// ```swift
/// var config = RichEditorConfiguration()
/// config.assetColors = [.asset("Brand"), .asset("Accent")]   // shown first in color menus
/// RichColor.assetBundle = .main                              // where the assets live (default)
/// ```
public struct RichColor: Hashable, RawRepresentable {
    /// Palette name ("red"), "asset:<name>", or "hex:#RRGGBB[AA]" for a picked color.
    public let rawValue: String

    public init?(rawValue: String) {
        if rawValue.hasPrefix(Self.assetPrefix), rawValue.count > Self.assetPrefix.count {
            self.rawValue = rawValue
        } else if rawValue.hasPrefix(Self.hexPrefix), Self.parseHex(String(rawValue.dropFirst(Self.hexPrefix.count))) != nil {
            self.rawValue = rawValue
        } else if Self.palette[rawValue] != nil {
            self.rawValue = rawValue
        } else {
            return nil
        }
    }

    private init(palette name: String) { rawValue = name }

    public static let `default` = RichColor(palette: "default")
    public static let gray = RichColor(palette: "gray")
    public static let brown = RichColor(palette: "brown")
    public static let orange = RichColor(palette: "orange")
    public static let yellow = RichColor(palette: "yellow")
    public static let green = RichColor(palette: "green")
    public static let blue = RichColor(palette: "blue")
    public static let purple = RichColor(palette: "purple")
    public static let pink = RichColor(palette: "pink")
    public static let red = RichColor(palette: "red")

    /// The built-in palette (asset colors are listed by `RichEditorConfiguration.assetColors`).
    public static let allCases: [RichColor] = [.default, .gray, .brown, .orange, .yellow, .green, .blue, .purple, .pink, .red]

    // MARK: Asset colors

    private static let assetPrefix = "asset:"

    /// Bundle that holds the asset catalog of `.asset(_:)` colors.
    public static var assetBundle: Bundle = .main

    /// A named color from the asset catalog in `assetBundle`.
    public static func asset(_ name: String) -> RichColor { RichColor(palette: assetPrefix + name) }

    /// Asset name, for colors made with `.asset(_:)`.
    public var assetName: String? {
        rawValue.hasPrefix(Self.assetPrefix) ? String(rawValue.dropFirst(Self.assetPrefix.count)) : nil
    }

    /// The asset color, or `nil` for palette colors and missing assets.
    private var assetColor: UIColor? {
        assetName.flatMap { UIColor(named: $0, in: Self.assetBundle, compatibleWith: nil) }
    }

    // MARK: Custom colors

    private static let hexPrefix = "hex:"

    /// Any color, e.g. from the system color picker. Stored as sRGB hex, so it
    /// doesn't adapt to dark mode.
    public static func custom(_ color: UIColor) -> RichColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)).getRed(&r, green: &g, blue: &b, alpha: &a)
        let c = { (v: CGFloat) in Int((max(0, min(1, v)) * 255).rounded()) }
        let hex = a < 0.999 ? String(format: "#%02X%02X%02X%02X", c(r), c(g), c(b), c(a))
                            : String(format: "#%02X%02X%02X", c(r), c(g), c(b))
        return RichColor(palette: hexPrefix + hex)
    }

    /// The picked color, for colors made with `.custom(_:)`.
    public var customColor: UIColor? {
        guard rawValue.hasPrefix(Self.hexPrefix) else { return nil }
        return Self.parseHex(String(rawValue.dropFirst(Self.hexPrefix.count)))
    }

    private static func parseHex(_ hex: String) -> UIColor? {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6 || digits.count == 8, let v = UInt64(digits, radix: 16) else { return nil }
        let rgb = digits.count == 8 ? v >> 8 : v
        let alpha = digits.count == 8 ? CGFloat(v & 0xFF) / 255 : 1
        return UIColor(red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                       blue: CGFloat(rgb & 0xFF) / 255, alpha: alpha)
    }

    // MARK: Appearance

    /// "Default", "Red", or the asset name split into words ("BrandBlue" → "Brand Blue").
    public var title: String {
        if let name = assetName {
            var words = ""
            for (i, c) in name.enumerated() {
                if i > 0, c.isUppercase, let previous = words.last, !previous.isUppercase, previous != " " { words.append(" ") }
                words.append(c == "_" || c == "-" ? " " : c)
            }
            return words
        }
        if customColor != nil { return "Custom " + rawValue.dropFirst(Self.hexPrefix.count) }
        return rawValue == "default" ? "Default" : rawValue.capitalized
    }

    /// Text color; `.default` means "the style's text color".
    public var textColor: UIColor {
        if let custom = customColor { return custom }
        if assetName != nil { return assetColor ?? .label }
        let p = Self.palette[rawValue]!
        return Self.dynamic(p.lightText, p.darkText)
    }

    /// Highlight / callout background. Asset colors are used as a light tint
    /// so text stays readable on them.
    public var backgroundColor: UIColor {
        if let custom = customColor { return custom }
        if assetName != nil { return (assetColor ?? .systemGray).withAlphaComponent(0.22) }
        let p = Self.palette[rawValue]!
        return Self.dynamic(p.lightBackground, p.darkBackground)
    }

    /// Light-mode color, used in exported HTML.
    var textHex: String {
        if customColor != nil || assetName != nil { return textColor.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)).cssHex }
        return String(format: "#%06X", Self.palette[rawValue]!.lightText)
    }
    var backgroundHex: String {
        if customColor != nil || assetName != nil { return backgroundColor.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)).cssHex }
        return String(format: "#%06X", Self.palette[rawValue]!.lightBackground)
    }

    /// Palette entry whose light text / background hex matches `hex`.
    static func matching(textHex hex: String) -> RichColor? {
        let value = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16)
        return allCases.first { $0 != .default && palette[$0.rawValue]!.lightText == value }
    }
    static func matching(backgroundHex hex: String) -> RichColor? {
        let value = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16)
        return allCases.first { $0 != .default && palette[$0.rawValue]!.lightBackground == value }
    }

    private struct Entry { let lightText, darkText, lightBackground, darkBackground: UInt32 }

    private static let palette: [String: Entry] = [
        "default": Entry(lightText: 0x37352F, darkText: 0xD4D4D4, lightBackground: 0xF1F1EF, darkBackground: 0x2F2F2F),
        "gray": Entry(lightText: 0x787774, darkText: 0x9B9B9B, lightBackground: 0xF1F1EF, darkBackground: 0x2F2F2F),
        "brown": Entry(lightText: 0x9F6B53, darkText: 0xBA856F, lightBackground: 0xF4EEEE, darkBackground: 0x4A3228),
        "orange": Entry(lightText: 0xD9730D, darkText: 0xC77D48, lightBackground: 0xFBECDD, darkBackground: 0x5C3B23),
        "yellow": Entry(lightText: 0xCB912F, darkText: 0xCA9849, lightBackground: 0xFBF3DB, darkBackground: 0x564328),
        "green": Entry(lightText: 0x448361, darkText: 0x529E72, lightBackground: 0xEDF3EC, darkBackground: 0x243D30),
        "blue": Entry(lightText: 0x337EA9, darkText: 0x5E87C9, lightBackground: 0xE7F3F8, darkBackground: 0x143A4E),
        "purple": Entry(lightText: 0x9065B0, darkText: 0x9D68D3, lightBackground: 0xF6F3F9, darkBackground: 0x3C2D49),
        "pink": Entry(lightText: 0xC14C8A, darkText: 0xD15796, lightBackground: 0xFAF1F5, darkBackground: 0x4E2C3C),
        "red": Entry(lightText: 0xD44C47, darkText: 0xDF5452, lightBackground: 0xFDEBEC, darkBackground: 0x522E2A)
    ]

    private static func dynamic(_ light: UInt32, _ dark: UInt32) -> UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? rgb(dark) : rgb(light) }
    }
    private static func rgb(_ v: UInt32) -> UIColor {
        UIColor(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}

extension NSAttributedString.Key {
    // Paragraph level: applied to every character of a paragraph.
    /// `RichBlockType.rawValue` of the paragraph.
    public static let richBlock = NSAttributedString.Key("RichContent.block")
    /// Int ≥ 1, nesting level of the block (Tab / Shift-Tab).
    public static let richListLevel = NSAttributedString.Key("RichContent.listLevel")
    /// Bool, to-do checked.
    public static let richChecked = NSAttributedString.Key("RichContent.checked")
    /// `RichToggleChildren`: present while a toggle is collapsed.
    public static let richToggleChildren = NSAttributedString.Key("RichContent.toggleChildren")
    /// String emoji of a callout.
    public static let richCalloutEmoji = NSAttributedString.Key("RichContent.calloutEmoji")
    /// `RichColor.rawValue`, background of a callout.
    public static let richBlockColor = NSAttributedString.Key("RichContent.blockColor")
    /// String language of a code block ("swift", "json" …).
    public static let richCodeLanguage = NSAttributedString.Key("RichContent.codeLanguage")

    // Character level: the semantic format; fonts / colors are derived from it.
    public static let richBold = NSAttributedString.Key("RichContent.bold")
    public static let richItalic = NSAttributedString.Key("RichContent.italic")
    public static let richUnderline = NSAttributedString.Key("RichContent.underline")
    public static let richStrike = NSAttributedString.Key("RichContent.strike")
    public static let richCode = NSAttributedString.Key("RichContent.code")
    /// `RichColor.rawValue` of the text.
    public static let richTextColor = NSAttributedString.Key("RichContent.textColor")
    /// `RichColor.rawValue` of the highlight.
    public static let richHighlight = NSAttributedString.Key("RichContent.highlight")
}

/// Blocks hidden inside a collapsed toggle. Compared by identity so text
/// storage doesn't diff whole documents while merging attribute runs.
public final class RichToggleChildren: NSObject {
    /// The hidden paragraphs, with the levels they had when collapsed.
    let content: NSAttributedString
    /// Level of the toggle when it was collapsed (children are deeper).
    let level: Int

    init(content: NSAttributedString, level: Int) {
        self.content = content
        self.level = level
    }
}

extension UIFont {
    func setting(_ trait: UIFontDescriptor.SymbolicTraits, _ on: Bool) -> UIFont {
        var traits = fontDescriptor.symbolicTraits
        if on { traits.insert(trait) } else { traits.remove(trait) }
        guard let descriptor = fontDescriptor.withSymbolicTraits(traits) else { return self }
        return UIFont(descriptor: descriptor, size: pointSize)
    }

    var isMonospaced: Bool { fontDescriptor.symbolicTraits.contains(.traitMonoSpace) }
    var isBold: Bool { fontDescriptor.symbolicTraits.contains(.traitBold) }
    var isItalic: Bool { fontDescriptor.symbolicTraits.contains(.traitItalic) }
}

// MARK: - Paragraph info

/// Paragraph-level attributes of one block.
struct BlockInfo: Equatable {
    var type: RichBlockType = .paragraph
    var level = 1
    var checked = false
    var emoji: String?
    var color: RichColor?
    var language: String?
    var collapsed: RichToggleChildren?

    init(type: RichBlockType = .paragraph, level: Int = 1) {
        self.type = type
        self.level = level
    }

    init(_ attributes: [NSAttributedString.Key: Any]) {
        type = (attributes[.richBlock] as? String).flatMap(RichBlockType.init(rawValue:)) ?? .paragraph
        level = max(attributes[.richListLevel] as? Int ?? 1, 1)
        checked = attributes[.richChecked] as? Bool ?? false
        emoji = attributes[.richCalloutEmoji] as? String
        color = (attributes[.richBlockColor] as? String).flatMap(RichColor.init(rawValue:))
        language = attributes[.richCodeLanguage] as? String
        collapsed = attributes[.richToggleChildren] as? RichToggleChildren
    }

    /// Paragraph attributes to store, without the derived visual ones.
    var attributes: [NSAttributedString.Key: Any] {
        var a: [NSAttributedString.Key: Any] = [.richBlock: type.rawValue, .richListLevel: level]
        if type == .todo, checked { a[.richChecked] = true }
        if type == .callout { a[.richCalloutEmoji] = emoji ?? "💡" }
        if let color, type == .callout { a[.richBlockColor] = color.rawValue }
        if let language, type == .codeBlock { a[.richCodeLanguage] = language }
        if let collapsed, type == .toggle { a[.richToggleChildren] = collapsed }
        return a
    }

    static let keys: [NSAttributedString.Key] = [
        .richBlock, .richListLevel, .richChecked, .richCalloutEmoji, .richBlockColor, .richCodeLanguage, .richToggleChildren
    ]

    static func == (a: BlockInfo, b: BlockInfo) -> Bool {
        a.type == b.type && a.level == b.level && a.checked == b.checked && a.emoji == b.emoji
            && a.color == b.color && a.language == b.language && a.collapsed === b.collapsed
    }
}

/// Character-level formats of one run.
struct InlineInfo: Equatable {
    var bold = false, italic = false, underline = false, strike = false, code = false
    var link: URL?
    var color: RichColor?
    var highlight: RichColor?

    init() {}

    init(_ a: [NSAttributedString.Key: Any]) {
        bold = a[.richBold] as? Bool ?? false
        italic = a[.richItalic] as? Bool ?? false
        underline = a[.richUnderline] as? Bool ?? false
        strike = a[.richStrike] as? Bool ?? false
        code = a[.richCode] as? Bool ?? false
        if let url = a[.link] as? URL { link = url } else if let s = a[.link] as? String { link = URL(string: s) }
        color = (a[.richTextColor] as? String).flatMap(RichColor.init(rawValue:))
        highlight = (a[.richHighlight] as? String).flatMap(RichColor.init(rawValue:))
    }

    var attributes: [NSAttributedString.Key: Any] {
        var a: [NSAttributedString.Key: Any] = [:]
        if bold { a[.richBold] = true }
        if italic { a[.richItalic] = true }
        if underline { a[.richUnderline] = true }
        if strike { a[.richStrike] = true }
        if code { a[.richCode] = true }
        if let link { a[.link] = link }
        if let color, color != .default { a[.richTextColor] = color.rawValue }
        if let highlight, highlight != .default { a[.richHighlight] = highlight.rawValue }
        return a
    }

    static let keys: [NSAttributedString.Key] = [.richBold, .richItalic, .richUnderline, .richStrike, .richCode, .link, .richTextColor, .richHighlight]
}

// MARK: - Styling

/// Derives fonts, colors and paragraph styles from the semantic attributes.
/// Everything visual in the editor goes through here, so typing, importing,
/// formatting and undo all look the same.
enum EditorStyling {

    static let maxLevel = 6
    static let attachmentCharacter = "\u{FFFC}"
    static let lineBreak = "\u{2028}"

    struct Metrics {
        let indentStep: CGFloat
        let markerWidth: CGFloat = 26
        let quoteTextOffset: CGFloat = 16
        let boxPadding: CGFloat = 12
        let boxMargin: CGFloat = 4
        let calloutEmojiWidth: CGFloat = 30

        init(_ style: RichContentStyle) { indentStep = max(style.listIndent, 24) }

        func base(_ level: Int) -> CGFloat { CGFloat(max(level, 1) - 1) * indentStep }

        /// Leading edge of the text of a block.
        func textIndent(_ info: BlockInfo) -> CGFloat {
            let base = base(info.level)
            switch info.type {
            case _ where info.type.hasMarker: return base + markerWidth
            case .quote: return base + quoteTextOffset
            case .callout: return base + boxPadding + calloutEmojiWidth
            case .codeBlock: return base + boxPadding
            default: return base
            }
        }
    }

    static func baseFont(for block: RichBlockType, style: RichContentStyle) -> UIFont {
        let base = style.font
        switch block {
        case .heading1: return base.withSize(base.pointSize * 1.75).adding(.traitBold)
        case .heading2: return base.withSize(base.pointSize * 1.45).adding(.traitBold)
        case .heading3: return base.withSize(base.pointSize * 1.2).adding(.traitBold)
        case .codeBlock: return style.codeFont
        default: return base
        }
    }

    static func paragraphStyle(for info: BlockInfo, style: RichContentStyle) -> NSParagraphStyle {
        let m = Metrics(style)
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byWordWrapping
        p.lineSpacing = style.lineSpacing
        p.paragraphSpacing = style.paragraphSpacing / 2
        let indent = m.textIndent(info)
        p.firstLineHeadIndent = indent
        p.headIndent = indent
        p.tabStops = []
        p.defaultTabInterval = 28

        switch info.type {
        case .heading1:
            p.paragraphSpacingBefore = style.paragraphSpacing * 2.5
            p.paragraphSpacing = style.paragraphSpacing / 2
        case .heading2:
            p.paragraphSpacingBefore = style.paragraphSpacing * 2
            p.paragraphSpacing = style.paragraphSpacing / 2
        case .heading3:
            p.paragraphSpacingBefore = style.paragraphSpacing * 1.5
            p.paragraphSpacing = style.paragraphSpacing / 2
        case .callout, .codeBlock:
            p.tailIndent = -m.boxPadding
            p.paragraphSpacingBefore = m.boxMargin + m.boxPadding
            p.paragraphSpacing = m.boxMargin + m.boxPadding
        case .divider:
            p.paragraphSpacingBefore = 2
            p.paragraphSpacing = 2
        case .image:
            p.paragraphSpacingBefore = 4
            p.paragraphSpacing = style.paragraphSpacing
        default:
            break
        }
        return p
    }

    /// Full attributes for a run: paragraph info + inline formats → visuals.
    static func attributes(block info: BlockInfo, inline: InlineInfo,
                           style: RichContentStyle) -> [NSAttributedString.Key: Any] {
        var a = info.attributes.merging(inline.attributes) { $1 }
        let base = baseFont(for: info.type, style: style)

        var font: UIFont
        if info.type == .codeBlock {
            font = style.codeFont
        } else if inline.code {
            font = style.codeFont.withSize(base.pointSize * 0.9)
        } else {
            var traits: UIFontDescriptor.SymbolicTraits = []
            if inline.bold { traits.insert(.traitBold) }
            if inline.italic { traits.insert(.traitItalic) }
            font = base.adding(traits)
        }
        a[.font] = font
        a[.paragraphStyle] = paragraphStyle(for: info, style: style)

        let checkedTodo = info.type == .todo && info.checked
        var color = style.textColor
        if let c = inline.color, c != .default { color = c.textColor }
        if checkedTodo { color = style.secondaryTextColor }
        a[.foregroundColor] = color

        if let h = inline.highlight, h != .default {
            a[.backgroundColor] = h.backgroundColor
        } else if inline.code && info.type != .codeBlock {
            a[.backgroundColor] = style.codeBackgroundColor
        }
        if inline.underline { a[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if inline.strike || checkedTodo {
            a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            if checkedTodo { a[.strikethroughColor] = style.secondaryTextColor }
        }
        return a
    }

    /// Typing attributes for an empty block.
    static func typingAttributes(for info: BlockInfo, inline: InlineInfo = InlineInfo(),
                                 style: RichContentStyle) -> [NSAttributedString.Key: Any] {
        attributes(block: info, inline: inline, style: style)
    }

    // MARK: Reading the model

    static func info(in s: NSAttributedString, at index: Int) -> BlockInfo {
        guard s.length > 0 else { return BlockInfo() }
        return BlockInfo(s.attributes(at: min(max(index, 0), s.length - 1), effectiveRange: nil))
    }

    static func block(in s: NSAttributedString, at index: Int) -> RichBlockType { info(in: s, at: index).type }

    static func block(in attributes: [NSAttributedString.Key: Any]) -> RichBlockType { BlockInfo(attributes).type }

    static func listLevel(in s: NSAttributedString, at index: Int) -> Int { info(in: s, at: index).level }

    /// Paragraph ranges (including their terminating newline) in `s`.
    static func paragraphRanges(in s: NSAttributedString, within range: NSRange? = nil) -> [NSRange] {
        let ns = s.string as NSString
        var ranges: [NSRange] = []
        ns.enumerateSubstrings(in: range ?? NSRange(location: 0, length: ns.length),
                               options: [.byParagraphs, .substringNotRequired]) { _, _, enclosing, _ in
            ranges.append(enclosing)
        }
        return ranges
    }

    /// Info of the paragraph `range`, read from its first character (an empty
    /// last paragraph has none; the caller supplies typing attributes).
    static func info(ofParagraph range: NSRange, in s: NSAttributedString) -> BlockInfo {
        range.length > 0 ? info(in: s, at: range.location) : BlockInfo()
    }

    // MARK: Restyling

    /// Writes `info` onto a whole paragraph (content + terminator) and
    /// re-derives every visual attribute, keeping inline formats.
    static func apply(_ info: BlockInfo, toParagraph range: NSRange, in s: NSMutableAttributedString, style: RichContentStyle) {
        guard range.length > 0 else { return }
        var runs: [(NSRange, [NSAttributedString.Key: Any])] = []
        s.enumerateAttributes(in: range) { attrs, r, _ in
            var a = attributes(block: info, inline: InlineInfo(attrs), style: style)
            if let attachment = attrs[.attachment] { a[.attachment] = attachment }
            runs.append((r, a))
        }
        for (r, a) in runs { s.setAttributes(a, range: r) }
    }

    /// Makes every paragraph in `range` uniform (paragraph attributes from its
    /// first character) and re-derives visuals. Only touches runs that differ.
    static func normalize(_ s: NSMutableAttributedString, in range: NSRange, style: RichContentStyle) {
        let ns = s.string as NSString
        guard ns.length > 0 else { return }
        let clamped = NSIntersectionRange(range, NSRange(location: 0, length: ns.length))
        let paragraphs = ns.paragraphRange(for: NSRange(location: clamped.location, length: clamped.length))
        for p in paragraphRanges(in: s, within: paragraphs) {
            var info = self.info(in: s, at: p.location)
            if info.type.isAttachment {
                // An attachment block holds exactly one attachment.
                if attachmentRange(inParagraph: p, of: s) == nil { info = BlockInfo(type: .paragraph, level: info.level) }
            }
            s.enumerateAttributes(in: p) { attrs, r, _ in
                var a = attributes(block: info, inline: InlineInfo(attrs), style: style)
                if let attachment = attrs[.attachment] { a[.attachment] = attachment }
                if !NSDictionary(dictionary: attrs).isEqual(to: a) { s.setAttributes(a, range: r) }
            }
        }
    }

    /// The attachment character of an image / divider paragraph.
    static func attachmentRange(inParagraph p: NSRange, of s: NSAttributedString) -> NSRange? {
        var found: NSRange?
        s.enumerateAttribute(.attachment, in: p) { value, r, stop in
            if value != nil { found = NSRange(location: r.location, length: 1); stop.pointee = true }
        }
        return found
    }

    /// Paragraphs nested under the paragraph at `range` (deeper level,
    /// contiguous). Returns the range covering them, possibly empty.
    static func childrenRange(of range: NSRange, in s: NSAttributedString) -> NSRange {
        let level = info(ofParagraph: range, in: s).level
        let ns = s.string as NSString
        var end = NSMaxRange(range)
        while end < ns.length {
            let next = ns.paragraphRange(for: NSRange(location: end, length: 0))
            guard info(in: s, at: next.location).level > level else { break }
            end = NSMaxRange(next)
        }
        return NSRange(location: NSMaxRange(range), length: end - NSMaxRange(range))
    }
}
