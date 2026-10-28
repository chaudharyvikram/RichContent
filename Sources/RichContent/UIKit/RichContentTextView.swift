import UIKit

/// TextKit 1 layout manager that draws a vertical bar per quote level for
/// text tagged with `.richQuoteDepth`.
class QuoteBarLayoutManager: NSLayoutManager {
    var barColor: UIColor = .separator
    var barWidth: CGFloat = 2
    var levelIndent: CGFloat = 12

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let container = textContainers.first else { return }

        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        barColor.setFill()

        storage.enumerateAttribute(.richQuoteDepth, in: characters) { value, range, _ in
            guard let depth = value as? Int, depth > 0 else { return }
            let glyphs = self.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var minY = CGFloat.greatestFiniteMagnitude
            var maxY: CGFloat = 0
            self.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, _, _ in
                minY = min(minY, rect.minY)
                maxY = max(maxY, rect.maxY)
            }
            guard minY < maxY else { return }
            for level in 0..<depth {
                let x = origin.x + container.lineFragmentPadding + CGFloat(level) * self.levelIndent
                UIRectFill(CGRect(x: x, y: origin.y + minY, width: self.barWidth, height: maxY - minY))
            }
        }
    }
}

/// TextKit 1 stack shared by the viewer and the editor.
///
/// IMPORTANT: the caller must keep a strong reference to the returned
/// storage. In TextKit 1 the storage owns the layout manager, the layout
/// manager owns the container, and the text view only retains the
/// container, so nothing else keeps the storage alive. Without it the
/// storage is freed: `attributedText` becomes nil and text never shows.
enum TextKitStack {
    static func make<L: NSLayoutManager>(_ layoutManager: L) -> (NSTextStorage, L, NSTextContainer) {
        let storage = NSTextStorage()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        return (storage, layoutManager, container)
    }
}

/// Read-only, selectable, self-sizing text view for rendered rich content.
/// Use directly from UIKit, or via `RichContentView` in SwiftUI.
public final class RichContentTextView: UITextView {

    /// Strong reference: keeps the TextKit 1 stack alive (see `TextKitStack`).
    private let richTextStorage: NSTextStorage
    private let quoteLayoutManager: QuoteBarLayoutManager

    public var richStyle: RichContentStyle {
        didSet { applyStyle() }
    }

    /// Called when a link is tapped. `nil` opens it with the system.
    public var onOpenURL: ((URL) -> Void)?

    public init(style: RichContentStyle = .standard) {
        let (storage, layoutManager, container) = TextKitStack.make(QuoteBarLayoutManager())
        self.richTextStorage = storage
        self.quoteLayoutManager = layoutManager
        self.richStyle = style
        super.init(frame: .zero, textContainer: container)

        isEditable = false
        isSelectable = true
        isScrollEnabled = false
        backgroundColor = .clear
        textContainerInset = .zero
        dataDetectorTypes = []
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.defaultHigh, for: .vertical)
        delegate = self
        applyStyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows any `RichContent` that renders natively (HTML is imported natively).
    public func setContent(_ content: RichContent) {
        textStorage.setAttributedString(RichContentRenderer.attributedString(for: content, style: richStyle))
        invalidateIntrinsicContentSize()
    }

    private func applyStyle() {
        quoteLayoutManager.barColor = richStyle.quoteBarColor
        quoteLayoutManager.barWidth = richStyle.quoteBarWidth
        quoteLayoutManager.levelIndent = richStyle.quoteIndent
        linkTextAttributes = [.foregroundColor: richStyle.linkColor]
        setNeedsDisplay()
    }
}

extension RichContentTextView: UITextViewDelegate {

    @available(iOS 17.0, *)
    public func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction) -> UIAction? {
        guard case .link(let url) = textItem.content, let handler = onOpenURL else { return defaultAction }
        return UIAction { _ in handler(url) }
    }

    // iOS 16
    public func textView(_ textView: UITextView, shouldInteractWith URL: URL, in characterRange: NSRange, interaction: UITextItemInteraction) -> Bool {
        guard interaction == .invokeDefaultAction, let handler = onOpenURL else { return true }
        handler(URL)
        return false
    }
}
