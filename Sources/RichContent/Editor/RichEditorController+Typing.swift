import UIKit

/// An entry of the "/" menu.
public struct RichEditorCommand: Identifiable, Equatable {
    public enum Action: Equatable {
        case block(RichBlockType)
        case imageFromURL
        case textColor(RichColor)
        case background(RichColor)
        case duplicate, delete, moveUp, moveDown
    }

    public let id: String
    public let title: String
    public let subtitle: String
    public let symbolName: String
    public let section: String
    public let keywords: [String]
    public let action: Action

    static func catalog(_ config: RichEditorConfiguration) -> [RichEditorCommand] {
        var commands: [RichEditorCommand] = []
        let blocks: [(RichBlockType, String, [String])] = [
            (.paragraph, "Just start writing with plain text.", ["text", "plain", "body", "paragraph", "p"]),
            (.heading1, "Big section heading.", ["h1", "heading", "title", "#"]),
            (.heading2, "Medium section heading.", ["h2", "heading", "subtitle", "##"]),
            (.heading3, "Small section heading.", ["h3", "heading", "subheading", "###"]),
            (.bulletList, "Create a simple bulleted list.", ["bullet", "list", "ul", "unordered", "-"]),
            (.numberedList, "Create a list with numbering.", ["numbered", "list", "ol", "ordered", "1."]),
            (.todo, "Track tasks with a to-do list.", ["todo", "to-do", "task", "checkbox", "check", "[]"]),
            (.toggle, "Toggles can hide and show content inside.", ["toggle", "collapse", "expand", "details", ">"]),
            (.quote, "Capture a quote.", ["quote", "blockquote", "citation", "\""]),
            (.callout, "Make writing stand out.", ["callout", "note", "info", "tip", "warning", "box"]),
            (.codeBlock, "Capture a code snippet.", ["code", "snippet", "pre", "```"]),
            (.divider, "Visually divide blocks.", ["divider", "line", "hr", "separator", "---"]),
            (.image, "Upload or embed with a link.", ["image", "photo", "picture", "img", "media"])
        ]
        for (type, subtitle, keywords) in blocks where config.allowedBlocks.contains(type) {
            commands.append(RichEditorCommand(id: type.rawValue, title: type.title, subtitle: type == .image ? "Choose from your photos." : subtitle,
                                              symbolName: type.symbolName, section: type == .image ? "Media" : "Basic blocks",
                                              keywords: keywords, action: .block(type)))
        }
        if config.allowedBlocks.contains(.image) {
            commands.append(RichEditorCommand(id: "image-url", title: "Image from link", subtitle: "Embed an image from a URL.",
                                              symbolName: "link", section: "Media", keywords: ["image", "url", "link", "embed"],
                                              action: .imageFromURL))
        }
        for color in RichColor.allCases {
            commands.append(RichEditorCommand(id: "color-\(color.rawValue)", title: color == .default ? "Default color" : color.title,
                                              subtitle: "Text color", symbolName: "textformat", section: "Color",
                                              keywords: [color.rawValue, "color", "colour", "text"], action: .textColor(color)))
        }
        for color in RichColor.allCases where color != .default {
            commands.append(RichEditorCommand(id: "background-\(color.rawValue)", title: "\(color.title) background",
                                              subtitle: "Highlight", symbolName: "highlighter", section: "Color",
                                              keywords: [color.rawValue, "background", "highlight", "bg"], action: .background(color)))
        }
        commands += [
            RichEditorCommand(id: "duplicate", title: "Duplicate", subtitle: "Copy this block below.", symbolName: "plus.square.on.square",
                              section: "Actions", keywords: ["duplicate", "copy", "clone"], action: .duplicate),
            RichEditorCommand(id: "move-up", title: "Move up", subtitle: "Move this block up.", symbolName: "arrow.up",
                              section: "Actions", keywords: ["move", "up"], action: .moveUp),
            RichEditorCommand(id: "move-down", title: "Move down", subtitle: "Move this block down.", symbolName: "arrow.down",
                              section: "Actions", keywords: ["move", "down"], action: .moveDown),
            RichEditorCommand(id: "delete", title: "Delete", subtitle: "Remove this block.", symbolName: "trash",
                              section: "Actions", keywords: ["delete", "remove", "trash"], action: .delete)
        ]
        return commands
    }

