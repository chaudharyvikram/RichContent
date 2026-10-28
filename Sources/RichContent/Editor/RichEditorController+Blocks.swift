import UIKit

extension RichEditorController {

    // MARK: - Inline formats

    public func toggle(_ format: RichInlineFormat) {
        guard format != .link else { beginLinkEditing(); return }
        let turnOn = !activeFormats.contains(format)
        applyInline(actionName: format.title) { inline in
            switch format {
            case .bold: inline.bold = turnOn
            case .italic: inline.italic = turnOn
            case .underline: inline.underline = turnOn
            case .strikethrough: inline.strike = turnOn
            case .code: inline.code = turnOn
            case .link: break
            }
        }
    }

    /// Text color of the selection (or of what is typed next).
    public func setTextColor(_ color: RichColor) {
        applyInline(actionName: "Color") { $0.color = color == .default ? nil : color }
    }

    /// Highlight of the selection (or of what is typed next).
    public func setHighlight(_ color: RichColor) {
        applyInline(actionName: "Highlight") { $0.highlight = color == .default ? nil : color }
    }

    func applyInline(actionName: String, _ change: @escaping (inout InlineInfo) -> Void) {
        guard let tv = textView else { return }
        let range = tv.selectedRange
        if range.length == 0 {
            var inline = InlineInfo(tv.typingAttributes)
            change(&inline)
            tv.typingAttributes = EditorStyling.attributes(block: BlockInfo(tv.typingAttributes), inline: inline, style: style)
            refreshState()
            tv.updateOverlays()
            return
        }
        edit(range, actionName: actionName) { m in
            var runs: [(NSRange, [NSAttributedString.Key: Any])] = []
            m.enumerateAttributes(in: NSRange(location: 0, length: m.length)) { attrs, r, _ in
                guard attrs[.attachment] == nil, !(m.string as NSString).substring(with: r).allSatisfy({ $0 == "\n" }) else { return }
                var inline = InlineInfo(attrs)
                change(&inline)
                runs.append((r, EditorStyling.attributes(block: BlockInfo(attrs), inline: inline, style: self.style)))
            }
            for (r, a) in runs { m.setAttributes(a, range: r) }
        }
    }

    /// Adds, changes or removes (`url == nil`) a link on `range`. With an empty
    /// range, inserts `title` (or the URL) as linked text.
    public func setLink(_ url: URL?, title: String? = nil, range: NSRange? = nil) {
        guard let tv = textView else { return }
        let target = range ?? tv.selectedRange
        guard NSMaxRange(target) <= tv.textStorage.length else { return }
        if target.length == 0 {
            guard let url else { return }
            let text = title?.isEmpty == false ? title! : url.absoluteString
            var inline = InlineInfo(tv.typingAttributes)
            inline.link = url
            let inserted = NSAttributedString(
                string: text, attributes: EditorStyling.attributes(block: BlockInfo(tv.typingAttributes), inline: inline, style: style))
            replace(target, with: inserted, actionName: "Link", selection: NSRange(location: target.location + inserted.length, length: 0))
        } else {
            edit(target, actionName: url == nil ? "Remove Link" : "Link") { m in
                var runs: [(NSRange, [NSAttributedString.Key: Any])] = []
                m.enumerateAttributes(in: NSRange(location: 0, length: m.length)) { attrs, r, _ in
                    guard attrs[.attachment] == nil else { return }
                    var inline = InlineInfo(attrs)
                    inline.link = url
                    runs.append((r, EditorStyling.attributes(block: BlockInfo(attrs), inline: inline, style: self.style)))
                }
                for (r, a) in runs { m.setAttributes(a, range: r) }
            }
        }
    }

    // MARK: - Turn into

