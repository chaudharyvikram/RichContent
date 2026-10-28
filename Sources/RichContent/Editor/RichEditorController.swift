import UIKit
import Combine

/// Editor options. `allowedBlocks` limits what the slash menu, Markdown
/// shortcuts, "Turn into" and the toolbars offer (e.g. no toggles in email).
public struct RichEditorConfiguration {
    public var allowedBlocks: Set<RichBlockType> = Set(RichBlockType.allCases)
    /// ⋮⋮ handle beside the current block: tap for block actions, drag to move.
    public var showsBlockHandles = true
    /// Floating format bar while text is selected.
    public var showsSelectionToolbar = true
    /// "/" opens the command menu.
    public var slashCommands = true
    /// "- ", "1. ", "[] ", "# ", "> ", "**bold**" … convert while typing.
    public var markdownShortcuts = true
    /// Load `http(s)` images in the document.
    public var loadsRemoteImages = true
    /// Shown in an empty text block under the caret.
    public var commandHint = "Type '/' for commands"
    /// Pasted / picked images are scaled down to this many pixels on the long side.
    public var maxImagePixelSize: CGFloat = 2048
    /// When an `imageUploader` upload fails, show an alert with Retry and
    /// Remove Image. The failed image also keeps a badge; tapping it offers
    /// the same choices.
    public var showsImageUploadFailureAlert = true
    /// Buttons in the format bar, in order (all by default). Tools the rest
    /// of the configuration rules out (e.g. Image without `.image` in
    /// `allowedBlocks`) are left out.
    public var toolbarTools: [RichEditorTool] = .all

    public init() {}

    public static var standard: RichEditorConfiguration { RichEditorConfiguration() }

    /// Email compose: no toggles or callouts, which most mail clients can't show.
    public static var email: RichEditorConfiguration {
        var c = RichEditorConfiguration()
        c.allowedBlocks.subtract([.toggle, .callout])
        c.commandHint = ""
        return c
    }
}

/// Drives a `RichContentEditor` / `RichEditorTextView`: formatting and block
/// commands, current-format state for toolbars, loading content and export.
///
/// ```swift
/// @StateObject var editor = RichEditorController()
/// RichContentEditor(controller: editor, placeholder: "Write a reply…")
///     .richEditorToolbar(editor)
/// // later
/// send(html: editor.html)
/// ```
@MainActor
public final class RichEditorController: NSObject, ObservableObject {

    // MARK: State (drives toolbars)

    @Published public private(set) var activeFormats: Set<RichInlineFormat> = []
    @Published public private(set) var blockType: RichBlockType = .paragraph
    /// Nesting level (1 = top) of the block under the caret.
    @Published public private(set) var listLevel: Int = 1
    @Published public private(set) var isChecked = false
    @Published public private(set) var textColor: RichColor = .default
    @Published public private(set) var highlight: RichColor = .default
    @Published public private(set) var isFocused = false
    @Published public private(set) var isEmpty = true
    @Published public private(set) var hasSelection = false
    @Published public private(set) var canUndo = false
    @Published public private(set) var canRedo = false
    @Published public private(set) var canIndent = false
    @Published public private(set) var canOutdent = false
    /// Images in the document still uploading with `imageUploader`.
    @Published public internal(set) var pendingImageUploads = 0
    /// Images in the document whose upload failed (Retry / Remove pending).
    @Published public internal(set) var failedImageUploads = 0

    public var configuration: RichEditorConfiguration {
        didSet { textView?.configurationDidChange() }
    }

    /// Called after every content change (typing, formatting, paste, undo).
    public var onChange: ((RichEditorController) -> Void)?

    /// Uploads a picked / pasted image and returns its URL. Without it,
    /// images are embedded as `data:` URLs. While it runs the image shows
    /// "Uploading…"; check `allImagesUploaded` before sending.
    public var imageUploader: ((UIImage) async throws -> URL)?

    /// Called when an image upload fails (in addition to the alert, see
    /// `RichEditorConfiguration.showsImageUploadFailureAlert`).
    public var onImageUploadFailure: ((Error) -> Void)?

    /// Uploads started in this editor, by the image's `data:` source.
    var imageUploads: [ImageUpload] = []