    /// Commands matching `query`, best first. An empty query lists the blocks.
    static func filter(_ commands: [RichEditorCommand], query: String) -> [RichEditorCommand] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return commands.filter { $0.section == "Basic blocks" || $0.section == "Media" } }
        let scored: [(RichEditorCommand, Int)] = commands.compactMap { command in
            let title = command.title.lowercased()
            if command.keywords.contains(q) || title == q { return (command, 0) }
            if title.hasPrefix(q) { return (command, 1) }
            if title.split(separator: " ").contains(where: { $0.hasPrefix(q) }) { return (command, 2) }
            if command.keywords.contains(where: { $0.hasPrefix(q) }) { return (command, 3) }
            if title.contains(q) { return (command, 4) }
            return nil
        }
        return scored.enumerated().sorted { ($0.element.1, $0.offset) < ($1.element.1, $1.offset) }.map(\.element.0)
    }
}

/// The "/" menu while it is open.
struct SlashState {
    /// Location of the "/".
    var location: Int
    var query = ""
    var results: [RichEditorCommand] = []
    var selection = 0
    /// Length of the longest query that still had results.
    var lastMatchLength = 0
}

extension RichEditorController {

    // MARK: - Text changes

    /// Decides what a keystroke does. `false` means it was handled here.
    func shouldChange(_ range: NSRange, _ text: String) -> Bool {
        guard let tv = textView, tv.markedTextRange == nil else { return true }

        if text == "\n" {
            if slash != nil { confirmSlashCommand(); return false }
            handleReturn(range)
            return false
        }

        let p = paragraph(at: range.location)
        let info = p.isTrailing ? trailingInfo : EditorStyling.info(ofParagraph: p.range, in: tv.textStorage)

        // Image / divider blocks hold no text: typing goes into a new block below.
        if info.type.isAttachment, !p.isTrailing, !text.isEmpty, range.length == 0 {
            insertTextBlock(after: p.range, text: text, level: info.level)
            return false
        }

        if range.length == 0, !text.isEmpty, info.type != .codeBlock, configuration.markdownShortcuts {
            if applyBlockShortcut(typed: text, at: range.location, paragraph: p, info: info) { return false }
            if applyInlineShortcut(typed: text, at: range.location, paragraph: p) { return false }
        }

        if text == "/", configuration.slashCommands, info.type != .codeBlock, range.length == 0 {
            let s = tv.textStorage.string as NSString
            let previous = range.location > 0 ? s.character(at: range.location - 1) : 10
            let atWordStart = range.location == p.range.location || [10, 32, 9, 0x2028, 0xA0].contains(previous)
            if atWordStart { pendingSlashLocation = range.location }
        }
        return true
    }

    /// Where a "/" is being typed (opens the menu once it is in the text).
    var pendingSlashLocation: Int? {
        get { slashPending }
        set { slashPending = newValue }
    }

    private func insertTextBlock(after p: NSRange, text: String, level: Int) {
        guard let index = paragraphList.firstIndex(of: p) else { return }
        var block = EditorBlock(.paragraph, level: level)
        block.content = NSAttributedString(string: text)
        replaceParagraphs((index + 1)..<(index + 1), with: [block], actionName: "Typing",
                          caretBlock: 0, caretOffset: (text as NSString).length)
    }

    // MARK: - Return