    /// Sets the block type of every block in the selection.
    public func setBlock(_ type: RichBlockType) {
        guard configuration.allowedBlocks.contains(type) else { return }
        if type == .divider { insertDivider(); return }
        if type == .table { insertTable(); return }
        if type == .image { textView?.presentImagePicker(); return }
        guard let tv = textView else { return }

        if currentParagraph.isTrailing {
            trailingInfo = newInfo(type, from: trailingInfo, hasChildren: false)
            syncTypingAttributes()
            tv.redrawDecorations()
            refreshState()
            tv.updateOverlays()
            return
        }

        let list = paragraphList
        let selected = selectedParagraphs
        guard let first = selected.first, let firstIndex = list.firstIndex(of: first) else { return }
        let indices = firstIndex..<(firstIndex + selected.count)
        let blocks = documentBlocks
        var result: [EditorBlock] = []
        for i in indices {
            var block = blocks[i]
            let hasChildren = i + 1 < blocks.count && blocks[i + 1].info.level > block.info.level
            let hidden = block.hiddenChildren
            block.info = newInfo(type, from: block.info, hasChildren: hasChildren || !(hidden ?? []).isEmpty)
            if block.info.type.isAttachment { continue }
            if type == .toggle, block.info.collapsed != nil {
                block.hiddenChildren = hidden ?? []
                block.info.collapsed = nil
            } else {
                block.hiddenChildren = nil
            }
            if type == .codeBlock { block.content = NSAttributedString(string: block.content.string) }
            result.append(block)
            // Converting a collapsed toggle into something else reveals its children.
            if type != .toggle, let hidden { result += hidden }
        }
        let selection = tv.selectedRange
        let oldLength = tv.textStorage.length
        let caretIndex = (list.firstIndex { NSLocationInRange(selection.location, $0) } ?? firstIndex) - firstIndex
        replaceParagraphs(indices, with: result, actionName: type.title,
                          caretBlock: max(caretIndex, 0), caretOffset: selection.location - list[firstIndex + max(caretIndex, 0)].location)
        if tv.textStorage.length == oldLength { tv.selectedRange = selection }
    }

    /// Toolbar behaviour: choosing the active block type turns it back into text.
    public func toggleBlock(_ type: RichBlockType) {
        setBlock(blockType == type ? .paragraph : type)
    }

    private func newInfo(_ type: RichBlockType, from old: BlockInfo, hasChildren: Bool) -> BlockInfo {
        var info = BlockInfo(type: type, level: old.level)
        switch type {
        case .todo: info.checked = old.type == .todo ? old.checked : false
        case .callout:
            info.emoji = old.emoji ?? "💡"
            info.color = old.color
        case .codeBlock: info.language = old.language
        case .toggle:
            // A new toggle starts closed (like Notion) unless it already has children.
            info.collapsed = old.type == .toggle ? old.collapsed : (hasChildren ? nil : RichToggleChildren(content: NSAttributedString(), level: old.level))
        default: break
        }
        return info
    }

    // MARK: - Nesting

    public func indent() { changeLevel(by: 1) }
    public func outdent() { changeLevel(by: -1) }

    func changeLevel(by delta: Int) {
        guard let tv = textView else { return }
        if currentParagraph.isTrailing {
            let limit = maxLevel(before: tv.textStorage.length) + 1
            trailingInfo.level = min(max(trailingInfo.level + delta, 1), min(limit, EditorStyling.maxLevel))
            syncTypingAttributes()
            tv.redrawDecorations()
            refreshState()
            return
        }
        let list = paragraphList
        let selected = selectedParagraphs
        guard let first = selected.first, let firstIndex = list.firstIndex(of: first) else { return }
        var blocks = documentBlocks
        let lastSpan = blockSpan(at: firstIndex + selected.count - 1)
        let indices = firstIndex..<lastSpan.upperBound

        if delta > 0 {
            guard firstIndex > 0, blocks[firstIndex].info.level <= blocks[firstIndex - 1].info.level else { return }
        } else {
            guard blocks[firstIndex].info.level > 1 else { return }
        }
        for i in indices {
            blocks[i].info.level = min(max(blocks[i].info.level + delta, 1), EditorStyling.maxLevel)
        }
        let selection = tv.selectedRange
        let caretOffset = selection.location - first.location

        // Indenting under a closed toggle puts the blocks inside it.
        if delta > 0, firstIndex > 0, blocks[firstIndex - 1].info.type == .toggle,
           blocks[firstIndex - 1].hiddenChildren != nil,
           blocks[firstIndex].info.level == blocks[firstIndex - 1].info.level + 1 {
            var toggle = blocks[firstIndex - 1]
            toggle.hiddenChildren = (toggle.hiddenChildren ?? []) + Array(blocks[indices])
            replaceParagraphs((firstIndex - 1)..<indices.upperBound, with: [toggle], actionName: "Indent",
                              caretBlock: 0, caretOffset: toggle.content.length)
            return
        }
        replaceParagraphs(indices, with: Array(blocks[indices]), actionName: delta > 0 ? "Indent" : "Outdent",
                          caretBlock: 0, caretOffset: caretOffset)
        if selection.length > 0, tv.textStorage.length >= NSMaxRange(selection) { tv.selectedRange = selection }
    }

