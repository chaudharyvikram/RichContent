import UIKit

/// Format-neutral block, the bridge between the text storage and HTML /
/// Markdown / plain text. Nesting is expressed by `info.level` in a flat list
/// (a block's children are the following blocks with a deeper level).
struct EditorBlock {
    var info: BlockInfo
    /// Inline text with semantic attributes only (`InlineInfo.keys`).
    /// Line breaks inside a block are U+2028.
    var content: NSAttributedString
    var image: EditorImage?
    /// Collapsed toggle: the hidden child blocks (absolute levels).
    var hiddenChildren: [EditorBlock]?

    init(_ type: RichBlockType, level: Int = 1, content: NSAttributedString = NSAttributedString()) {
        info = BlockInfo(type: type, level: level)
        self.content = content
    }

    init(_ type: RichBlockType, level: Int = 1, text: String) {
        self.init(type, level: level, content: NSAttributedString(string: text))
    }

    var text: String { content.string }
}

struct EditorImage: Equatable {
    var source: String
    var alt: String = ""
    var size: CGSize?
}

/// Converts between `[EditorBlock]` and the editor's attributed string.
@MainActor
enum EditorDocument {

    // MARK: Blocks → text storage

    static func attributedString(from blocks: [EditorBlock], style: RichContentStyle) -> NSMutableAttributedString {
        let result = NSMutableAttributedString()
        for (index, block) in blocks.enumerated() {
            var info = block.info
            info.collapsed = nil
            if info.type == .toggle, let hidden = block.hiddenChildren {
                info.collapsed = RichToggleChildren(content: attributedString(from: hidden, style: style), level: info.level)
            }
            let piece = NSMutableAttributedString()
            switch info.type {
            case .image:
                let image = block.image ?? EditorImage(source: "")
                var a = EditorStyling.attributes(block: info, inline: InlineInfo(), style: style)
                a[.attachment] = RichImageAttachment(source: image.source, alt: image.alt, size: image.size)
                piece.append(NSAttributedString(string: EditorStyling.attachmentCharacter, attributes: a))
            case .divider:
                var a = EditorStyling.attributes(block: info, inline: InlineInfo(), style: style)
                a[.attachment] = RichDividerAttachment()
                piece.append(NSAttributedString(string: EditorStyling.attachmentCharacter, attributes: a))
            default:
                block.content.enumerateAttributes(in: NSRange(location: 0, length: block.content.length)) { attrs, r, _ in
                    let text = (block.content.string as NSString).substring(with: r)
                        .replacingOccurrences(of: "\n", with: EditorStyling.lineBreak)
                    piece.append(NSAttributedString(
                        string: text, attributes: EditorStyling.attributes(block: info, inline: InlineInfo(attrs), style: style)))
                }
            }
            if index < blocks.count - 1 {
                piece.append(NSAttributedString(
                    string: "\n", attributes: EditorStyling.attributes(block: info, inline: InlineInfo(), style: style)))
            }
            result.append(piece)
        }
        return result
    }

    /// Info of the empty line after the text when the last block is empty:
    /// such a block has no characters to carry its type.
    static func trailingInfo(of blocks: [EditorBlock], style: RichContentStyle) -> BlockInfo? {
        guard let last = blocks.last, last.content.length == 0, !last.info.type.isAttachment else { return nil }
        var info = last.info
        info.collapsed = nil
        if info.type == .toggle, let hidden = last.hiddenChildren {
            info.collapsed = RichToggleChildren(content: attributedString(from: hidden, style: style), level: info.level)
        }
        return info
    }

    // MARK: Text storage → blocks