    public private(set) var style: RichContentStyle
    private(set) weak var textView: RichEditorTextView?
    private var pendingDocument: NSAttributedString?
    /// Block of the empty line after a trailing newline (it has no characters).
    var trailingInfo = BlockInfo()
    /// Range touched by the change in flight, for normalising afterwards.
    var pendingEditRange: NSRange?
    /// Text replacing a range (suggestion, autocorrect, dictation, typing over
    /// a selection) keeps the replaced text's formatting: where it lands and
    /// the inline formats of the first replaced character.
    var pendingReplacementStyle: (range: NSRange, inline: InlineInfo)?
    var slash: SlashState?
    var slashPending: Int?
    /// Link taps (from the edit menu's "Open Link" and the quoted original).
    /// `nil` opens with the system.
    public var onOpenURL: ((URL) -> Void)?

    /// The message being replied to, shown read-only below the text like the
    /// quoted original in Mail and Gmail: it scrolls with the reply, can't be
    /// edited, and `replyHTML()` sends it. `nil` shows nothing.
    @Published public var quotedOriginal: QuotedOriginal? {
        didSet { if quotedOriginal != oldValue { textView?.quotedOriginalDidChange() } }
    }

    public init(style: RichContentStyle = .standard, content: RichContent? = nil,
                configuration: RichEditorConfiguration = .standard) {
        self.style = style
        self.configuration = configuration
        super.init()
        if let content { load(content) }
    }

    // MARK: - Content in / out

    /// The document in the editor's model (attributes describe blocks).
    public var attributedText: NSAttributedString {
        if let textView { return NSAttributedString(attributedString: textView.textStorage) }
        return pendingDocument ?? NSAttributedString()
    }

    /// Lossless, email-safe HTML. Loading it back restores every block.
    public var html: String { RichEditorSerializer.html(from: attributedText) }
    /// CommonMark / GitHub Markdown (colors and toggle state are dropped).
    public var markdown: String { RichEditorSerializer.markdown(from: attributedText) }
    /// Plain text with "• ", "1. ", "☐ ", "> " prefixes.
    public var plainText: String { RichEditorSerializer.plainText(from: attributedText) }

    /// Reply HTML: this document, an attribution line and the quoted original.
    public func replyHTML(quoting original: RichContent, attribution: String) -> String {
        RichEditorSerializer.replyHTML(attributedText, quoting: original, attribution: attribution, style: style)
    }

    /// Reply HTML with `quotedOriginal` (just `html` when there is none).
    public func replyHTML() -> String {
        guard let quoted = quotedOriginal else { return html }
        return replyHTML(quoting: quoted.content, attribution: quoted.attribution)
    }

    /// Loads any content the viewer understands (HTML, Markdown, plain, attributed, mixed).
    public func load(_ content: RichContent) {
        setBlocks(EditorImporter.blocks(from: content))
    }

    func setBlocks(_ blocks: [EditorBlock]) {
        setDocument(EditorDocument.attributedString(from: blocks, style: style))
        if let trailing = EditorDocument.trailingInfo(of: blocks, style: style) {
            trailingInfo = trailing
            syncTypingAttributes()
            contentDidChange()
        }
    }

    /// Replaces the document. Clears undo history.
    public func setDocument(_ document: NSAttributedString) {
        trailingInfo = BlockInfo()
        guard let tv = textView else { pendingDocument = document; return }
        tv.textStorage.setAttributedString(restyled(document))
        prepareAttachments(in: NSRange(location: 0, length: tv.textStorage.length))
        tv.undoManager?.removeAllActions()
        tv.selectedRange = NSRange(location: 0, length: 0)
        syncTypingAttributes()
        contentDidChange()
    }

    public func clear() { setDocument(NSAttributedString()) }
    public func focus() { textView?.becomeFirstResponder() }
    public func resignFocus() { textView?.resignFirstResponder() }

    public var selectedRange: NSRange { textView?.selectedRange ?? NSRange(location: 0, length: 0) }

    public var selectedText: String {
        guard let tv = textView, tv.selectedRange.length > 0 else { return "" }
        return (tv.textStorage.string as NSString).substring(with: tv.selectedRange)
    }

    /// Link under the caret / at the start of the selection.
    public var selectedLink: URL? {
        guard let tv = textView, tv.textStorage.length > 0 else { return nil }
        let selection = tv.selectedRange
        let index = selection.length == 0 ? selection.location - 1 : selection.location
        guard index >= 0 else { return nil }
        return InlineInfo(tv.textStorage.attributes(at: min(index, tv.textStorage.length - 1), effectiveRange: nil)).link
    }