    // MARK: - To-dos, toggles, callouts, code

    /// Checks / unchecks the to-do under the caret.
    public func toggleChecked() {
        let p = currentParagraph
        guard !p.isTrailing else {
            if trailingInfo.type == .todo { trailingInfo.checked.toggle(); syncTypingAttributes(); textView?.redrawDecorations(); refreshState() }
            return
        }
        toggleChecked(paragraphAt: p.range.location)
    }

    func toggleChecked(paragraphAt location: Int) {
        guard let s = storage else { return }
        let p = paragraph(at: location)
        guard !p.isTrailing else { toggleChecked(); return }
        var info = EditorStyling.info(ofParagraph: p.range, in: s)
        guard info.type == .todo else { return }
        info.checked.toggle()
        let selection = selectedRange
        edit(p.range, actionName: info.checked ? "Check" : "Uncheck") { m in
            EditorStyling.apply(info, toParagraph: NSRange(location: 0, length: m.length), in: m, style: self.style)
        }
        textView?.selectedRange = selection
    }

    /// Opens / closes the toggle under the caret.
    public func toggleCollapsed() {
        let p = currentParagraph
        guard !p.isTrailing else { return }
        toggleCollapsed(paragraphAt: p.range.location)
    }

    func toggleCollapsed(paragraphAt location: Int) {
        guard let tv = textView, let s = storage else { return }
        let p = paragraph(at: location)
        guard !p.isTrailing else { return }
        let info = EditorStyling.info(ofParagraph: p.range, in: s)
        guard info.type == .toggle else { return }
        let selection = tv.selectedRange
        if info.collapsed != nil {
            edit(p.range, actionName: "Expand") { m in
                EditorDocument.expandToggle(paragraph: NSRange(location: 0, length: m.length), in: m, style: self.style)
            }
            tv.selectedRange = selection
        } else {
            let children = EditorStyling.childrenRange(of: p.range, in: s)
            let range = NSRange(location: p.range.location, length: p.range.length + children.length)
            edit(range, actionName: "Collapse") { m in
                EditorDocument.collapseToggle(paragraph: NSRange(location: 0, length: p.range.length), in: m)
            }
            if NSLocationInRange(selection.location, children) {
                tv.selectedRange = NSRange(location: p.range.location + contentLength(p.range), length: 0)
            } else if selection.location >= NSMaxRange(range) {
                tv.selectedRange = NSRange(location: selection.location - children.length, length: 0)
            } else {
                tv.selectedRange = selection
            }
        }
        syncTypingAttributes()
    }

    public func setCalloutEmoji(_ emoji: String) {
        updateCurrentInfo(actionName: "Callout Icon") { if $0.type == .callout { $0.emoji = emoji } }
    }

    public func setCodeLanguage(_ language: String?) {
        updateCurrentInfo(actionName: "Code Language") { if $0.type == .codeBlock { $0.language = language } }
    }

    /// Text color (or background, for a callout's box) of the whole block.
    public func setBlockColor(_ color: RichColor, background: Bool = false) {
        guard let tv = textView else { return }
        if background, blockType == .callout {
            updateCurrentInfo(actionName: "Color") { $0.color = color }
            return
        }
        let selection = tv.selectedRange
        let paragraphs = selectedParagraphs
        guard let first = paragraphs.first, let last = paragraphs.last else { return }
        tv.selectedRange = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
        if background { setHighlight(color) } else { setTextColor(color) }
        tv.selectedRange = selection
        syncTypingAttributes()
    }

    func updateCurrentInfo(actionName: String, _ change: (inout BlockInfo) -> Void) {
        guard let s = storage else { return }
        let p = currentParagraph
        if p.isTrailing {
            change(&trailingInfo)
            syncTypingAttributes()
            textView?.redrawDecorations()
            return
        }
        var info = EditorStyling.info(ofParagraph: p.range, in: s)
        change(&info)
        let selection = selectedRange
        edit(p.range, actionName: actionName) { m in
            EditorStyling.apply(info, toParagraph: NSRange(location: 0, length: m.length), in: m, style: self.style)
        }
        textView?.selectedRange = selection
    }