    func handleReturn(_ range: NSRange) {
        guard let tv = textView else { return }
        if range.length > 0 {
            replace(range, with: NSAttributedString(), actionName: "Typing", selection: NSRange(location: range.location, length: 0))
        }
        let caret = tv.selectedRange.location
        let p = paragraph(at: caret)

        if p.isTrailing {
            var info = trailingInfo
            if info.type != .paragraph {
                if info.type.hasMarker && info.level > 1 { info.level -= 1 } else { info = BlockInfo(type: .paragraph, level: info.level) }
                trailingInfo = info
                syncTypingAttributes()
                tv.redrawDecorations()
                refreshState()
                tv.updateOverlays()
                return
            }
            // Empty last line: a new empty line of the same kind.
            let attrs = EditorStyling.attributes(block: info, inline: InlineInfo(), style: style)
            replace(NSRange(location: caret, length: 0), with: NSAttributedString(string: "\n", attributes: attrs),
                    actionName: "Typing", selection: NSRange(location: caret + 1, length: 0))
            return
        }

        guard let index = paragraphList.firstIndex(of: p.range) else { return }
        let block = documentBlocks[index]
        let info = block.info
        let offset = caret - p.range.location
        let content = block.content.string as NSString

        // Code / callout: Return is a line break; Return on an empty last line leaves.
        if info.type.keepsLineBreaks {
            let endsWithBreak = offset == content.length && content.length > 0 && content.hasSuffix(EditorStyling.lineBreak)
            if !endsWithBreak {
                let attrs = tv.typingAttributes
                replace(NSRange(location: caret, length: 0), with: NSAttributedString(string: EditorStyling.lineBreak, attributes: attrs),
                        actionName: "Typing", selection: NSRange(location: caret + 1, length: 0))
                return
            }
            var trimmed = block
            trimmed.content = block.content.attributedSubstring(from: NSRange(location: 0, length: content.length - 1))
            replaceParagraphs(index..<(index + 1), with: [trimmed, EditorBlock(.paragraph, level: info.level)],
                              actionName: "Typing", caretBlock: 1)
            return
        }

        if info.type.isAttachment {
            let empty = EditorBlock(.paragraph, level: info.level)
            replaceParagraphs(index..<(index + 1), with: offset == 0 ? [empty, block] : [block, empty],
                              actionName: "Typing", caretBlock: offset == 0 ? 0 : 1)
            return
        }

        // Empty list item / quote: step out (outdent first, then plain text).
        if content.length == 0, info.type.hasMarker || info.type == .quote {
            if info.type.hasMarker, info.level > 1 { changeLevel(by: -1) } else { setBlock(.paragraph) }
            return
        }

        var first = block
        first.content = block.content.attributedSubstring(from: NSRange(location: 0, length: offset))
        var second = EditorBlock(.paragraph, level: info.level)
        second.content = block.content.attributedSubstring(from: NSRange(location: offset, length: content.length - offset))
        let atEnd = offset == content.length

        switch info.type {
        case .bulletList, .numberedList:
            second.info.type = info.type
        case .todo:
            second.info.type = .todo
        case .toggle:
            if block.hiddenChildren == nil, atEnd {
                // Open toggle: the new block goes inside it, first.
                second.info.level = info.level + 1
            } else {
                second.info.type = .toggle
                second.info.collapsed = RichToggleChildren(content: NSAttributedString(), level: info.level)
                second.hiddenChildren = []
            }
        case .heading1, .heading2, .heading3, .quote:
            if !atEnd { second.info.type = info.type }
        default:
            break
        }
        if offset == 0, content.length > 0, info.type != .toggle {
            // Return at the start pushes the block down and leaves an empty one above.
            var empty = EditorBlock(info.type.isHeading || info.type == .quote ? .paragraph : info.type, level: info.level)
            if empty.info.type == .toggle { empty.hiddenChildren = [] }
            replaceParagraphs(index..<(index + 1), with: [empty, block], actionName: "Typing", caretBlock: 1)
            return
        }
        replaceParagraphs(index..<(index + 1), with: [first, second], actionName: "Typing", caretBlock: 1)
    }

