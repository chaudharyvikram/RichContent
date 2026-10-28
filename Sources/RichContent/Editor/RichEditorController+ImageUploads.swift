import UIKit

/// An `imageUploader` upload, keyed by the image's `data:` source. Image
/// blocks are rebuilt from their source when blocks move or undo runs, so the
/// state lives here and is mirrored onto every attachment showing the image.
struct ImageUpload {
    let source: String
    let image: UIImage
    var failed = false
}

extension RichEditorController {

    /// `true` when no image in the document is still uploading or has a
    /// failed upload. Check it before sending:
    ///
    /// ```swift
    /// Button("Send") { send(editor.replyHTML()) }
    ///     .disabled(editor.isEmpty || !editor.allImagesUploaded)
    /// ```
    public var allImagesUploaded: Bool { pendingImageUploads == 0 && failedImageUploads == 0 }

    /// Uploads `image` (shown with `source`) when an `imageUploader` is set.
    func startImageUpload(source: String, image: UIImage) {
        guard let uploader = imageUploader else { return }
        if let index = imageUploads.firstIndex(where: { $0.source == source }) {
            imageUploads[index].failed = false
        } else {
            imageUploads.append(ImageUpload(source: source, image: image))
        }
        updateImageUploadStates()
        Task { @MainActor [weak self] in
            do {
                let url = try await uploader(image)
                self?.imageUploadFinished(source: source, url: url)
            } catch {
                self?.imageUploadFailed(source: source, error: error)
            }
        }
    }

    /// Retries every failed upload in the document.
    public func retryFailedImageUploads() {
        for upload in imageUploads where upload.failed && contains(imageSource: upload.source) {
            startImageUpload(source: upload.source, image: upload.image)
        }
    }

    /// Removes every image whose upload failed (one undo step each).
    public func removeFailedImages() {
        for upload in imageUploads where upload.failed { removeImage(source: upload.source) }
    }

    func retryImageUpload(source: String) {
        guard let upload = imageUploads.first(where: { $0.source == source }) else { return }
        startImageUpload(source: source, image: upload.image)
    }

    /// Deletes the image block(s) showing `source`.
    func removeImage(source: String) {
        var previous: Int?
        while let tv = textView, let location = location(ofImageSource: source), location != previous {
            previous = location
            tv.selectedRange = NSRange(location: location, length: 0)
            deleteBlock()
        }
        imageUploads.removeAll { $0.source == source }
        updateImageUploadStates()
    }

    private func imageUploadFinished(source: String, url: URL) {
        imageUploads.removeAll { $0.source == source }
        if let s = storage {
            s.enumerateAttribute(.attachment, in: NSRange(location: 0, length: s.length)) { value, _, _ in
                if let image = value as? RichImageAttachment, image.source == source { image.source = url.absoluteString }
            }
        }
        updateImageUploadStates()
        onChange?(self)
    }

    private func imageUploadFailed(source: String, error: Error) {
        guard let index = imageUploads.firstIndex(where: { $0.source == source }) else { return }
        imageUploads[index].failed = true
        updateImageUploadStates()
        // Deleted while uploading: nothing to ask about.
        guard contains(imageSource: source) else { return }
        onImageUploadFailure?(error)
        if configuration.showsImageUploadFailureAlert { textView?.presentImageUploadFailure(source: nil) }
    }

    /// Mirrors upload states onto the document's image attachments and
    /// refreshes `pendingImageUploads` / `failedImageUploads`.
    func updateImageUploadStates() {
        var pending = Set<String>(), failed = Set<String>()
        if !imageUploads.isEmpty || pendingImageUploads > 0 || failedImageUploads > 0, let s = storage {
            s.enumerateAttribute(.attachment, in: NSRange(location: 0, length: s.length)) { value, _, _ in
                guard let image = value as? RichImageAttachment else { return }
                let upload = imageUploads.first { $0.source == image.source }
                let state: RichImageAttachment.UploadState? = upload.map { $0.failed ? .failed : .uploading }
                if let upload { if upload.failed { failed.insert(upload.source) } else { pending.insert(upload.source) } }
                if image.uploadState != state {
                    image.uploadState = state
                    image.invalidate()
                }
            }
        }
        if pendingImageUploads != pending.count { pendingImageUploads = pending.count }
        if failedImageUploads != failed.count { failedImageUploads = failed.count }
    }

    func contains(imageSource source: String) -> Bool { location(ofImageSource: source) != nil }

    private func location(ofImageSource source: String) -> Int? {
        guard let s = storage else { return nil }
        var found: Int?
        s.enumerateAttribute(.attachment, in: NSRange(location: 0, length: s.length)) { value, range, stop in
            if let image = value as? RichImageAttachment, image.source == source {
                found = range.location
                stop.pointee = true
            }
        }
        return found
    }
}

// MARK: - Retry / Remove prompt

extension RichEditorTextView {

    /// Asks what to do about failed uploads: for one image (`source`) when
    /// its badge is tapped, else for every failed image.
    func presentImageUploadFailure(source: String?) {
        guard let controller = editorController, let presenter = presentingController,
              !(presenter is UIAlertController) else { return }
        let count = source == nil ? controller.failedImageUploads : 1
        guard count > 0 else { return }
        let alert = UIAlertController(
            title: count == 1 ? "Image Couldn't Be Uploaded" : "\(count) Images Couldn't Be Uploaded",
            message: "Try again, or remove \(count == 1 ? "it" : "them") from the message.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: count == 1 ? "Remove Image" : "Remove Images", style: .destructive) { _ in
            if let source { controller.removeImage(source: source) } else { controller.removeFailedImages() }
        })
        alert.addAction(UIAlertAction(title: "Retry", style: .default) { _ in
            if let source { controller.retryImageUpload(source: source) } else { controller.retryFailedImageUploads() }
        })
        alert.addAction(UIAlertAction(title: "Not Now", style: .cancel))
        presenter.present(alert, animated: true)
    }

    /// The failed-upload image under `point`, if any.
    func failedUploadImage(at point: CGPoint) -> RichImageAttachment? {
        guard textStorage.length > 0 else { return nil }
        let p = CGPoint(x: point.x - textContainerInset.left, y: point.y - textContainerInset.top)
        let glyph = layoutManager.glyphIndex(for: p, in: textContainer)
        let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
        guard rect.contains(p) else { return nil }
        let index = layoutManager.characterIndexForGlyph(at: glyph)
        guard index < textStorage.length,
              let image = textStorage.attribute(.attachment, at: index, effectiveRange: nil) as? RichImageAttachment,
              image.uploadState == .failed else { return nil }
        return image
    }
}