    // MARK: - Dividers and images

    public func insertDivider() {
        guard configuration.allowedBlocks.contains(.divider) else { return }
        insertAttachmentBlock(EditorBlock(.divider, level: info(ofParagraphAt: selectedRange.location).level), actionName: "Divider")
    }

    /// Inserts an image block (uploaded with `imageUploader`, or embedded).
    public func insertImage(_ image: UIImage, alt: String = "") {
        guard configuration.allowedBlocks.contains(.image) else { return }
        let scaled = image.scaledDown(toPixels: configuration.maxImagePixelSize)
        guard let dataURL = scaled.dataURL() else { return }
        var block = EditorBlock(.image, level: info(ofParagraphAt: selectedRange.location).level)
        block.image = EditorImage(source: dataURL, alt: alt, size: scaled.size)
        insertAttachmentBlock(block, actionName: "Image")
        startImageUpload(source: dataURL, image: scaled)
    }

    /// Inserts an image block that loads from `url`.
    public func insertImage(url: URL, alt: String = "") {
        guard configuration.allowedBlocks.contains(.image) else { return }
        var block = EditorBlock(.image, level: info(ofParagraphAt: selectedRange.location).level)
        block.image = EditorImage(source: url.absoluteString, alt: alt)
        insertAttachmentBlock(block, actionName: "Image")
    }

    /// Image / divider: replaces an empty current block, else goes below it.
    /// The caret moves to the block after it (created when needed).
    func insertAttachmentBlock(_ block: EditorBlock, actionName: String) {
        let p = currentParagraph
        let list = paragraphList
        let follower = EditorBlock(.paragraph, level: block.info.level)
        if p.isTrailing {
            replaceParagraphs(list.count..<list.count, with: [block, follower], actionName: actionName, caretBlock: 1)
            return
        }
        guard let index = list.firstIndex(of: p.range) else { return }
        let blocks = documentBlocks
        let current = blocks[index]
        if current.info.type == .paragraph, current.content.length == 0 {
            replaceParagraphs(index..<(index + 1), with: [block, follower], actionName: actionName, caretBlock: 1)
        } else {
            let span = blockSpan(at: index)
            let hasNext = span.upperBound < blocks.count
            replaceParagraphs(span.upperBound..<span.upperBound, with: hasNext ? [block] : [block, follower],
                              actionName: actionName, caretBlock: 1)
        }
    }

    // MARK: - Block actions

    public func duplicateBlock() {
        guard let index = currentBlockIndex else { return }
        let span = blockSpan(at: index)
        let blocks = documentBlocks
        let copy = Array(blocks[span])
        replaceParagraphs(span, with: copy + copy, actionName: "Duplicate",
                          caretBlock: span.count, caretOffset: selectedRange.location - paragraphList[index].location)
    }

    public func deleteBlock() {
        guard let index = currentBlockIndex else {
            trailingInfo = BlockInfo()
            syncTypingAttributes()
            textView?.redrawDecorations()
            return
        }
        replaceParagraphs(blockSpan(at: index), with: [], actionName: "Delete Block")
    }

    public func moveBlockUp() {
        guard let index = currentBlockIndex else { return }
        let blocks = documentBlocks
        let level = blocks[index].info.level
        var previous = index - 1
        while previous >= 0, blocks[previous].info.level > level { previous -= 1 }
        guard previous >= 0, blocks[previous].info.level == level else { return }
        let span = blockSpan(at: index)
        let offset = selectedRange.location - paragraphList[index].location
        replaceParagraphs(previous..<span.upperBound, with: Array(blocks[span]) + Array(blocks[previous..<index]),
                          actionName: "Move Up", caretBlock: 0, caretOffset: offset)
    }

    public func moveBlockDown() {
        guard let index = currentBlockIndex else { return }
        let blocks = documentBlocks
        let span = blockSpan(at: index)
        guard span.upperBound < blocks.count, blocks[span.upperBound].info.level == blocks[index].info.level else { return }
        let next = blockSpan(at: span.upperBound)
        let offset = selectedRange.location - paragraphList[index].location
        replaceParagraphs(index..<next.upperBound, with: Array(blocks[next]) + Array(blocks[span]),
                          actionName: "Move Down", caretBlock: next.count, caretOffset: offset)
    }