    /// Shift-Return: a line break inside the block.
    func insertLineBreak() {
        guard let tv = textView else { return }
        let range = tv.selectedRange
        replace(range, with: NSAttributedString(string: EditorStyling.lineBreak, attributes: tv.typingAttributes),
                actionName: "Typing", selection: NSRange(location: range.location + 1, length: 0))
    }

    // MARK: - Backspace

    /// Backspace at the start of a block removes its format, outdents it, or
    /// removes an image / divider, instead of joining paragraphs.
    func handleDeleteBackward() -> Bool {
        guard let tv = textView, tv.selectedRange.length == 0, tv.markedTextRange == nil else { return false }
        let caret = tv.selectedRange.location
        if let slash, caret == slash.location + 1 { self.slash = nil; return false }
        let p = paragraph(at: caret)

        if p.isTrailing {
            guard trailingInfo != BlockInfo() else { return false }
            if trailingInfo.type != .paragraph {
                trailingInfo = BlockInfo(type: .paragraph, level: trailingInfo.level)
            } else {
                trailingInfo.level -= 1
            }
            syncTypingAttributes()
            tv.redrawDecorations()
            refreshState()
            tv.updateOverlays()
            return true
        }

        let s = tv.textStorage
        let info = EditorStyling.info(ofParagraph: p.range, in: s)
        guard let index = paragraphList.firstIndex(of: p.range) else { return false }

        if info.type.isAttachment {
            // Backspace on an image / divider removes the block.
            replaceParagraphs(index..<(index + 1), with: [EditorBlock(.paragraph, level: info.level)],
                              actionName: "Delete", caretBlock: 0)
            return true
        }
        guard caret == p.range.location else { return false }

        if info.type != .paragraph {
            setBlock(.paragraph)
            return true
        }
        if info.level > 1 {
            changeLevel(by: -1)
            return true
        }
        guard index > 0 else { return true }
        let blocks = documentBlocks
        let previous = blocks[index - 1]
        if previous.info.type.isAttachment {
            replaceParagraphs((index - 1)..<index, with: [], actionName: "Delete")
            tv.selectedRange = NSRange(location: paragraphList[max(index - 1, 0)].location, length: 0)
            return true
        }
        if previous.content.length == 0, previous.hiddenChildren == nil {
            // An empty block above: remove it, keep this block as it is.
            let range = paragraphList[index - 1]
            replace(range, with: NSAttributedString(), actionName: "Delete", selection: NSRange(location: range.location, length: 0))
            return true
        }
        // Join with the block above: its type wins.
        var joined = previous
        let text = NSMutableAttributedString(attributedString: previous.content)
        text.append(blocks[index].content)
        joined.content = text
        replaceParagraphs((index - 1)..<(index + 1), with: [joined], actionName: "Delete",
                          caretBlock: 0, caretOffset: previous.content.length)
        return true
    }

    // MARK: - Markdown shortcuts

