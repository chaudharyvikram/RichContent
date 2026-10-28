import UIKit

/// Common sizing for block attachments: they span the text width of their
/// paragraph (container width minus indents).
public class EditorBlockAttachment: NSTextAttachment {

    /// Set by the editor so a loaded image can trigger relayout.
    weak var hostView: UITextView?

    func availableWidth(_ container: NSTextContainer?, characterIndex: Int, fallback: CGFloat) -> CGFloat {
        guard let container, container.size.width > 0 else { return fallback }
        var width = container.size.width - container.lineFragmentPadding * 2
        if let storage = container.layoutManager?.textStorage, characterIndex < storage.length,
           let p = storage.attribute(.paragraphStyle, at: characterIndex, effectiveRange: nil) as? NSParagraphStyle {
            width -= p.headIndent
            if p.tailIndent < 0 { width += p.tailIndent }
        }
        return max(width, 40)
    }

    /// Re-lays out the paragraph holding this attachment.
    func invalidate() {
        guard let hostView, let storage = hostView.layoutManager.textStorage else { return }
        let layoutManager = hostView.layoutManager
        var found: NSRange?
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, r, stop in
            if (value as AnyObject?) === self { found = r; stop.pointee = true }
        }
        guard let range = found else { return }
        layoutManager.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
        layoutManager.invalidateDisplay(forCharacterRange: range)
        hostView.setNeedsDisplay()
        hostView.invalidateIntrinsicContentSize()
        (hostView as? RichEditorTextView)?.contentLayoutDidChange()
    }
}

/// Horizontal rule (`<hr>`, `---`).
final class RichDividerAttachment: EditorBlockAttachment {

    override func attachmentBounds(for textContainer: NSTextContainer?, proposedLineFragment lineFrag: CGRect,
                                   glyphPosition position: CGPoint, characterIndex charIndex: Int) -> CGRect {
        CGRect(x: 0, y: -6, width: availableWidth(textContainer, characterIndex: charIndex, fallback: lineFrag.width), height: 22)
    }

    override func image(forBounds imageBounds: CGRect, textContainer: NSTextContainer?, characterIndex charIndex: Int) -> UIImage? {
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        return UIGraphicsImageRenderer(size: imageBounds.size, format: format).image { _ in
            UIColor.separator.setFill()
            UIRectFill(CGRect(x: 0, y: (imageBounds.height - 1) / 2, width: imageBounds.width, height: 1))
        }
    }
}

/// Image block. Loads `data:` URLs immediately and remote URLs on demand,
/// scales to the text width and keeps its source for export.
public final class RichImageAttachment: EditorBlockAttachment {

    public enum State { case loading, loaded, failed }
    /// Upload through `RichEditorController.imageUploader`.
    public enum UploadState { case uploading, failed }

    /// `https://…`, `data:image/…;base64,…` or a file URL.
    public internal(set) var source: String
    public var alt: String
    /// Natural size, when known (from the HTML or the loaded image).
    public private(set) var naturalSize: CGSize?
    public private(set) var state: State = .loading
    public private(set) var loadedImage: UIImage?
    /// Set while this image uploads and after its upload failed (drawn as a
    /// badge; a failed image offers Retry / Remove when tapped).
    public internal(set) var uploadState: UploadState?

    private static let cache = NSCache<NSString, UIImage>()
    private var loadTask: Task<Void, Never>?

