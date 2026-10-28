import SwiftUI
import UIKit

/// Renders HTML, Markdown, plain text, `AttributedString`,
/// `NSAttributedString` or any mix of them.
///
/// ```swift
/// ScrollView {
///     RichContentView(.auto(email.body))
///         .richContentStyle(.email)
///         .padding(.horizontal, 16)
/// }
/// ```
/// - Native content is one selectable text view that sizes itself to the
///   available width (put it inside a `ScrollView`).
/// - Native HTML import runs asynchronously and is cached.
/// - Link taps go through the `openURL` environment action, so
///   `.environment(\.openURL, …)` can intercept them.
public struct RichContentView: View {

    private let content: RichContent
    @Environment(\.richContentStyle) private var style
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var asyncBlocks: [RenderedBlock]?
    @State private var asyncKey: RenderKey?

    public init(_ content: RichContent) {
        self.content = content
    }

    private var key: RenderKey {
        RenderKey(content: content, style: style, dynamicTypeSize: dynamicTypeSize)
    }

    public var body: some View {
        let immediate = RichContentRenderer.immediateBlocks(for: content, style: style)
        let blocks = immediate ?? (asyncKey == key ? asyncBlocks : nil)

        Group {
            if let blocks {
                VStack(alignment: .leading, spacing: style.paragraphSpacing) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                        switch block {
                        case .text(let text):
                            RichTextRepresentable(text: text, style: style, openURL: { openURL($0) })
                                .padding(.horizontal, style.horizontalPadding)
                        case .web(let html):
                            RichWebBlock(html: html, style: style, openURL: { openURL($0) })
                                .padding(.horizontal, webPadding(for: html))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, style.verticalPadding)
            } else {
                RichContentPlaceholder()
                    .padding(.horizontal, style.horizontalPadding)
                    .padding(.vertical, style.verticalPadding)
            }
        }
        .task(id: key) {
            guard immediate == nil else { return }
            let currentKey = key
            let rendered = await RichContentRenderer.renderAsync(content, style: style)
            guard !Task.isCancelled else { return }
            asyncBlocks = rendered
            asyncKey = currentKey
        }
    }
}

extension RichContentView {
    private func webPadding(for html: String) -> CGFloat {
        switch style.webPadding {
        case .always: return style.horizontalPadding
        case .never: return 0
        case .automatic: return HTMLRenderer.isDesignedLayout(html) ? 0 : style.horizontalPadding
        }
    }
}

private struct RenderKey: Hashable {
    let content: RichContent
    let style: RichContentStyle
    let dynamicTypeSize: DynamicTypeSize
}

// MARK: - Style environment

private struct RichContentStyleKey: EnvironmentKey {
    static var defaultValue: RichContentStyle { .standard }
}

public extension EnvironmentValues {
    var richContentStyle: RichContentStyle {
        get { self[RichContentStyleKey.self] }
        set { self[RichContentStyleKey.self] = newValue }
    }
}

public extension View {
    func richContentStyle(_ style: RichContentStyle) -> some View {
        environment(\.richContentStyle, style)
    }

    /// Adjusts the inherited style, e.g. `.richContentStyle { $0.horizontalPadding = 20 }`.
    func richContentStyle(_ transform: @escaping (inout RichContentStyle) -> Void) -> some View {
        transformEnvironment(\.richContentStyle, transform: transform)
    }
}

// MARK: - Native text block

struct RichTextRepresentable: UIViewRepresentable {
    let text: NSAttributedString
    let style: RichContentStyle
    let openURL: (URL) -> Void

    func makeUIView(context: Context) -> RichContentTextView {
        RichContentTextView(style: style)
    }

    func updateUIView(_ view: RichContentTextView, context: Context) {
        view.onOpenURL = openURL
        if view.richStyle != style { view.richStyle = style }
        // `attributedText` is `NSAttributedString!` and can be nil on a fresh
        // view (iOS 18+); `textStorage` is always there.
        if !view.textStorage.isEqual(to: text) {
            view.textStorage.setAttributedString(text)
            view.invalidateIntrinsicContentSize()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: RichContentTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(size.height))
    }
}

// MARK: - Web block

struct RichWebBlock: View {
    let html: String
    let style: RichContentStyle
    let openURL: (URL) -> Void
    @State private var height: CGFloat = 1

    var body: some View {
        RichWebRepresentable(html: html, style: style, openURL: openURL, height: $height)
            .frame(height: height)
    }
}

private struct RichWebRepresentable: UIViewRepresentable {
    let html: String
    let style: RichContentStyle
    let openURL: (URL) -> Void
    @Binding var height: CGFloat

    func makeUIView(context: Context) -> RichWebContentView {
        RichWebContentView(frame: .zero)
    }

    func updateUIView(_ view: RichWebContentView, context: Context) {
        view.onOpenURL = openURL
        view.onHeightChange = { newHeight in
            if abs(newHeight - height) > 0.5 { height = newHeight }
        }
        view.load(html: html, style: style)
    }
}

// MARK: - Placeholder while HTML imports

private struct RichContentPlaceholder: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach([1.0, 0.92, 0.6], id: \.self) { fraction in
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(uiColor: .tertiarySystemFill))
                    .frame(height: 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .scaleEffect(x: fraction, y: 1, anchor: .leading)
            }
        }
        .accessibilityLabel("Loading content")
        .redacted(reason: .placeholder)
    }
}
