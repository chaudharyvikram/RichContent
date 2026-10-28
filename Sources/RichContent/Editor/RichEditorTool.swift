import UIKit

/// A button in the format bar (`RichEditorToolbar` / `.richEditorToolbar`).
/// Pass the ones to show, in order, to `RichEditorConfiguration.toolbarTools`
/// or `.richEditorToolbar(editor, tools:)`; separators go in between groups.
///
/// ```swift
/// config.toolbarTools = [.bold, .italic, .underline, .link, .bulletList, .numberedList, .image, .hideKeyboard]
/// config.toolbarTools = .basic   // or .all (the default)
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
    /// Inserts a table (needs `.table` in `allowedBlocks`); inside a table,
    /// a menu for rows, columns and the header row.
    case table
    case undo, redo
    /// Dismisses the keyboard; pinned at the trailing end.
    case hideKeyboard

    /// Separators are drawn where this changes.
    var group: Int {
        switch self {
        case .addBlock, .turnInto: return 0
        case .bold, .italic, .underline, .strikethrough, .code, .link, .color: return 1
        case .todo, .bulletList, .numberedList, .toggle, .outdent, .indent: return 2
        case .image, .table: return 3
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

/// A format-bar icon: an SF Symbol, an image from an asset catalog, or a
/// `UIImage`. Images are drawn as templates (tinted like the built-in icons).
public enum RichEditorToolIcon: Hashable {
    case system(String)
    case asset(String, bundle: Bundle? = nil)
    case image(UIImage)
}

public extension RichEditorTool {
    /// The built-in icon (override with `RichEditorConfiguration.toolbarIcons`).
    var defaultIcon: RichEditorToolIcon {
        switch self {
        case .addBlock: return .system("plus")
        case .turnInto: return .system("textformat")
        case .bold, .italic, .underline, .strikethrough, .code: return .system(inlineFormat!.symbolName)
        case .link: return .system("link")
        case .color: return .system("paintpalette")
        case .todo, .bulletList, .numberedList, .toggle: return .system(blockType!.symbolName)
        case .outdent: return .system("decrease.indent")
        case .indent: return .system("increase.indent")
        case .image: return .system("photo")
        case .table: return .system("tablecells")
        case .undo: return .system("arrow.uturn.backward")
        case .redo: return .system("arrow.uturn.forward")
        case .hideKeyboard: return .system("keyboard.chevron.compact.down")
        }
    }

    /// The built-in name, used for VoiceOver and the long-press tooltip
    /// (override with `RichEditorConfiguration.toolbarLabels`).
    var defaultLabel: String {
        switch self {
        case .addBlock: return "Add block"
        case .turnInto: return "Turn into"
        case .bold, .italic, .underline, .strikethrough, .code: return inlineFormat!.title
        case .link: return "Link"
        case .color: return "Color"
        case .todo, .bulletList, .numberedList, .toggle: return blockType!.title
        case .outdent: return "Outdent"
        case .indent: return "Indent"
        case .image: return "Image"
        case .table: return "Table"
        case .undo: return "Undo"
        case .redo: return "Redo"
        case .hideKeyboard: return "Hide keyboard"
        }
    }
}

/// Ready-made tool lists: `config.toolbarTools = .all` or `.basic`.
public extension Array where Element == RichEditorTool {
    /// Every tool, in the default order.
    static var all: [RichEditorTool] { RichEditorTool.allCases }

    /// Text styling only.
    static var basic: [RichEditorTool] { [.bold, .italic, .underline, .strikethrough, .link, .hideKeyboard] }
}