    // MARK: - Attaching

    func attach(_ tv: RichEditorTextView, style: RichContentStyle) {
        // A new text view replacing a live one (SwiftUI switching layouts):
        // carry the document over.
        if let old = textView, old !== tv, pendingDocument == nil {
            pendingDocument = NSAttributedString(attributedString: old.textStorage)
            old.delegate = nil
            old.editorController = nil
        }
        self.style = style
        textView = tv
        tv.delegate = self
        tv.editorController = self
        tv.apply(style)
        tv.quotedOriginalDidChange()
        if let document = pendingDocument {
            pendingDocument = nil
            tv.textStorage.setAttributedString(restyled(document))
            prepareAttachments(in: NSRange(location: 0, length: tv.textStorage.length))
        }
        syncTypingAttributes()
        contentDidChange()
    }

    /// The text view is going away (SwiftUI dismantled it): keep the document
    /// so `html` still works and a new text view picks it up.
    func detach(_ tv: RichEditorTextView) {
        guard textView === tv else { return }
        pendingDocument = NSAttributedString(attributedString: tv.textStorage)
        tv.delegate = nil
        tv.editorController = nil
        textView = nil
        isFocused = false
    }

    func updateStyle(_ newStyle: RichContentStyle) {
        guard newStyle != style else { return }
        style = newStyle
        guard let tv = textView else { return }
        tv.apply(newStyle)
        tv.quotedOriginalDidChange()
        let selection = tv.selectedRange
        EditorStyling.normalize(tv.textStorage, in: NSRange(location: 0, length: tv.textStorage.length), style: newStyle)
        tv.selectedRange = selection
        syncTypingAttributes()
        contentDidChange()
    }

    private func restyled(_ document: NSAttributedString) -> NSAttributedString {
        let m = NSMutableAttributedString(attributedString: document)
        EditorStyling.normalize(m, in: NSRange(location: 0, length: m.length), style: style)
        return m
    }

    // MARK: - Paragraph helpers

    var storage: NSTextStorage? { textView?.textStorage }

    /// Paragraph at `location`. The empty line after a trailing newline (or an
    /// empty document) is `isTrailing`, with an empty range at the end.
    func paragraph(at location: Int) -> (range: NSRange, isTrailing: Bool) {
        guard let s = storage else { return (NSRange(location: 0, length: 0), true) }
        let ns = s.string as NSString
        if ns.length == 0 { return (NSRange(location: 0, length: 0), true) }
        if location >= ns.length, ns.character(at: ns.length - 1) == 10 {
            return (NSRange(location: ns.length, length: 0), true)
        }
        return (ns.paragraphRange(for: NSRange(location: min(location, ns.length), length: 0)), false)
    }

    func info(ofParagraphAt location: Int) -> BlockInfo {
        let p = paragraph(at: location)
        guard let s = storage, !p.isTrailing else { return trailingInfo }
        return EditorStyling.info(ofParagraph: p.range, in: s)
    }

    /// Length of a paragraph without its terminator.
    func contentLength(_ p: NSRange) -> Int {
        guard let s = storage, p.length > 0 else { return 0 }
        let ns = s.string as NSString
        return ns.character(at: NSMaxRange(p) - 1) == 10 ? p.length - 1 : p.length
    }

    var currentParagraph: (range: NSRange, isTrailing: Bool) { paragraph(at: selectedRange.location) }

    /// Paragraphs touched by the selection (at least the caret's).
    var selectedParagraphs: [NSRange] {
        guard let s = storage, s.length > 0 else { return [] }
        let sel = selectedRange
        let ns = s.string as NSString
        if paragraph(at: sel.location).isTrailing { return [] }
        let covering = ns.paragraphRange(for: NSRange(location: min(sel.location, ns.length - 1),
                                                       length: max(0, min(sel.length, ns.length - min(sel.location, ns.length - 1)))))
        return EditorStyling.paragraphRanges(in: s, within: covering)
    }

    // MARK: - Editing primitives (undoable)