    private func applyBlockShortcut(typed: String, at location: Int, paragraph p: (range: NSRange, isTrailing: Bool),
                                    info: BlockInfo) -> Bool {
        guard let s = storage, !p.isTrailing, info.type != .codeBlock else { return false }
        let prefixLength = location - p.range.location
        guard prefixLength > 0, prefixLength <= 4 else { return false }
        let prefix = (s.string as NSString).substring(with: NSRange(location: p.range.location, length: prefixLength))
        let contentLength = self.contentLength(p.range)

        var target: (RichBlockType, Bool)?
        if typed == " " {
            switch prefix {
            case "-", "*", "+": target = (.bulletList, false)
            case "[]", "[ ]": target = (.todo, false)
            case "[x]", "[X]": target = (.todo, true)
            case "#": target = (.heading1, false)
            case "##": target = (.heading2, false)
            case "###": target = (.heading3, false)
            case ">": target = (.toggle, false)
            case "\"", "“", "”", "|": target = (.quote, false)
            default:
                if prefix.count >= 2, prefix.dropLast().allSatisfy(\.isNumber), prefix.last == "." || prefix.last == ")" {
                    target = (.numberedList, false)
                }
            }
        } else if typed == "`", prefix == "``", contentLength == 2 {
            target = (.codeBlock, false)
        } else if typed == "-", prefix == "--", contentLength == 2, info.type == .paragraph {
            guard configuration.allowedBlocks.contains(.divider), let index = paragraphList.firstIndex(of: p.range) else { return false }
            replaceParagraphs(index..<(index + 1), with: [EditorBlock(.divider, level: info.level), EditorBlock(.paragraph, level: info.level)],
                              actionName: "Divider", caretBlock: 1)
            return true
        }
        guard let (type, checked) = target, configuration.allowedBlocks.contains(type),
              info.type == .paragraph || (info.type.hasMarker && type.hasMarker) || info.type.isHeading,
              let index = paragraphList.firstIndex(of: p.range) else { return false }

        var block = documentBlocks[index]
        block.content = block.content.attributedSubstring(from: NSRange(location: prefixLength, length: block.content.length - prefixLength))
        block.info = BlockInfo(type: type, level: info.level)
        block.info.checked = checked
        if type == .toggle { block.hiddenChildren = [] }
        if type == .codeBlock { block.content = NSAttributedString(string: block.content.string) }
        replaceParagraphs(index..<(index + 1), with: [block], actionName: type.title, caretBlock: 0)
        return true
    }

    private static let inlineMarkers: [(String, (inout InlineInfo) -> Void)] = [
        ("**", { $0.bold = true }), ("__", { $0.bold = true }), ("~~", { $0.strike = true }),
        ("*", { $0.italic = true }), ("_", { $0.italic = true }), ("~", { $0.strike = true }), ("`", { $0.code = true })
    ]

    /// `**bold**`, `*italic*`, `_italic_`, `~strike~`, `` `code` `` format when
    /// the closing marker is typed.
    private func applyInlineShortcut(typed: String, at location: Int, paragraph p: (range: NSRange, isTrailing: Bool)) -> Bool {
        guard let s = storage, !p.isTrailing, typed.count == 1, "*_~`".contains(typed) else { return false }
        let before = (s.string as NSString).substring(with: NSRange(location: p.range.location, length: location - p.range.location))

        for (marker, apply) in Self.inlineMarkers where marker.hasSuffix(typed) {
            let closingTyped = String(marker.dropLast())        // already in the text
            guard before.hasSuffix(closingTyped) else { continue }
            let body = String(before.dropLast(closingTyped.count))
            guard let open = body.range(of: marker, options: .backwards) else { continue }
            let inner = String(body[open.upperBound...])
            guard !inner.isEmpty, inner.first != " ", inner.last != " ", !inner.contains(marker) else { continue }
            // "***", "a*b": the opening marker must not continue a run or a word for _.
            if open.lowerBound > body.startIndex {
                let previous = body[body.index(before: open.lowerBound)]
                if String(previous) == String(marker.last!) { continue }
                if marker.hasPrefix("_"), previous.isLetter || previous.isNumber { continue }
            }

            let openLocation = p.range.location + (body[..<open.lowerBound] as Substring).utf16.count
            let markerLength = (marker as NSString).length
            let innerLength = (inner as NSString).length
            let fullRange = NSRange(location: openLocation, length: markerLength + innerLength + (closingTyped as NSString).length)
            let original = s.attributedSubstring(from: NSRange(location: openLocation + markerLength, length: innerLength))
            let formatted = NSMutableAttributedString()
            original.enumerateAttributes(in: NSRange(location: 0, length: original.length)) { attrs, r, _ in
                var inline = InlineInfo(attrs)
                apply(&inline)
                formatted.append(NSAttributedString(string: (original.string as NSString).substring(with: r),
                                                    attributes: EditorStyling.attributes(block: BlockInfo(attrs), inline: inline, style: style)))
            }
            replace(fullRange, with: formatted, actionName: "Format",
                    selection: NSRange(location: openLocation + formatted.length, length: 0))
            // Typing continues unformatted after the closing marker.
            if let tv = textView {
                tv.typingAttributes = EditorStyling.attributes(block: BlockInfo(tv.typingAttributes), inline: InlineInfo(), style: style)
            }
            return true
        }
        return false
    }