    /// Drag and drop: moves the block at `index` (with its children) so it
    /// lands before block `target` (or at the end), at that block's level.
    func moveBlock(at index: Int, toBefore target: Int) {
        let blocks = documentBlocks
        guard index < blocks.count else { return }
        let span = blockSpan(at: index)
        guard target < span.lowerBound || target > span.upperBound else { return }
        let newLevel = target < blocks.count ? blocks[target].info.level : 1
        let delta = newLevel - blocks[index].info.level
        let moved = blocks[span].map { block -> EditorBlock in
            var b = block
            b.info.level = min(max(b.info.level + delta, 1), EditorStyling.maxLevel)
            return b
        }
        let lo = min(span.lowerBound, target)
        let hi = max(span.upperBound, target)
        var slice = Array(blocks[lo..<hi])
        slice.removeSubrange((span.lowerBound - lo)..<(span.upperBound - lo))
        let position = target <= span.lowerBound ? target - lo : target - lo - span.count
        slice.insert(contentsOf: moved, at: position)
        replaceParagraphs(lo..<hi, with: slice, actionName: "Move", caretBlock: position, caretOffset: .max)
    }

    var currentBlockIndex: Int? {
        let p = currentParagraph
        guard !p.isTrailing else { return nil }
        return paragraphList.firstIndex(of: p.range)
    }

    // MARK: - Copy & paste

    /// Copies the selection as HTML (full fidelity inside the editor and in
    /// other apps) and plain text.
    func handleCopy(cut: Bool) -> Bool {
        guard let tv = textView, tv.selectedRange.length > 0 else { return false }
        let selection = tv.selectedRange
        let piece = tv.textStorage.attributedSubstring(from: selection)
        UIPasteboard.general.items = [[
            "public.html": RichEditorSerializer.html(from: piece),
            "public.utf8-plain-text": RichEditorSerializer.plainText(from: piece)
        ]]
        if cut {
            replace(selection, with: NSAttributedString(), actionName: "Cut", selection: NSRange(location: selection.location, length: 0))
        }
        return true
    }

    /// Paste: HTML (from the editor, Safari, Mail, Notes, Docs …) keeps its
    /// blocks and formats; images become image blocks; a URL over selected
    /// text links it; multi-line plain text becomes blocks.
    func handlePaste() -> Bool {
        guard let tv = textView else { return false }
        let pasteboard = UIPasteboard.general
        var blocks: [EditorBlock]?

        if let data = pasteboard.data(forPasteboardType: "public.html"), let html = String(data: data, encoding: .utf8) {
            blocks = EditorHTMLParser.blocks(fromHTML: html)
        } else if !pasteboard.hasStrings, pasteboard.hasImages, let image = pasteboard.image {
            insertImage(image)
            return true
        } else if let string = pasteboard.string {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
               ["http", "https", "mailto"].contains(scheme), !trimmed.contains(" ") {
                if tv.selectedRange.length > 0 { setLink(url); return true }
                setLink(url, title: trimmed)
                return true
            }
            if !string.contains("\n") {
                let attrs = EditorStyling.attributes(block: BlockInfo(tv.typingAttributes), inline: { var i = InlineInfo(tv.typingAttributes); i.link = nil; return i }(), style: style)
                let text = NSAttributedString(string: string, attributes: attrs)
                let range = tv.selectedRange
                replace(range, with: text, actionName: "Paste", selection: NSRange(location: range.location + text.length, length: 0))
                tv.scrollRangeToVisible(tv.selectedRange)
                return true
            }
            blocks = EditorImporter.plainBlocks(string)
        }
        guard let pasted = blocks?.filter({ configuration.allowedBlocks.contains($0.info.type) || $0.info.type == .paragraph }),
              !pasted.isEmpty else { return blocks != nil }
        insertBlocks(pasted)
        tv.scrollRangeToVisible(tv.selectedRange)
        return true
    }

