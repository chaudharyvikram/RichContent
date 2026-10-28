import SwiftUI
import UIKit

/// The message being replied to, shown read-only below the editable text,
/// like the quoted original in Mail and Gmail.
///
/// ```swift
/// editor.quotedOriginal = QuotedOriginal(.auto(email.body),
///                                        attribution: "On Oct 28, 2026 at 9:41 AM, Alex Kim wrote:")
/// send(editor.replyHTML())   // the reply, the attribution and the quoted original
/// ```
public struct QuotedOriginal: Hashable {
    public var content: RichContent
    /// The "On …, … wrote:" line above the quote. Empty hides it.
    public var attribution: String

    public init(_ content: RichContent, attribution: String = "") {
        self.content = content
        self.attribution = attribution
    }
}

/// Renders a `QuotedOriginal` with the read-only viewer (native text, or the
/// web view for designed emails) behind a quote bar, and reports its height.
struct EditorQuotedOriginalView: View {
    let quoted: QuotedOriginal
    let style: RichContentStyle
    let openURL: (URL) -> Void
    let onHeightChange: (CGFloat) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !quoted.attribution.isEmpty {
                Text(quoted.attribution)
                    .font(Font(style.font as CTFont))
                    .foregroundStyle(Color(uiColor: style.secondaryTextColor))
            }
            HStack(alignment: .top, spacing: 0) {
                Rectangle()
                    .fill(Color(uiColor: style.quoteBarColor))
                    .frame(width: style.quoteBarWidth)
                RichContentView(quoted.content)
                    .richContentStyle(quotedStyle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { Color.clear.preference(key: QuotedHeightKey.self, value: $0.size.height) })
        .onPreferenceChange(QuotedHeightKey.self, perform: onHeightChange)
        .environment(\.openURL, OpenURLAction { url in openURL(url); return .handled })
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Original message")
    }

    /// The editor's style, inset from the quote bar instead of the screen edge.
    private var quotedStyle: RichContentStyle {
        var quoted = style
        quoted.horizontalPadding = max(style.quoteIndent - style.quoteBarWidth, 8)
        quoted.verticalPadding = 0
        return quoted
    }
}

private struct QuotedHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

// MARK: - Hosting it in the text view

extension RichEditorTextView {

    /// Space between the last line of the reply and the quoted original.
    private var quotedSpacing: CGFloat { 24 }

    /// Room below the text for the quoted original. It lives in
    /// `contentInset`, not `textContainerInset`: UITextView scrolls the text
    /// container's bottom inset into view along with a caret on the last line,
    /// which made Return jump to the end of the quoted original.
    var quotedReservedHeight: CGFloat {
        quotedHost == nil || quotedHeight <= 0 ? 0 : quotedSpacing + quotedHeight
    }

    /// Shows, updates or removes the quoted original from the controller.
    func quotedOriginalDidChange() {
        guard showsQuotedOriginal, let controller = editorController, let quoted = controller.quotedOriginal else {
            quotedHost?.view.removeFromSuperview()
            quotedHost = nil
            quotedHeight = 0
            updateQuotedInset()
            return
        }
        let root = EditorQuotedOriginalView(
            quoted: quoted, style: controller.style,
            openURL: { [weak controller] url in
                if let open = controller?.onOpenURL { open(url) } else { UIApplication.shared.open(url) }
            },
            onHeightChange: { [weak self] height in self?.quotedHeightDidChange(height) })
        if let host = quotedHost {
            host.rootView = root
        } else {
            let host = UIHostingController(rootView: root)
            host.view.backgroundColor = .clear
            // It sits inside a scroll view: no safe-area or keyboard padding.
            if #available(iOS 16.4, *) { host.safeAreaRegions = [] }
            quotedHost = host
            addSubview(host.view)
        }
        setNeedsLayout()
    }

    private func quotedHeightDidChange(_ height: CGFloat) {
        guard abs(height - quotedHeight) > 0.5 else { return }
        quotedHeight = height
        updateQuotedInset()
        setNeedsLayout()
    }

    /// Adds / removes only this view's share of `contentInset.bottom`, so an
    /// app's own inset (e.g. for the keyboard) is kept.
    func updateQuotedInset() {
        let reserved = quotedReservedHeight
        let delta = reserved - appliedQuotedInset
        guard abs(delta) > 0.5 else { return }
        contentInset.bottom += delta
        appliedQuotedInset = reserved
        invalidateIntrinsicContentSize()
    }

    /// Places the quoted original right below the last line of text.
    func layoutQuotedOriginal() {
        guard let host = quotedHost else { return }
        let inset = textContainerInset
        layoutManager.ensureLayout(for: textContainer)
        let textBottom = inset.top + layoutManager.usedRect(for: textContainer).maxY
        let width = max(bounds.width - inset.left - inset.right, 0)
        let height = quotedHeight > 0 ? quotedHeight : 1
        host.view.frame = CGRect(x: inset.left, y: textBottom + quotedSpacing, width: width, height: height)
    }

    /// The quoted original is read-only: taps and presses on it never reach
    /// the text view (no caret, no selection), only scrolling does.
    func isQuotedOriginalTouch(_ recognizer: UIGestureRecognizer) -> Bool {
        guard let host = quotedHost, recognizer !== panGestureRecognizer else { return false }
        return host.view.frame.contains(recognizer.location(in: self))
    }
}