    /// Replaces `range` and registers the reverse change as one undo step.
    func replace(_ range: NSRange, with new: NSAttributedString, actionName: String, selection: NSRange? = nil) {
        guard let tv = textView else { return }
        let s = tv.textStorage
        let old = s.attributedSubstring(from: range)
        let oldSelection = tv.selectedRange
        // The keyboard keeps its own copy of the text around the caret
        // (autocorrect, capitalisation); tell it the text changed under it.
        tv.inputDelegate?.selectionWillChange(tv)
        tv.inputDelegate?.textWillChange(tv)
        s.beginEditing()
        s.replaceCharacters(in: range, with: new)
        s.endEditing()
        tv.inputDelegate?.textDidChange(tv)
        let newRange = NSRange(location: range.location, length: new.length)
        prepareAttachments(in: newRange)
        if let undoManager = tv.undoManager {
            undoManager.beginUndoGrouping()
            undoManager.registerUndo(withTarget: self) { target in
                MainActor.assumeIsolated {
                    target.replace(newRange, with: old, actionName: actionName, selection: oldSelection)
                }
            }
            undoManager.setActionName(actionName)
            undoManager.endUndoGrouping()
        }
        if let selection {
            tv.selectedRange = NSRange(location: min(selection.location, s.length),
                                       length: min(selection.length, max(0, s.length - min(selection.location, s.length))))
        }
        tv.inputDelegate?.selectionDidChange(tv)
        if tv.isFirstResponder { tv.scrollRangeToVisible(tv.selectedRange) }
        syncTypingAttributes()
        contentDidChange()
    }

    /// Edits a copy of `range` and writes it back as one undo step.
    func edit(_ range: NSRange, actionName: String, _ body: (NSMutableAttributedString) -> Void) {
        guard let tv = textView else { return }
        let copy = NSMutableAttributedString(attributedString: tv.textStorage.attributedSubstring(from: range))
        body(copy)
        let selection = tv.selectedRange
        replace(range, with: copy, actionName: actionName, selection: copy.length == range.length ? selection : nil)
    }

    /// Replaces whole paragraphs (index range into `paragraphList`) with
    /// `blocks`, then puts the caret in block `caretBlock` at `caretOffset`.
    func replaceParagraphs(_ indices: Range<Int>, with blocks: [EditorBlock], actionName: String,
                           caretBlock: Int? = nil, caretOffset: Int = 0, selectWhole: Bool = false) {
        guard let s = storage else { return }
        let list = paragraphList
        let start = indices.lowerBound < list.count ? list[indices.lowerBound].location : s.length
        let end = indices.upperBound > 0 && indices.upperBound <= list.count ? NSMaxRange(list[indices.upperBound - 1]) : start
        let range = NSRange(location: start, length: max(end - start, 0))
        let endedWithBreak = range.length > 0 && (s.string as NSString).character(at: NSMaxRange(range) - 1) == 10
        let atDocumentEnd = NSMaxRange(range) >= s.length

        let piece = EditorDocument.attributedString(from: blocks, style: style)
        if !blocks.isEmpty, endedWithBreak || (!atDocumentEnd && range.length == 0) {
            // The line break belongs to the last block (it may be empty).
            var info = blocks.last!.info
            if let hidden = blocks.last!.hiddenChildren, info.type == .toggle {
                info.collapsed = RichToggleChildren(content: EditorDocument.attributedString(from: hidden, style: style), level: info.level)
            }
            piece.append(NSAttributedString(string: "\n", attributes: EditorStyling.attributes(block: info, inline: InlineInfo(), style: style)))
        } else if blocks.isEmpty, atDocumentEnd, range.location > 0, !endedWithBreak {
            // Removing the last blocks: drop the line break before them too.
            replace(NSRange(location: range.location - 1, length: range.length + 1), with: NSAttributedString(),
                    actionName: actionName, selection: NSRange(location: range.location - 1, length: 0))
            return
        }

        var caret = NSRange(location: range.location, length: 0)
        if let caretBlock {
            let ns = piece.string as NSString
            var location = 0
            var index = 0
            while index < caretBlock, location < ns.length {
                location = NSMaxRange(ns.paragraphRange(for: NSRange(location: location, length: 0)))
                index += 1
            }
            let blockRange = ns.length > 0 && location < ns.length
                ? ns.paragraphRange(for: NSRange(location: location, length: 0)) : NSRange(location: location, length: 0)
            let content = blockRange.length > 0 && ns.character(at: NSMaxRange(blockRange) - 1) == 10 ? blockRange.length - 1 : blockRange.length
            caret = selectWhole
                ? NSRange(location: range.location + location, length: content)
                : NSRange(location: range.location + location + min(caretOffset, content), length: 0)
        }
        // An empty last block has no characters: the trailing line carries it.
        if atDocumentEnd, !endedWithBreak, let trailing = EditorDocument.trailingInfo(of: blocks, style: style) {
            trailingInfo = trailing
        }
        // Appending after a last paragraph that has no line break yet.
        if range.length == 0, atDocumentEnd, s.length > 0, !blocks.isEmpty,
           (s.string as NSString).character(at: s.length - 1) != 10 {
            piece.insert(NSAttributedString(string: "\n", attributes: s.attributes(at: s.length - 1, effectiveRange: nil)), at: 0)
            caret.location += 1
        }
        replace(range, with: piece, actionName: actionName, selection: caret)
    }