    /// Inserts blocks at the caret: the first one's text joins the current
    /// block, the rest follow it, and the text after the caret comes last.
    func insertBlocks(_ input: [EditorBlock]) {
        guard let tv = textView else { return }
        if tv.selectedRange.length > 0 {
            replace(tv.selectedRange, with: NSAttributedString(), actionName: "Paste",
                    selection: NSRange(location: tv.selectedRange.location, length: 0))
        }
        let caret = tv.selectedRange.location
        let p = currentParagraph
        let list = paragraphList
        let index = p.isTrailing ? list.count : (list.firstIndex(of: p.range) ?? list.count)
        let currentInfo = p.isTrailing ? trailingInfo : EditorStyling.info(ofParagraph: p.range, in: tv.textStorage)

        // Single text block: paste inline, in the current block's format.
        if input.count == 1, !input[0].info.type.isAttachment, input[0].hiddenChildren == nil,
           input[0].info.type == .paragraph || input[0].info.type == currentInfo.type {
            let piece = NSMutableAttributedString()
            input[0].content.enumerateAttributes(in: NSRange(location: 0, length: input[0].content.length)) { attrs, r, _ in
                piece.append(NSAttributedString(string: (input[0].content.string as NSString).substring(with: r),
                                                attributes: EditorStyling.attributes(block: currentInfo, inline: InlineInfo(attrs), style: style)))
            }
            replace(NSRange(location: caret, length: 0), with: piece, actionName: "Paste",
                    selection: NSRange(location: caret + piece.length, length: 0))
            return
        }

        let minLevel = input.map(\.info.level).min() ?? 1
        let delta = currentInfo.level - minLevel
        var pasted = input.map { block -> EditorBlock in
            var b = block
            b.info.level = max(b.info.level + delta, 1)
            return b
        }

        var current = p.isTrailing ? EditorBlock(currentInfo.type, level: currentInfo.level) : documentBlocks[index]
        if p.isTrailing { current.info = currentInfo }
        let offset = min(max(caret - p.range.location, 0), current.content.length)
        var before = current
        before.content = current.content.attributedSubstring(from: NSRange(location: 0, length: offset))
        var after = current
        after.content = current.content.attributedSubstring(from: NSRange(location: offset, length: current.content.length - offset))
        after.hiddenChildren = nil
        if after.info.type == .toggle { after.info.collapsed = nil }

        var result: [EditorBlock] = []
        // An empty current block is replaced by what is pasted.
        if before.content.length > 0 || before.hiddenChildren != nil {
            if before.content.length > 0, let first = pasted.first, !first.info.type.isAttachment, first.hiddenChildren == nil {
                let joined = NSMutableAttributedString(attributedString: before.content)
                joined.append(first.content)
                before.content = joined
                pasted.removeFirst()
            }
            result.append(before)
        }
        result += pasted
        let caretBlock = max(result.count - 1, 0)
        let caretOffset = result.last?.content.length ?? 0
        if after.content.length > 0 { result.append(after) }
        let indices = p.isTrailing ? list.count..<list.count : index..<(index + 1)
        replaceParagraphs(indices, with: result, actionName: "Paste", caretBlock: caretBlock, caretOffset: caretOffset)
    }

    // MARK: - Color picker

