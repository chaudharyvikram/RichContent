import SwiftUI
import UIKit
import PhotosUI

/// Editable text view for `RichEditorController`, usable directly from UIKit.
/// Hosts the "/" menu, the selection toolbar and the block handle, handles
/// taps on checkboxes / toggle arrows / callout icons, keyboard shortcuts and
/// rich copy & paste.
///
/// ```swift
/// let editor = RichEditorController(style: .email)
/// let textView = RichEditorTextView()
/// editor.attach(to: textView)
/// ```
public final class RichEditorTextView: UITextView {

    weak var editorController: RichEditorController?
    /// Strong reference: keeps the TextKit 1 stack alive (see `TextKitStack`).
    private let richTextStorage: NSTextStorage
    let editorLayoutManager: EditorLayoutManager
    private let placeholderLabel = UILabel()

    let slashMenu = EditorSlashMenuView()
    let selectionToolbar = EditorSelectionToolbar()
    let blockHandle = EditorBlockHandle()
    private let dropIndicator = UIView()
    private var markerTap: UITapGestureRecognizer!
    private var drag: (source: Int, target: Int)?
    private var autoScrollLink: CADisplayLink?
    private var autoScrollSpeed: CGFloat = 0

    /// The read-only quoted original below the text (see `EditorQuotedOriginal.swift`).
    var quotedHost: UIHostingController<EditorQuotedOriginalView>?
    var quotedHeight: CGFloat = 0
    /// The part of `contentInset.bottom` this view added for the quoted original.
    var appliedQuotedInset: CGFloat = 0

    public var placeholder: String {
        get { placeholderLabel.text ?? "" }
        set { placeholderLabel.text = newValue; updatePlaceholder() }
    }

    /// Minimum height when used without scrolling (auto-growing).
    public var minimumHeight: CGFloat = 120

    /// Width the block handle needs left of a block's text.
    private let handleWidth: CGFloat = 28

    /// Left and right margin: `editorHorizontalPadding` when set, else the
    /// style's padding, widened (on both sides, so blocks stay centred) when
    /// the block handle needs room.
    private func sideInset(_ style: RichContentStyle) -> CGFloat {
        if let padding = style.editorHorizontalPadding { return max(padding, 0) }
        let showsHandles = editorController?.configuration.showsBlockHandles ?? true
        return showsHandles ? max(style.horizontalPadding, handleWidth + 2) : style.horizontalPadding
    }