    static func blocks(from s: NSAttributedString) -> [EditorBlock] {
        let ns = s.string as NSString
        var result: [EditorBlock] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length),
                               options: [.byParagraphs, .substringNotRequired]) { _, content, enclosing, _ in
            var info = EditorStyling.info(in: s, at: enclosing.location)
            let collapsed = info.collapsed
            info.collapsed = nil
            var block = EditorBlock(info.type, level: info.level)
            block.info = info

            if info.type.isAttachment {
                if let r = EditorStyling.attachmentRange(inParagraph: enclosing, of: s),
                   let image = s.attribute(.attachment, at: r.location, effectiveRange: nil) as? RichImageAttachment {
                    block.image = EditorImage(source: image.source, alt: image.alt, size: image.naturalSize)
                } else if info.type == .image {
                    block.info.type = .paragraph
                }
            } else {
                block.content = semanticContent(of: s, in: content)
            }
            if let collapsed {
                let delta = info.level - collapsed.level
                block.hiddenChildren = blocks(from: collapsed.content).map { child in
                    var child = child
                    child.info.level = max(child.info.level + delta, 1)
                    return child
                }
            }
            result.append(block)
        }
        return result
    }

    /// The inline semantic attributes of `range`, attachment characters removed.
    static func semanticContent(of s: NSAttributedString, in range: NSRange) -> NSAttributedString {
        let out = NSMutableAttributedString()
        guard range.length > 0 else { return out }
        s.enumerateAttributes(in: range) { attrs, r, _ in
            guard attrs[.attachment] == nil else { return }
            let text = (s.string as NSString).substring(with: r)
            out.append(NSAttributedString(string: text, attributes: InlineInfo(attrs).attributes))
        }
        return out
    }

    // MARK: Toggles

    /// Hides the children of the toggle paragraph `p` in a `RichToggleChildren`.
    /// Returns the range of `s` that changed (before → after lengths differ).
    @discardableResult
    static func collapseToggle(paragraph p: NSRange, in s: NSMutableAttributedString) -> NSRange {
        let info = EditorStyling.info(ofParagraph: p, in: s)
        guard info.type == .toggle, info.collapsed == nil else { return NSRange(location: p.location, length: 0) }
        let children = EditorStyling.childrenRange(of: p, in: s)
        var hidden = s.attributedSubstring(from: children)
        var removal = children
        if children.length > 0 {
            if NSMaxRange(children) == s.length, !s.string.hasSuffix("\n") {
                // Last children: take the toggle's own line break with them.
                removal = NSRange(location: children.location - 1, length: children.length + 1)
            } else if hidden.string.hasSuffix("\n") {
                hidden = hidden.attributedSubstring(from: NSRange(location: 0, length: hidden.length - 1))
            }
        }
        let stash = RichToggleChildren(content: hidden, level: info.level)
        s.replaceCharacters(in: removal, with: "")
        let title = NSRange(location: p.location, length: min(p.length, s.length - p.location))
        s.addAttribute(.richToggleChildren, value: stash, range: title)
        return NSRange(location: p.location, length: title.length)
    }

    /// Re-inserts the hidden children of a collapsed toggle paragraph `p`.
    @discardableResult
    static func expandToggle(paragraph p: NSRange, in s: NSMutableAttributedString, style: RichContentStyle) -> NSRange {
        let info = EditorStyling.info(ofParagraph: p, in: s)
        guard info.type == .toggle, let stash = info.collapsed else { return NSRange(location: p.location, length: 0) }
        s.removeAttribute(.richToggleChildren, range: p)

        let content = NSMutableAttributedString(attributedString: stash.content)
        let delta = info.level - stash.level
        if delta != 0 {
            for r in EditorStyling.paragraphRanges(in: content) {
                let level = EditorStyling.info(in: content, at: r.location).level
                content.addAttribute(.richListLevel, value: max(level + delta, 1), range: r)
            }
        }
        guard content.length > 0 else { return p }

        let toggleEnd = NSMaxRange(p)
        let endsWithBreak = toggleEnd > 0 && (s.string as NSString).character(at: toggleEnd - 1) == 10
        let insertion = NSMutableAttributedString()
        var location = toggleEnd
        if endsWithBreak {
            insertion.append(content)
            if !content.string.hasSuffix("\n") {
                let attrs = content.attributes(at: content.length - 1, effectiveRange: nil)
                insertion.append(NSAttributedString(string: "\n", attributes: attrs))
            }
        } else {
            let attrs = s.attributes(at: max(toggleEnd - 1, 0), effectiveRange: nil)
            insertion.append(NSAttributedString(string: "\n", attributes: attrs))
            insertion.append(content)
            location = toggleEnd
        }
        s.insert(insertion, at: location)
        let changed = NSRange(location: p.location, length: p.length + insertion.length)
        EditorStyling.normalize(s, in: changed, style: style)
        return changed
    }
}