    /// All paragraphs (the empty trailing line is not one).
    var paragraphList: [NSRange] {
        guard let s = storage else { return [] }
        return EditorStyling.paragraphRanges(in: s)
    }

    func paragraphIndex(at location: Int) -> Int? {
        paragraphList.firstIndex { NSLocationInRange(location, $0) || (location == NSMaxRange($0) && location == storage?.length) }
    }

    /// Index range of the block at `index` plus its nested children.
    func blockSpan(at index: Int) -> Range<Int> {
        let blocks = documentBlocks
        guard index < blocks.count else { return index..<index }
        var end = index + 1
        while end < blocks.count, blocks[end].info.level > blocks[index].info.level { end += 1 }
        return index..<end
    }

    var documentBlocks: [EditorBlock] {
        guard let s = storage else { return [] }
        return EditorDocument.blocks(from: s)
    }

    // MARK: - Undo

    public func undo() {
        slash = nil
        textView?.undoManager?.undo()
        afterUndoRedo()
    }

    public func redo() {
        slash = nil
        textView?.undoManager?.redo()
        afterUndoRedo()
    }

    private func afterUndoRedo() {
        guard let s = storage else { return }
        EditorStyling.normalize(s, in: NSRange(location: 0, length: s.length), style: style)
        syncTypingAttributes()
        contentDidChange()
    }

    // MARK: - State

    func prepareAttachments(in range: NSRange) {
        guard let tv = textView else { return }
        let s = tv.textStorage
        let clamped = NSIntersectionRange(range, NSRange(location: 0, length: s.length))
        guard clamped.length > 0 else { return }
        s.enumerateAttribute(.attachment, in: clamped) { value, _, _ in
            guard let attachment = value as? EditorBlockAttachment else { return }
            attachment.hostView = tv
            (attachment as? RichImageAttachment)?.loadIfNeeded(allowsRemote: configuration.loadsRemoteImages)
        }
    }

    func contentDidChange() {
        guard let tv = textView else { return }
        isEmpty = tv.textStorage.length == 0
        tv.updatePlaceholder()
        tv.redrawDecorations()
        refreshState()
        updateImageUploadStates()
        tv.updateOverlays()
        tv.reportContentHeight()
        tv.revealCaretInEnclosingScrollView()
        onChange?(self)
    }

    /// Typing attributes follow the paragraph under the caret (UIKit would take
    /// them from the character before it, i.e. the previous paragraph).
    func syncTypingAttributes() {
        guard let tv = textView, tv.markedTextRange == nil else { return }
        let sel = tv.selectedRange
        let p = paragraph(at: sel.location)
        let info = p.isTrailing ? trailingInfo : EditorStyling.info(ofParagraph: p.range, in: tv.textStorage)
        var inline = InlineInfo()
        if !p.isTrailing, p.range.length > 0 {
            let s = tv.textStorage
            let contentEnd = p.range.location + contentLength(p.range)
            if sel.location > p.range.location {
                inline = InlineInfo(s.attributes(at: sel.location - 1, effectiveRange: nil))
            } else if contentEnd > p.range.location {
                inline = InlineInfo(s.attributes(at: p.range.location, effectiveRange: nil))
            }
        }
        inline.link = nil
        tv.typingAttributes = EditorStyling.attributes(block: info, inline: inline, style: style)
    }