    // MARK: - Slash menu

    func updateSlashState() {
        guard let tv = textView else { return }
        let s = tv.textStorage.string as NSString
        if let location = pendingSlashLocation {
            pendingSlashLocation = nil
            if location < s.length, s.character(at: location) == 47 {
                var state = SlashState(location: location)
                state.results = RichEditorCommand.filter(RichEditorCommand.catalog(configuration), query: "")
                slash = state
                return
            }
        }
        guard var state = slash else { return }
        let caret = tv.selectedRange.location
        guard state.location < s.length, s.character(at: state.location) == 47, caret > state.location else {
            slash = nil
            return
        }
        let query = s.substring(with: NSRange(location: state.location + 1, length: caret - state.location - 1))
        if query.contains("\n") || query.contains(EditorStyling.lineBreak) || query.count > 30 {
            slash = nil
            return
        }
        let results = RichEditorCommand.filter(RichEditorCommand.catalog(configuration), query: query)
        if results.isEmpty, query.hasSuffix(" ") || query.count > state.lastMatchLength + 3 {
            slash = nil
            return
        }
        if !results.isEmpty { state.lastMatchLength = query.count }
        if query != state.query { state.selection = 0 }
        state.query = query
        state.results = results
        slash = state
    }

    func moveSlashSelection(by delta: Int) {
        guard var state = slash, !state.results.isEmpty else { return }
        state.selection = (state.selection + delta + state.results.count) % state.results.count
        slash = state
        textView?.updateOverlays()
    }

    func confirmSlashCommand() {
        guard let state = slash, state.selection < state.results.count else { slash = nil; return }
        run(state.results[state.selection])
    }

    func cancelSlashCommand() {
        slash = nil
        textView?.updateOverlays()
    }

    /// Opens the "/" menu: in the current block when it is empty, else in a
    /// new block below (the toolbar's "+").
    public func showCommandMenu() {
        guard let tv = textView, configuration.slashCommands else { return }
        if !tv.isFirstResponder { tv.becomeFirstResponder() }
        let p = currentParagraph
        if !p.isTrailing, contentLength(p.range) > 0, let index = paragraphList.firstIndex(of: p.range) {
            let level = EditorStyling.info(ofParagraph: p.range, in: tv.textStorage).level
            replaceParagraphs((index + 1)..<(index + 1), with: [EditorBlock(.paragraph, level: level)],
                              actionName: "Typing", caretBlock: 0)
        }
        tv.insertText("/")
    }

    /// Runs a menu command: removes the typed "/query", then acts on the block.
    public func run(_ command: RichEditorCommand) {
        guard let tv = textView else { return }
        if let state = slash {
            slash = nil
            let end = min(tv.selectedRange.location, tv.textStorage.length)
            if end > state.location {
                replace(NSRange(location: state.location, length: end - state.location), with: NSAttributedString(),
                        actionName: "Typing", selection: NSRange(location: state.location, length: 0))
            }
        }
        switch command.action {
        case .block(let type):
            if type == .image { tv.presentImagePicker() } else { setBlock(type) }
        case .imageFromURL: tv.presentImageURLPrompt()
        case .textColor(let color): setBlockColor(color)
        case .background(let color): setBlockColor(color, background: true)
        case .duplicate: duplicateBlock()
        case .delete: deleteBlock()
        case .moveUp: moveBlockUp()
        case .moveDown: moveBlockDown()
        }
        tv.updateOverlays()
    }
}
