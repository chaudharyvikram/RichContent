import UIKit

/// Visual settings shared by every renderer. All colors default to dynamic
/// system colors, so light / dark mode work without re-rendering native text.
public struct RichContentStyle: Hashable {

    public enum HTMLRendering: Hashable {
        /// Native text for simple HTML; web view for tables, images, media.
        case automatic
        /// Always `NSAttributedString` (fast, selectable, no images).
        case native
        /// Always a sandboxed `WKWebView`.
        case web
    }

    // Text
    public var font: UIFont = .preferredFont(forTextStyle: .body)
    public var textColor: UIColor = .label
    public var secondaryTextColor: UIColor = .secondaryLabel
    public var linkColor: UIColor = .tintColor
    public var codeFont: UIFont = .monospacedSystemFont(
        ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize * 0.9, weight: .regular)
    public var codeBackgroundColor: UIColor = .secondarySystemBackground

    // Spacing
    public var lineSpacing: CGFloat = 2
    public var paragraphSpacing: CGFloat = 8
    public var listIndent: CGFloat = 20

    // Quotes ("> " lines, <blockquote>, markdown quotes)
    public var quoteBarColor: UIColor = .separator
    public var quoteBarWidth: CGFloat = 2
    /// Horizontal step per quote level (bar + gap).
    public var quoteIndent: CGFloat = 12
    public var dimsQuotedText: Bool = true

    // Padding
    public enum WebPadding: Hashable {
        /// Pad simple HTML like text; let designed emails (newsletters with
        /// layout tables / backgrounds) run edge to edge with their own margins.
        case automatic
        case always
        case never
    }
    /// Left / right padding around content.
    public var horizontalPadding: CGFloat = 0
    /// Top / bottom padding around the whole content.
    public var verticalPadding: CGFloat = 0
    public var webPadding: WebPadding = .automatic
    /// Editor only: left / right margin, used exactly as given on both sides.
    /// `nil` (default) uses `horizontalPadding`, widened to fit the block
    /// handle (⋮⋮) when it is shown.
    public var editorHorizontalPadding: CGFloat?

    // Behaviour
    /// Web view only: also apply `font` to HTML that declares its own fonts
    /// (newsletters). Off keeps the sender's design; `font` is still the default.
    public var forcesBaseFontInWebContent: Bool = false
    public var htmlRendering: HTMLRendering = .automatic
    /// Replace the fonts / near-black colors HTML brings with this style's,
    /// so emails match the app and follow dark mode.
    public var normalizesHTMLFonts: Bool = true
    /// Web view only: load remote images, fonts and CSS. Off by default
    /// (blocks tracking pixels).
    public var allowsRemoteContent: Bool = false
    public var detectsLinks: Bool = true
    /// Keep single newlines in Markdown as line breaks (email-style text).
    public var preservesMarkdownLineBreaks: Bool = true

    public init() {}

    public static var standard: RichContentStyle { RichContentStyle() }

    /// Uses a custom base font everywhere (native text, Markdown headings,
    /// HTML, web view). Bold / italic come from the same family's faces.
    /// - Parameters:
    ///   - font: e.g. `UIFont(name: "Inter-Regular", size: 16)!`
    ///   - textStyle: Dynamic Type style to scale with.
    ///   - scalesWithDynamicType: pass `false` for a fixed size.
    public mutating func setFont(_ font: UIFont,
                                 relativeTo textStyle: UIFont.TextStyle = .body,
                                 scalesWithDynamicType: Bool = true) {
        self.font = scalesWithDynamicType
            ? UIFontMetrics(forTextStyle: textStyle).scaledFont(for: font)
            : font
    }

    /// Same as `setFont`, for a monospaced code font.
    public mutating func setCodeFont(_ font: UIFont,
                                     relativeTo textStyle: UIFont.TextStyle = .body,
                                     scalesWithDynamicType: Bool = true) {
        self.codeFont = scalesWithDynamicType
            ? UIFontMetrics(forTextStyle: textStyle).scaledFont(for: font)
            : font
    }

    /// Returns a copy with a custom base font.
    public func font(_ font: UIFont, relativeTo textStyle: UIFont.TextStyle = .body) -> RichContentStyle {
        var copy = self
        copy.setFont(font, relativeTo: textStyle)
        return copy
    }

    /// Returns a copy with padding.
    public func padding(horizontal: CGFloat, vertical: CGFloat = 0) -> RichContentStyle {
        var copy = self
        copy.horizontalPadding = horizontal
        copy.verticalPadding = vertical
        return copy
    }

    /// Compact reading style used on the email detail screen.
    public static var email: RichContentStyle {
        var style = RichContentStyle()
        style.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 16))
        style.codeFont = UIFontMetrics(forTextStyle: .body)
            .scaledFont(for: .monospacedSystemFont(ofSize: 14, weight: .regular))
        style.paragraphSpacing = 6
        style.quoteIndent = 12
        style.horizontalPadding = 16
        style.verticalPadding = 8
        return style
    }
}