    public init(source: String, alt: String = "", size: CGSize? = nil, image: UIImage? = nil) {
        self.source = source
        self.alt = alt
        self.naturalSize = size
        super.init(data: nil, ofType: nil)
        if let image {
            loadedImage = image
            naturalSize = naturalSize ?? image.size
            state = .loaded
            Self.cache.setObject(image, forKey: source as NSString)
        } else if let cached = Self.cache.object(forKey: source as NSString) {
            loadedImage = cached
            naturalSize = naturalSize ?? cached.size
            state = .loaded
        } else if let decoded = Self.decodeDataURL(source) {
            loadedImage = decoded
            naturalSize = naturalSize ?? decoded.size
            state = .loaded
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Starts loading a remote image (no-op when loaded or already loading).
    func loadIfNeeded(allowsRemote: Bool) {
        guard state == .loading, loadTask == nil else { return }
        guard allowsRemote, let url = URL(string: source),
              ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "")
        else {
            if !allowsRemote { return }
            state = .failed
            invalidate()
            return
        }
        loadTask = Task { @MainActor [weak self] in
            // Download and decode off the main thread.
            let image = await Task.detached { () -> UIImage? in
                if url.isFileURL { return UIImage(contentsOfFile: url.path)?.preparingForDisplay() }
                guard let data = try? await URLSession.shared.data(from: url).0 else { return nil }
                return UIImage(data: data)?.preparingForDisplay()
            }.value
            guard let self else { return }
            self.loadTask = nil
            if let image {
                Self.cache.setObject(image, forKey: self.source as NSString)
                self.loadedImage = image
                self.naturalSize = self.naturalSize ?? image.size
                self.state = .loaded
            } else {
                self.state = .failed
            }
            self.invalidate()
        }
    }

    static func decodeDataURL(_ source: String) -> UIImage? {
        guard source.hasPrefix("data:"), let comma = source.firstIndex(of: ",") else { return nil }
        let header = source[..<comma]
        let payload = String(source[source.index(after: comma)...])
        let data = header.contains(";base64")
            ? Data(base64Encoded: payload, options: .ignoreUnknownCharacters)
            : payload.removingPercentEncoding?.data(using: .utf8)
        return data.flatMap(UIImage.init(data:))
    }

    override public func attachmentBounds(for textContainer: NSTextContainer?, proposedLineFragment lineFrag: CGRect,
                                          glyphPosition position: CGPoint, characterIndex charIndex: Int) -> CGRect {
        let available = availableWidth(textContainer, characterIndex: charIndex, fallback: lineFrag.width)
        switch state {
        case .loaded:
            let natural = naturalSize ?? loadedImage?.size ?? CGSize(width: available, height: available * 0.6)
            let width = min(natural.width, available)
            let height = natural.width > 0 ? width * natural.height / natural.width : 160
            return CGRect(x: 0, y: 0, width: width, height: min(height, 1200))
        case .loading:
            if let natural = naturalSize, natural.width > 0 {
                let width = min(natural.width, available)
                return CGRect(x: 0, y: 0, width: width, height: width * natural.height / natural.width)
            }
            return CGRect(x: 0, y: 0, width: available, height: 160)
        case .failed:
            return CGRect(x: 0, y: 0, width: available, height: 56)
        }
    }

    override public func image(forBounds imageBounds: CGRect, textContainer: NSTextContainer?,
                               characterIndex charIndex: Int) -> UIImage? {
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        let size = imageBounds.size
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            let rect = CGRect(origin: .zero, size: size)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: 6)
            if state == .loaded, let image = loadedImage {
                path.addClip()
                image.draw(in: rect)
                if let uploadState { drawUploadBadge(uploadState, in: rect) }
                return
            }
            UIColor.tertiarySystemFill.setFill()
            path.fill()
            let symbol = state == .failed ? "photo.badge.exclamationmark" : "photo"
            let config = UIImage.SymbolConfiguration(pointSize: 20, weight: .regular)
            let icon = UIImage(systemName: symbol, withConfiguration: config)?
                .withTintColor(.secondaryLabel, renderingMode: .alwaysOriginal)
            let label = alt.isEmpty ? (state == .failed ? "Image couldn't be loaded" : "") : alt
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.preferredFont(forTextStyle: .footnote), .foregroundColor: UIColor.secondaryLabel
            ]
            let textSize = (label as NSString).size(withAttributes: attrs)
            if let icon {
                let iconY = label.isEmpty ? (size.height - icon.size.height) / 2 : (size.height - icon.size.height - textSize.height - 4) / 2
                icon.draw(at: CGPoint(x: (size.width - icon.size.width) / 2, y: max(iconY, 4)))
                if !label.isEmpty {
                    let textRect = CGRect(x: 12, y: max(iconY, 4) + icon.size.height + 4,
                                          width: size.width - 24, height: textSize.height)
                    let p = NSMutableParagraphStyle()
                    p.alignment = .center
                    p.lineBreakMode = .byTruncatingTail
                    var a = attrs
                    a[.paragraphStyle] = p
                    (label as NSString).draw(in: textRect, withAttributes: a)
                }
            }
        }
    }

    /// Dims the image and shows "Uploading…" or "Upload failed".
    private func drawUploadBadge(_ upload: UploadState, in rect: CGRect) {
        UIColor.black.withAlphaComponent(upload == .failed ? 0.45 : 0.25).setFill()
        UIRectFillUsingBlendMode(rect, .normal)
        let symbol = upload == .failed ? "exclamationmark.triangle.fill" : "arrow.up.circle.fill"
        let label = upload == .failed ? "Upload failed · Tap for options" : "Uploading…"
        let icon = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold))?
            .withTintColor(upload == .failed ? .systemYellow : .white, renderingMode: .alwaysOriginal)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize, weight: .semibold),
            .foregroundColor: UIColor.white
        ]
        let textSize = (label as NSString).size(withAttributes: attrs)
        let iconHeight = icon?.size.height ?? 0
        var y = rect.midY - (iconHeight + 6 + textSize.height) / 2
        if let icon {
            icon.draw(at: CGPoint(x: rect.midX - icon.size.width / 2, y: y))
            y += iconHeight + 6
        }
        let p = NSMutableParagraphStyle()
        p.alignment = .center
        p.lineBreakMode = .byTruncatingTail
        var a = attrs
        a[.paragraphStyle] = p
        (label as NSString).draw(in: CGRect(x: rect.minX + 8, y: y, width: rect.width - 16, height: textSize.height), withAttributes: a)
    }
}