    public init() {
        let (storage, layoutManager, container) = TextKitStack.make(EditorLayoutManager())
        richTextStorage = storage
        editorLayoutManager = layoutManager
        super.init(frame: .zero, textContainer: container)

        isEditable = true
        isSelectable = true
        isScrollEnabled = true
        alwaysBounceVertical = true
        keyboardDismissMode = .interactive
        backgroundColor = .clear
        allowsEditingTextAttributes = false
        dataDetectorTypes = []
        smartInsertDeleteType = .yes

        placeholderLabel.numberOfLines = 0
        placeholderLabel.textColor = .placeholderText
        placeholderLabel.isAccessibilityElement = false
        addSubview(placeholderLabel)

        dropIndicator.backgroundColor = .tintColor
        dropIndicator.layer.cornerRadius = 1.5
        dropIndicator.isHidden = true
        for overlay in [blockHandle, dropIndicator, selectionToolbar, slashMenu] as [UIView] {
            overlay.isHidden = true
            addSubview(overlay)
        }
        blockHandle.textView = self
        selectionToolbar.textView = self
        slashMenu.textView = self

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleDrag(_:)))
        blockHandle.addGestureRecognizer(pan)

        markerTap = UITapGestureRecognizer(target: self, action: #selector(handleMarkerTap(_:)))
        addGestureRecognizer(markerTap)

        layoutManager.focus = { [weak self] in self?.focusInfo() }
        layoutManager.trailingLineInfo = { [weak self] in self?.editorController?.trailingInfo ?? BlockInfo() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Style

    func apply(_ style: RichContentStyle) {
        let side = sideInset(style)
        textContainerInset = UIEdgeInsets(top: max(style.verticalPadding, 8), left: side,
                                          bottom: max(style.verticalPadding, 8) + 8, right: side)
        editorLayoutManager.style = style
        editorLayoutManager.accentColor = style.linkColor
        editorLayoutManager.commandHint = editorController?.configuration.commandHint ?? ""
        linkTextAttributes = [.foregroundColor: style.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue]
        tintColor = style.linkColor
        placeholderLabel.font = style.font
        setNeedsLayout()
        redrawDecorations()
    }

    func configurationDidChange() {
        guard let controller = editorController else { return }
        apply(controller.style)
        updateOverlays()
    }

    func updatePlaceholder() {
        placeholderLabel.isHidden = textStorage.length > 0 || editorController?.trailingInfo.type != .paragraph
    }

    func redrawDecorations() {
        editorLayoutManager.invalidateDisplay(forCharacterRange: NSRange(location: 0, length: textStorage.length))
        setNeedsDisplay()
    }

    /// An image finished loading: sizes changed.
    func contentLayoutDidChange() {
        invalidateIntrinsicContentSize()
        updateOverlays()
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        let inset = textContainerInset
        let width = bounds.width - inset.left - inset.right
        let size = placeholderLabel.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        placeholderLabel.frame = CGRect(x: inset.left, y: inset.top, width: width, height: size.height)
        layoutQuotedOriginal()
        updateOverlays()
    }

    private func focusInfo() -> EditorLayoutManager.Focus? {
        guard isFirstResponder, let controller = editorController, selectedRange.length == 0 else { return nil }
        let p = controller.paragraph(at: selectedRange.location)
        let info = controller.info(ofParagraphAt: selectedRange.location)
        let showsHint = textStorage.length > 0 || info.type != .paragraph
        return EditorLayoutManager.Focus(paragraphLocation: p.range.location, isEmptyLastLine: p.isTrailing,
                                         info: info, showsHint: showsHint && controller.slash == nil)
    }

    // MARK: Geometry

    /// Rect of a paragraph in view (content) coordinates.
    func rect(ofParagraphAt location: Int) -> CGRect? {
        editorLayoutManager.blockRect(ofParagraphAt: location)?
            .offsetBy(dx: textContainerInset.left, dy: textContainerInset.top)
    }

    var visibleRect: CGRect { CGRect(origin: contentOffset, size: bounds.size).inset(by: adjustedContentInset) }

    // MARK: Overlays

    func updateOverlays() {
        guard let controller = editorController else { return }
        let config = controller.configuration

        // "/" menu.
        if let slash = controller.slash, isFirstResponder, !slash.results.isEmpty {
            slashMenu.show(slash, grouped: slash.query.isEmpty)
            positionSlashMenu(at: slash.location)
        } else {
            slashMenu.isHidden = true
        }

        // Selection toolbar.
        if config.showsSelectionToolbar, isFirstResponder, selectedRange.length > 0, controller.slash == nil, drag == nil {
            selectionToolbar.update(controller)
            positionSelectionToolbar()
        } else {
            selectionToolbar.isHidden = true
        }

        // Block handle beside the caret's block.
        if config.showsBlockHandles, isFirstResponder || drag != nil, selectedRange.length == 0 || drag != nil,
           controller.slash == nil, textStorage.length > 0 {
            positionBlockHandle(controller)
        } else {
            blockHandle.isHidden = true
        }
    }

    private func positionSlashMenu(at location: Int) {
        let caret = caretRect(for: position(from: beginningOfDocument, offset: location) ?? endOfDocument)
        let visible = visibleRect
        let size = slashMenu.preferredSize(maxHeight: min(320, visible.height * 0.6))
        var x = min(max(caret.minX - 8, visible.minX + 8), visible.maxX - size.width - 8)
        x = max(x, visible.minX + 8)
        let below = caret.maxY + 6
        let y = below + size.height <= visible.maxY - 8 || caret.minY - size.height - 6 < visible.minY
            ? below : caret.minY - size.height - 6
        slashMenu.frame = CGRect(x: x, y: y, width: min(size.width, bounds.width - 16), height: size.height)
        slashMenu.isHidden = false
        bringSubviewToFront(slashMenu)
    }

    private func positionSelectionToolbar() {
        guard let range = selectedTextRange else { return }
        let rects = selectionRects(for: range).map(\.rect).filter { !$0.isEmpty && $0.width > 0 }
        guard let first = rects.first else { selectionToolbar.isHidden = true; return }
        let union = rects.dropFirst().reduce(first) { $0.union($1) }
        let visible = visibleRect
        let size = selectionToolbar.intrinsicContentSize
        let width = min(size.width, bounds.width - 16)
        var x = union.midX - width / 2
        x = min(max(x, visible.minX + 8), visible.maxX - width - 8)
        // Below the selection: the system edit menu takes the space above it.
        var y = union.maxY + 10
        if y + size.height > visible.maxY - 8 { y = max(union.minY - size.height - 52, visible.minY + 8) }
        selectionToolbar.frame = CGRect(x: x, y: y, width: width, height: size.height)
        selectionToolbar.isHidden = false
        bringSubviewToFront(selectionToolbar)
    }

    private func positionBlockHandle(_ controller: RichEditorController) {
        let location = drag.map { controller.paragraphList[min($0.source, controller.paragraphList.count - 1)].location }
            ?? controller.paragraph(at: selectedRange.location).range.location
        guard let rect = rect(ofParagraphAt: location) else { blockHandle.isHidden = true; return }
        let info = controller.info(ofParagraphAt: location)
        let metrics = EditorStyling.Metrics(controller.style)
        let lineHeight = EditorStyling.baseFont(for: info.type, style: controller.style).lineHeight
        let spacingBefore = EditorStyling.paragraphStyle(for: info, style: controller.style).paragraphSpacingBefore
        let x = textContainerInset.left + metrics.base(info.level) - handleWidth
        let y = rect.minY + spacingBefore + (lineHeight - 28) / 2
        blockHandle.frame = CGRect(x: max(x, 0), y: y, width: 24, height: 28)
        blockHandle.configure(for: controller, info: info)
        blockHandle.isHidden = false
        bringSubviewToFront(blockHandle)
    }

    /// UIKit sizes the caret to the whole line fragment, which includes
    /// paragraph spacing (tall carets in callouts, code, headings). Keep it
    /// to the text line.
    public override func caretRect(for position: UITextPosition) -> CGRect {
        var rect = super.caretRect(for: position)
        let index = offset(from: beginningOfDocument, to: position)
        let layout = editorLayoutManager
        var used: CGRect?
        if index >= textStorage.length {
            if !layout.extraLineFragmentUsedRect.isEmpty { used = layout.extraLineFragmentUsedRect }
        } else if layout.numberOfGlyphs > 0 {
            let glyph = layout.glyphIndexForCharacter(at: index)
            used = layout.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
        }
        guard let used, rect.height > used.height + 1 else { return rect }
        rect.origin.y = used.minY + textContainerInset.top
        rect.size.height = used.height
        return rect
    }

    // MARK: Taps on markers

    /// Paragraph location of the checkbox / toggle arrow / callout icon at `point`.
    private func markerHit(at point: CGPoint) -> (location: Int, info: BlockInfo)? {
        guard let controller = editorController else { return nil }
        let p = CGPoint(x: point.x - textContainerInset.left, y: point.y - textContainerInset.top)
        var location: Int
        if textStorage.length == 0 {
            location = 0
        } else {
            let glyph = editorLayoutManager.glyphIndex(for: p, in: textContainer)
            location = editorLayoutManager.characterIndexForGlyph(at: glyph)
            let lastLine = editorLayoutManager.extraLineFragmentRect
            if !lastLine.isEmpty, p.y >= lastLine.minY { location = textStorage.length }
        }
        let paragraph = controller.paragraph(at: location)
        let start = paragraph.isTrailing ? textStorage.length : paragraph.range.location
        guard let marker = editorLayoutManager.markerRect(ofParagraphAt: start), marker.contains(p) else { return nil }
        return (start, controller.info(ofParagraphAt: start))
    }

    // With a quoted original below the text, UIKit's own scrolling (on focus,
    // keyboard, Return, typing on the last line) scrolls to the end of the
    // scrollable area, i.e. past the whole quoted original. Programmatic
    // scrolls are capped to what keeps the caret visible; the user's own
    // drags and flicks are left alone.
    public override var contentOffset: CGPoint {
        get { super.contentOffset }
        set { super.contentOffset = limitingAutoScroll(newValue) }
    }

    public override func setContentOffset(_ contentOffset: CGPoint, animated: Bool) {
        super.setContentOffset(limitingAutoScroll(contentOffset), animated: animated)
    }

    private func limitingAutoScroll(_ target: CGPoint) -> CGPoint {
        guard appliedQuotedInset > 0, isFirstResponder, drag == nil, !isTracking, !isDragging, !isDecelerating,
              target.y > super.contentOffset.y, let caret = selectedTextRange?.end else { return target }
        // Only the keyboard / safe area hides content; the quoted original's inset doesn't.
        let hiddenBottom = max(adjustedContentInset.bottom - appliedQuotedInset, 0)
        let caretBottom = caretRect(for: caret).maxY + textContainerInset.bottom
        let needed = caretBottom - bounds.height + hiddenBottom
        let limit = max(super.contentOffset.y, needed)
        return CGPoint(x: target.x, y: min(target.y, limit))
    }

    // The quoted original sits in `contentInset`, which UITextView's own
    // sizing ignores; count it when the view grows with its content.
    public override func sizeThatFits(_ size: CGSize) -> CGSize {
        var fitting = super.sizeThatFits(size)
        fitting.height += quotedReservedHeight
        return fitting
    }

    public override var intrinsicContentSize: CGSize {
        var size = super.intrinsicContentSize
        if !isScrollEnabled, size.height != UIView.noIntrinsicMetric { size.height += quotedReservedHeight }
        return size
    }

    public override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        let point = gestureRecognizer.location(in: self)
        // The quoted original is read-only: no caret or selection there, only scrolling.
        if isQuotedOriginalTouch(gestureRecognizer) { return false }
        if gestureRecognizer === markerTap { return markerHit(at: point) != nil || failedUploadImage(at: point) != nil }
        // Touches on the menus / handle belong to them, not to text selection.
        for overlay in [slashMenu, selectionToolbar, blockHandle] as [UIView]
        where !overlay.isHidden && overlay.frame.insetBy(dx: -6, dy: -6).contains(point) && gestureRecognizer.view === self {
            return false
        }
        // Don't move the caret / start selection when a marker is tapped.
        if gestureRecognizer is UITapGestureRecognizer, markerHit(at: point) != nil || failedUploadImage(at: point) != nil {
            return false
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    @objc private func handleMarkerTap(_ recognizer: UITapGestureRecognizer) {
        if let failed = failedUploadImage(at: recognizer.location(in: self)) {
            presentImageUploadFailure(source: failed.source)
            return
        }
        guard let controller = editorController, let hit = markerHit(at: recognizer.location(in: self)) else { return }
        UISelectionFeedbackGenerator().selectionChanged()
        switch hit.info.type {
        case .todo: controller.toggleChecked(paragraphAt: hit.location)
        case .toggle: controller.toggleCollapsed(paragraphAt: hit.location)
        case .callout:
            let rect = editorLayoutManager.markerRect(ofParagraphAt: hit.location)?
                .offsetBy(dx: textContainerInset.left, dy: textContainerInset.top) ?? .zero
            presentEmojiPicker(from: rect, paragraphAt: hit.location)
        default: break
        }
    }

    // MARK: Drag to reorder

    @objc private func handleDrag(_ pan: UIPanGestureRecognizer) {
        guard let controller = editorController else { return }
        let point = pan.location(in: self)
        switch pan.state {
        case .began:
            guard let index = controller.currentBlockIndex else { pan.state = .cancelled; return }
            drag = (index, index)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            selectionToolbar.isHidden = true
            updateDropTarget(at: point)
        case .changed:
            updateDropTarget(at: point)
            let visible = visibleRect
            if isScrollEnabled {
                autoScrollSpeed = point.y < visible.minY + 60 ? -8 : point.y > visible.maxY - 60 ? 8 : 0
                if autoScrollSpeed != 0, autoScrollLink == nil {
                    autoScrollLink = CADisplayLink(target: self, selector: #selector(autoScroll))
                    autoScrollLink?.add(to: .main, forMode: .common)
                }
            }
        case .ended:
            stopAutoScroll()
            if let drag { controller.moveBlock(at: drag.source, toBefore: drag.target) }
            endDrag()
        default:
            stopAutoScroll()
            endDrag()
        }
    }

    @objc private func autoScroll() {
        guard autoScrollSpeed != 0 else { return }
        let maxY = max(contentSize.height - bounds.height + adjustedContentInset.bottom, -adjustedContentInset.top)
        let y = min(max(contentOffset.y + autoScrollSpeed, -adjustedContentInset.top), maxY)
        setContentOffset(CGPoint(x: contentOffset.x, y: y), animated: false)
    }

    private func stopAutoScroll() {
        autoScrollLink?.invalidate()
        autoScrollLink = nil
        autoScrollSpeed = 0
    }

    private func endDrag() {
        drag = nil
        dropIndicator.isHidden = true
        updateOverlays()
    }

    private func updateDropTarget(at point: CGPoint) {
        guard let controller = editorController, var drag else { return }
        let list = controller.paragraphList
        let span = controller.blockSpan(at: drag.source)
        var target = list.count
        var lineY: CGFloat?
        for (i, p) in list.enumerated() {
            guard let rect = rect(ofParagraphAt: p.location) else { continue }
            if point.y < rect.midY { target = i; lineY = rect.minY; break }
            lineY = rect.maxY
        }
        // Dropping inside the dragged block (or right where it is) is a no-op.
        if target > span.lowerBound && target <= span.upperBound { target = span.lowerBound }
        drag.target = target
        self.drag = drag
        let level = target < list.count ? controller.info(ofParagraphAt: list[target].location).level : 1
        let x = textContainerInset.left + EditorStyling.Metrics(controller.style).base(level)
        dropIndicator.frame = CGRect(x: x, y: (lineY ?? 0) - 1.5, width: bounds.width - x - textContainerInset.right, height: 3)
        dropIndicator.isHidden = target == span.lowerBound
        bringSubviewToFront(dropIndicator)
    }

    // MARK: Editing hooks

    public override func deleteBackward() {
        if editorController?.handleDeleteBackward() == true { return }
        super.deleteBackward()
    }

    public override func paste(_ sender: Any?) {
        if editorController?.handlePaste() == true { return }
        super.paste(sender)
    }

    public override func copy(_ sender: Any?) {
        if editorController?.handleCopy(cut: false) == true { return }
        super.copy(sender)
    }

    public override func cut(_ sender: Any?) {
        if editorController?.handleCopy(cut: true) == true { return }
        super.cut(sender)
    }

    public override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), UIPasteboard.general.hasImages { return true }
        return super.canPerformAction(action, withSender: sender)
    }

    // MARK: Keyboard

    public override var keyCommands: [UIKeyCommand]? {
        var commands: [UIKeyCommand] = []
        func key(_ input: String, _ modifiers: UIKeyModifierFlags = [], _ title: String, _ action: Selector, priority: Bool = false) {
            let command = UIKeyCommand(title: title, action: action, input: input, modifierFlags: modifiers)
            if priority { command.wantsPriorityOverSystemBehavior = true }
            commands.append(command)
        }
        if editorController?.slash != nil {
            key(UIKeyCommand.inputUpArrow, [], "Previous Command", #selector(slashUp), priority: true)
            key(UIKeyCommand.inputDownArrow, [], "Next Command", #selector(slashDown), priority: true)
            key(UIKeyCommand.inputEscape, [], "Close Menu", #selector(slashEscape), priority: true)
        }
        key("\t", [], "Indent", #selector(tabKey), priority: true)
        key("\t", .shift, "Outdent", #selector(shiftTabKey), priority: true)
        key("\r", .shift, "Line Break", #selector(lineBreakKey))
        key("\r", .command, "Check / Expand", #selector(commandReturn))
        key("b", .command, "Bold", #selector(boldKey))
        key("i", .command, "Italic", #selector(italicKey))
        key("u", .command, "Underline", #selector(underlineKey))
        key("s", [.command, .shift], "Strikethrough", #selector(strikeKey))
        key("e", .command, "Inline Code", #selector(codeKey))
        key("k", .command, "Link", #selector(linkKey))
        key("d", .command, "Duplicate Block", #selector(duplicateKey))
        key(UIKeyCommand.inputUpArrow, [.command, .shift], "Move Block Up", #selector(moveUpKey))
        key(UIKeyCommand.inputDownArrow, [.command, .shift], "Move Block Down", #selector(moveDownKey))
        let turnInto: [(String, RichBlockType)] = [("0", .paragraph), ("1", .heading1), ("2", .heading2), ("3", .heading3),
                                                  ("4", .todo), ("5", .bulletList), ("6", .numberedList), ("7", .toggle), ("8", .codeBlock)]
        for (input, type) in turnInto {
            key(input, [.command, .alternate], "Turn into \(type.title)", #selector(turnIntoKey(_:)))
        }
        return commands
    }

    @objc private func slashUp() { editorController?.moveSlashSelection(by: -1) }
    @objc private func slashDown() { editorController?.moveSlashSelection(by: 1) }
    @objc private func slashEscape() { editorController?.cancelSlashCommand() }
    @objc private func tabKey() {
        guard let controller = editorController else { return }
        if controller.blockType == .codeBlock { insertText("    ") } else { controller.indent() }
    }
    @objc private func shiftTabKey() { editorController?.outdent() }
    @objc private func lineBreakKey() { editorController?.insertLineBreak() }
    @objc private func commandReturn() {
        guard let controller = editorController else { return }
        if controller.blockType == .todo { controller.toggleChecked() } else if controller.blockType == .toggle { controller.toggleCollapsed() }
    }
    @objc private func boldKey() { editorController?.toggle(.bold) }
    @objc private func italicKey() { editorController?.toggle(.italic) }
    @objc private func underlineKey() { editorController?.toggle(.underline) }
    @objc private func strikeKey() { editorController?.toggle(.strikethrough) }
    @objc private func codeKey() { editorController?.toggle(.code) }
    @objc private func linkKey() { editorController?.beginLinkEditing() }
    @objc private func duplicateKey() { editorController?.duplicateBlock() }
    @objc private func moveUpKey() { editorController?.moveBlockUp() }
    @objc private func moveDownKey() { editorController?.moveBlockDown() }
    @objc private func turnIntoKey(_ command: UIKeyCommand) {
        let map: [String: RichBlockType] = ["0": .paragraph, "1": .heading1, "2": .heading2, "3": .heading3,
                                            "4": .todo, "5": .bulletList, "6": .numberedList, "7": .toggle, "8": .codeBlock]
        if let input = command.input, let type = map[input] { editorController?.setBlock(type) }
    }

    // MARK: Accessibility

    public override var accessibilityCustomActions: [UIAccessibilityCustomAction]? {
        get {
            guard let controller = editorController else { return nil }
            var actions: [UIAccessibilityCustomAction] = []
            func add(_ name: String, _ body: @escaping () -> Void) {
                actions.append(UIAccessibilityCustomAction(name: name) { _ in body(); return true })
            }
            switch controller.blockType {
            case .todo: add(controller.isChecked ? "Uncheck" : "Check") { controller.toggleChecked() }
            case .toggle: add(controller.info(ofParagraphAt: controller.selectedRange.location).collapsed == nil ? "Collapse" : "Expand") { controller.toggleCollapsed() }
            default: break
            }
            if controller.canIndent { add("Indent") { controller.indent() } }
            if controller.canOutdent { add("Outdent") { controller.outdent() } }
            add("Move block up") { controller.moveBlockUp() }
            add("Move block down") { controller.moveBlockDown() }
            add("Duplicate block") { controller.duplicateBlock() }
            add("Delete block") { controller.deleteBlock() }
            return actions
        }
        set {}
    }

    // MARK: Presenting UI

    var presentingController: UIViewController? {
        var controller = window?.rootViewController
        while let presented = controller?.presentedViewController, !presented.isBeingDismissed { controller = presented }
        return controller
    }

    func presentImagePicker() {
        guard let presenter = presentingController else { return }
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 0
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        presenter.present(picker, animated: true)
    }

    func presentImageURLPrompt() {
        guard let presenter = presentingController else { return }
        let alert = UIAlertController(title: "Image link", message: "Paste the address of an image.", preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "https://example.com/image.png"
            field.keyboardType = .URL
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in self?.becomeFirstResponder() })
        alert.addAction(UIAlertAction(title: "Embed", style: .default) { [weak self, weak alert] _ in
            guard let text = alert?.textFields?.first?.text, let url = RichEditorController.normalizedURL(text) else { return }
            self?.editorController?.insertImage(url: url)
            self?.becomeFirstResponder()
        })
        presenter.present(alert, animated: true)
    }

    func presentEmojiPicker(from rect: CGRect, paragraphAt location: Int) {
        guard let presenter = presentingController, let controller = editorController else { return }
        let picker = EditorEmojiPicker { [weak self, weak controller] emoji in
            guard let self, let controller else { return }
            let selection = self.selectedRange
            self.selectedRange = NSRange(location: location, length: 0)
            controller.setCalloutEmoji(emoji)
            self.selectedRange = selection
        }
        picker.modalPresentationStyle = .popover
        picker.popoverPresentationController?.sourceView = self
        picker.popoverPresentationController?.sourceRect = rect
        picker.popoverPresentationController?.delegate = picker
        presenter.present(picker, animated: true)
    }
}

extension RichEditorTextView: PHPickerViewControllerDelegate {
    public func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        becomeFirstResponder()
        for result in results where result.itemProvider.canLoadObject(ofClass: UIImage.self) {
            result.itemProvider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
                guard let image = object as? UIImage else { return }
                DispatchQueue.main.async { self?.editorController?.insertImage(image) }
            }
        }
    }
}

public extension RichEditorController {
    /// Connects a UIKit `RichEditorTextView` (SwiftUI's `RichContentEditor`
    /// does this for you).
    func attach(to textView: RichEditorTextView) {
        attach(textView, style: style)
    }
}
