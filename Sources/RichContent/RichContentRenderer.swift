import UIKit

/// One visual block of rendered content.
public enum RenderedBlock {
    /// Native text: plain, Markdown, attributed and simple HTML, merged.
    case text(NSAttributedString)
    /// HTML that needs a browser engine (tables, images, media).
    case web(html: String)
}

/// Turns `RichContent` into display blocks, with an in-memory cache.
@MainActor
public enum RichContentRenderer {

    private final class Box {
        let blocks: [RenderedBlock]
        init(_ blocks: [RenderedBlock]) { self.blocks = blocks }
    }

    private static let cache: NSCache<NSNumber, Box> = {
        let cache = NSCache<NSNumber, Box>()
        cache.countLimit = 64
        return cache
    }()

    private static func cacheKey(_ content: RichContent, _ style: RichContentStyle) -> NSNumber? {
        guard content.isCacheable else { return nil }
        var hasher = Hasher()
        hasher.combine(content)
        hasher.combine(style)
        hasher.combine(UIApplication.shared.preferredContentSizeCategory.rawValue)
        return NSNumber(value: hasher.finalize())
    }

    /// Cached blocks, or a fresh render when that is cheap (no native-HTML
    /// import involved). `nil` means: call `render` asynchronously.
    public static func immediateBlocks(for content: RichContent, style: RichContentStyle) -> [RenderedBlock]? {
        if let key = cacheKey(content, style), let hit = cache.object(forKey: key) { return hit.blocks }
        let needsImport = content.flattened.contains { part in
            if case .html(let html) = part { return !usesWebView(html, style: style) }
            return false
        }
        return needsImport ? nil : render(content, style: style)
    }

    /// Renders after yielding once, so the screen can appear before the
    /// HTML importer runs.
    public static func renderAsync(_ content: RichContent, style: RichContentStyle) async -> [RenderedBlock] {
        await Task.yield()
        return render(content, style: style)
    }

    /// Synchronous render (may block briefly for native HTML).
    public static func render(_ content: RichContent, style: RichContentStyle) -> [RenderedBlock] {
        let key = cacheKey(content, style)
        if let key, let hit = cache.object(forKey: key) { return hit.blocks }

        var blocks: [RenderedBlock] = []
        var pendingText: NSMutableAttributedString?

        func flushText() {
            guard let text = pendingText, text.length > 0 else { pendingText = nil; return }
            if style.detectsLinks { TextKitHelpers.linkify(text) }
            blocks.append(.text(text))
            pendingText = nil
        }

        for part in content.flattened {
            if case .html(let html) = part, usesWebView(html, style: style) {
                flushText()
                blocks.append(.web(html: html))
                continue
            }
            let attributed = nativeAttributedString(for: part, style: style)
            guard attributed.length > 0 else { continue }
            if pendingText == nil { pendingText = NSMutableAttributedString() }
            TextKitHelpers.appendParagraph(attributed, to: pendingText!)
        }
        flushText()

        if let key { cache.setObject(Box(blocks), forKey: key) }
        return blocks
    }

    /// Everything as one `NSAttributedString` (HTML always imported natively).
    /// Handy for UIKit labels, previews, search snippets or copy/share.
    public static func attributedString(for content: RichContent, style: RichContentStyle = .standard) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for part in content.flattened {
            TextKitHelpers.appendParagraph(nativeAttributedString(for: part, style: style), to: result)
        }
        if style.detectsLinks { TextKitHelpers.linkify(result) }
        return result
    }

    // MARK: - Per-format

    private static func usesWebView(_ html: String, style: RichContentStyle) -> Bool {
        switch style.htmlRendering {
        case .native: return false
        case .web: return true
        case .automatic: return HTMLRenderer.prefersWebView(html)
        }
    }

    private static func nativeAttributedString(for part: RichContent, style: RichContentStyle) -> NSAttributedString {
        switch part {
        case .plain(let string):
            return PlainTextRenderer.render(string, style: style)
        case .markdown(let string):
            return MarkdownRenderer.render(markdown: string, style: style)
        case .html(let string):
            return HTMLRenderer.render(string, style: style)
        case .attributed(let attributed):
            // Built from Markdown? Then it carries block structure worth laying out.
            if attributed.runs.contains(where: { $0.presentationIntent != nil }) {
                return MarkdownRenderer.render(parsed: attributed, style: style)
            }
            let converted = (try? NSAttributedString(attributed, including: \.uiKit)) ?? NSAttributedString(attributed)
            let mutable = NSMutableAttributedString(attributedString: converted)
            TextKitHelpers.fillDefaults(mutable, style: style)
            return mutable
        case .nsAttributed(let attributed):
            let mutable = NSMutableAttributedString(attributedString: attributed)
            TextKitHelpers.fillDefaults(mutable, style: style)
            return mutable
        case .auto, .mixed:
            // Resolved by `flattened`; kept for exhaustiveness.
            return attributedString(for: part, style: style)
        }
    }
}