    func refreshState() {
        guard let tv = textView else { return }
        let s = tv.textStorage
        let selection = tv.selectedRange
        hasSelection = selection.length > 0

        if selection.length == 0 {
            let inline = InlineInfo(tv.typingAttributes)
            activeFormats = Self.formats(inline)
            textColor = inline.color ?? .default
            highlight = inline.highlight ?? .default
        } else {
            var common: Set<RichInlineFormat>?
            var colors = Set<RichColor>()
            var highlights = Set<RichColor>()
            s.enumerateAttributes(in: NSIntersectionRange(selection, NSRange(location: 0, length: s.length))) { attrs, _, _ in
                guard attrs[.attachment] == nil else { return }
                let inline = InlineInfo(attrs)
                let formats = Self.formats(inline)
                common = common.map { $0.intersection(formats) } ?? formats
                colors.insert(inline.color ?? .default)
                highlights.insert(inline.highlight ?? .default)
            }
            activeFormats = common ?? []
            textColor = colors.count == 1 ? colors.first! : .default
            highlight = highlights.count == 1 ? highlights.first! : .default
        }

        let info = info(ofParagraphAt: selection.location)
        blockType = info.type
        listLevel = info.level
        isChecked = info.checked
        let p = currentParagraph
        canOutdent = info.level > 1
        if p.isTrailing || p.range.location == 0 {
            canIndent = p.isTrailing && s.length > 0 && maxLevel(before: s.length) >= info.level
        } else {
            canIndent = maxLevel(before: p.range.location) >= info.level && info.level < EditorStyling.maxLevel
        }
        canUndo = tv.undoManager?.canUndo ?? false
        canRedo = tv.undoManager?.canRedo ?? false
    }

    /// Level of the paragraph just before `location` (a block may be at most
    /// one deeper than the block above it).
    func maxLevel(before location: Int) -> Int {
        guard let s = storage, location > 0 else { return 0 }
        let previous = (s.string as NSString).paragraphRange(for: NSRange(location: location - 1, length: 0))
        return EditorStyling.info(in: s, at: previous.location).level
    }

    static func formats(_ inline: InlineInfo) -> Set<RichInlineFormat> {
        var formats: Set<RichInlineFormat> = []
        if inline.bold { formats.insert(.bold) }
        if inline.italic { formats.insert(.italic) }
        if inline.underline { formats.insert(.underline) }
        if inline.strike { formats.insert(.strikethrough) }
        if inline.code { formats.insert(.code) }
        if inline.link != nil { formats.insert(.link) }
        return formats
    }

    func setFocused(_ focused: Bool) { isFocused = focused }
}

// MARK: - UITextViewDelegate

extension RichEditorController: UITextViewDelegate {

    public func textViewDidChange(_ textView: UITextView) {
        guard let s = storage else { return }
        if textView.markedTextRange == nil {
            let range = pendingEditRange ?? NSRange(location: 0, length: s.length)
            let selection = textView.selectedRange
            if let replacement = pendingReplacementStyle, replacement.range.length > 0,
               NSMaxRange(replacement.range) <= s.length {
                // UIKit inserts suggestions with the attributes it picked on the
                // selection change (from the character before the word).
                s.enumerateAttributes(in: replacement.range) { attrs, r, _ in
                    guard attrs[.attachment] == nil, InlineInfo(attrs) != replacement.inline else { return }
                    s.setAttributes(EditorStyling.attributes(block: BlockInfo(attrs), inline: replacement.inline, style: style),
                                    range: r)
                }
            }
            EditorStyling.normalize(s, in: range, style: style)
            prepareAttachments(in: range)
            if textView.selectedRange != selection { textView.selectedRange = selection }
        }
        pendingEditRange = nil
        pendingReplacementStyle = nil
        updateSlashState()
        contentDidChange()
    }

    public func textViewDidChangeSelection(_ textView: UITextView) {
        syncTypingAttributes()
        if let slash, textView.selectedRange.location <= slash.location || textView.selectedRange.length > 0 {
            self.slash = nil
        }
        refreshState()
        self.textView?.redrawDecorations()
        self.textView?.updateOverlays()
    }

    public func textViewDidBeginEditing(_ textView: UITextView) {
        isFocused = true
        self.textView?.updateOverlays()
    }

    public func textViewDidEndEditing(_ textView: UITextView) {
        isFocused = false
        slash = nil
        self.textView?.redrawDecorations()
        self.textView?.updateOverlays()
    }

    public func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        let allowed = shouldChange(range, text)
        if allowed {
            let length = (text as NSString).length
            pendingEditRange = NSRange(location: max(range.location - 1, 0), length: length + 2)
        }
        return allowed
    }
}