    /// Shows the system color picker; the picked color is applied to the
    /// selection (or what's typed next), or to the whole block with `wholeBlock`.
    public func presentColorPicker(background: Bool, wholeBlock: Bool = false) {
        guard let tv = textView, let presenter = tv.presentingController else { return }
        let range = tv.selectedRange
        let picker = UIColorPickerViewController()
        picker.title = background ? "Background color" : "Text color"
        picker.supportsAlpha = background
        let current = background ? highlight : textColor
        if current != .default { picker.selectedColor = background ? current.backgroundColor : current.textColor }
        let coordinator = ColorPickerCoordinator(initial: picker.selectedColor) { [weak self] color in
            self?.applyPickedColor(color, background: background, wholeBlock: wholeBlock, range: range)
        }
        picker.delegate = coordinator
        objc_setAssociatedObject(picker, &ColorPickerCoordinator.key, coordinator, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        presenter.present(picker, animated: true)
        // Swipe-to-dismiss doesn't call colorPickerViewControllerDidFinish.
        picker.presentationController?.delegate = coordinator
    }

    /// Applies a color from the picker to `range` (the selection when the picker opened).
    func applyPickedColor(_ color: UIColor, background: Bool, wholeBlock: Bool, range: NSRange) {
        guard let tv = textView else { return }
        tv.becomeFirstResponder()
        if NSMaxRange(range) <= tv.textStorage.length { tv.selectedRange = range }
        let picked = RichColor.custom(color)
        if wholeBlock { setBlockColor(picked, background: background) }
        else if background { setHighlight(picked) }
        else { setTextColor(picked) }
    }

    // MARK: - Link editing UI

    /// Shows a link prompt for the selection / the link under the caret.
    public func beginLinkEditing() {
        guard let tv = textView, let presenter = tv.presentingController else { return }
        let range = tv.selectedRange
        let existing = selectedLink
        let alert = UIAlertController(title: "Link",
                                      message: range.length == 0 && existing == nil ? "The address is inserted as linked text." : nil,
                                      preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "https://example.com"
            field.text = existing?.absoluteString
            field.keyboardType = .URL
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in tv.becomeFirstResponder() })
        if existing != nil {
            alert.addAction(UIAlertAction(title: "Remove Link", style: .destructive) { [weak self] _ in
                guard let self else { return }
                let target = range.length > 0 ? range : self.linkRange(around: range.location) ?? range
                self.setLink(nil, range: target)
                tv.becomeFirstResponder()
            })
        }
        alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self, weak alert] _ in
            guard let self, let text = alert?.textFields?.first?.text, let url = Self.normalizedURL(text) else { return }
            let target = range.length > 0 ? range : (existing != nil ? self.linkRange(around: range.location) ?? range : range)
            self.setLink(url, range: target)
            tv.becomeFirstResponder()
        })
        presenter.present(alert, animated: true)
    }

    /// Range of the link run touching `location`.
    func linkRange(around location: Int) -> NSRange? {
        guard let s = storage, s.length > 0 else { return nil }
        let index = min(max(location - 1, 0), s.length - 1)
        var range = NSRange()
        guard s.attribute(.link, at: index, longestEffectiveRange: &range, in: NSRange(location: 0, length: s.length)) != nil
        else { return nil }
        return range
    }

    static func normalizedURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains("://") || trimmed.hasPrefix("mailto:") || trimmed.hasPrefix("tel:") { return URL(string: trimmed) }
        if trimmed.contains("@"), !trimmed.contains("/") { return URL(string: "mailto:" + trimmed) }
        return URL(string: "https://" + trimmed)
    }
}

/// Applies the picked color once, when the picker closes (one undo step),
/// and only if it differs from the color the picker opened with.
/// Closing with the ✕ button and swiping the sheet down both count.
final class ColorPickerCoordinator: NSObject, UIColorPickerViewControllerDelegate, UIAdaptivePresentationControllerDelegate {
    static var key = 0
    private let initial: UIColor
    private let apply: (UIColor) -> Void
    private var finished = false

    init(initial: UIColor, apply: @escaping (UIColor) -> Void) {
        self.initial = initial
        self.apply = apply
    }

    func colorPickerViewControllerDidFinish(_ viewController: UIColorPickerViewController) {
        finish(with: viewController.selectedColor)
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        guard let picker = presentationController.presentedViewController as? UIColorPickerViewController else { return }
        finish(with: picker.selectedColor)
    }

    func finish(with color: UIColor) {
        guard !finished else { return }
        finished = true
        guard RichColor.custom(color) != RichColor.custom(initial) else { return }
        // Wait for the picker to go away so the text view can take focus back.
        DispatchQueue.main.async { [apply] in apply(color) }
    }
}

// MARK: - Image helpers

extension UIImage {
    func scaledDown(toPixels maxPixels: CGFloat) -> UIImage {
        let pixelWidth = size.width * scale
        let pixelHeight = size.height * scale
        let longest = max(pixelWidth, pixelHeight)
        guard longest > maxPixels, longest > 0 else { return self }
        let factor = maxPixels / longest
        let target = CGSize(width: (pixelWidth * factor).rounded(), height: (pixelHeight * factor).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in draw(in: CGRect(origin: .zero, size: target)) }
    }

    /// JPEG (or PNG when the image has transparency) as a `data:` URL.
    func dataURL() -> String? {
        let hasAlpha: Bool = {
            guard let alpha = cgImage?.alphaInfo else { return false }
            return [.first, .last, .premultipliedFirst, .premultipliedLast].contains(alpha)
        }()
        if hasAlpha, let png = pngData() { return "data:image/png;base64," + png.base64EncodedString() }
        guard let jpeg = jpegData(compressionQuality: 0.85) else { return nil }
        return "data:image/jpeg;base64," + jpeg.base64EncodedString()
    }
}
