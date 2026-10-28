import Foundation

/// A button in the format bar (`RichEditorToolbar` / `.richEditorToolbar`).
/// Pass the ones to show, in order, to `RichEditorConfiguration.toolbarTools`
/// or `.richEditorToolbar(editor, tools:)`; separators go in between groups.
///
/// ```swift
/// config.toolbarTools = [.bold, .italic, .underline, .link, .bulletList, .numberedList, .image, .hideKeyboard]
/// ```
public enum RichEditorTool: String, Hashable, CaseIterable, Sendable {
    /// "+": the block menu (needs `slashCommands`).
    case addBlock
    /// "Aa": turn the block into a heading, quote, list, …
    case turnInto
    case bold, italic, underline, strikethrough, code
    case link
    /// Text and background colors.
    case color
    case todo, bulletList, numberedList, toggle
    case outdent, indent
    /// Photo library (needs `.image` in `allowedBlocks`).
    case image
    case undo, redo
    /// Dismisses the keyboard; pinned at the trailing end.
    case hideKeyboard

    /// Every tool, in the default order.
    public static let all: [RichEditorTool] = allCases

    /// Text styling only.
    public static let basic: [RichEditorTool] = [.bold, .italic, .underline, .strikethrough, .link, .hideKeyboard]

    /// Separators are drawn where this changes.
    var group: Int {
        switch self {
        case .addBlock, .turnInto: return 0
        case .bold, .italic, .underline, .strikethrough, .code, .link, .color: return 1
        case .todo, .bulletList, .numberedList, .toggle, .outdent, .indent: return 2
        case .image: return 3
        case .undo, .redo: return 4
        case .hideKeyboard: return 5
        }
    }

    var inlineFormat: RichInlineFormat? {
        switch self {
        case .bold: return .bold
        case .italic: return .italic
        case .underline: return .underline
        case .strikethrough: return .strikethrough
        case .code: return .code
        default: return nil
        }
    }

    var blockType: RichBlockType? {
        switch self {
        case .todo: return .todo
        case .bulletList: return .bulletList
        case .numberedList: return .numberedList
        case .toggle: return .toggle
        default: return nil
        }
    }
}
