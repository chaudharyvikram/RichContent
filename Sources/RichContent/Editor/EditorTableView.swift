import UIKit

/// Edits a table block in place: laid over the table's attachment by the
/// document's text view, it holds one editor per cell (`RichEditorTextView` +
/// `RichEditorController`, so every tool works in cells) over a grid, in a
/// scroll view for tables wider than the text.
final class EditorTableView: UIView {

    let attachment: RichTableAttachment
    private weak var document: RichEditorController?
    private let scrollView = UIScrollView()
    private let grid = EditorTableGridView()
    /// [row][column]
    private(set) var cells: [[RichEditorController]] = []
    /// The width the table is laid out for (the text width at the table).
    var availableWidth: CGFloat = 0 {
        didSet { if abs(availableWidth - oldValue) > 0.5 { setNeedsLayout() } }
    }

    init(attachment: RichTableAttachment, document: RichEditorController) {
        self.attachment = attachment
        self.document = document
        super.init(frame: .zero)
        backgroundColor = .clear
        scrollView.showsVerticalScrollIndicator = false
        scrollView.alwaysBounceVertical = false
        scrollView.alwaysBounceHorizontal = false
        scrollView.isScrollEnabled = true
        scrollView.backgroundColor = .clear
        addSubview(scrollView)
        grid.isUserInteractionEnabled = false
        scrollView.addSubview(grid)
        rebuildCells()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// (Re)creates the cell editors from the table, e.g. after rows or
    /// columns were added. Keeps focus on `focus` when given.
    func rebuildCells(focus: (row: Int, column: Int)? = nil) {
        let old = cells
        guard let document else { cells = []; old.joined().forEach { $0.textView?.removeFromSuperview() }; return }
        let table = attachment.table
        cells = table.rows.enumerated().map { r, row in
            row.enumerated().map { c, blocks in
                makeCell(row: r, column: c, blocks: blocks, header: table.hasHeaderRow && r == 0, document: document)
            }
        }
        setNeedsLayout()
        layoutIfNeeded()
        // Focus the new cell before the old ones go, so the keyboard stays up.
        if let focus, cells.indices.contains(focus.row), cells[focus.row].indices.contains(focus.column) {
            cells[focus.row][focus.column].focus()
        }
        for cell in old.joined() { cell.textView?.removeFromSuperview() }
    }

    private func makeCell(row: Int, column: Int, blocks: [EditorBlock], header: Bool,
                          document: RichEditorController) -> RichEditorController {
        let style = RichTableAttachment.cellStyle(document.style, header: header)
        var configuration = document.configuration
        configuration.showsBlockHandles = false        // no room for ⋮⋮ in a cell
        configuration.allowedBlocks.remove(.table)     // no tables in tables
        configuration.commandHint = ""
        let cell = RichEditorController(style: style, configuration: configuration)
        cell.imageUploader = document.imageUploader
        cell.onOpenURL = document.onOpenURL

        let textView = RichEditorTextView()
        textView.ownUndoManager = UndoManager()       // a cell's undo stays in the cell
        textView.isScrollEnabled = false
        textView.fixedInsets = RichTableAttachment.cellPadding
        textView.showsQuotedOriginal = false
        textView.minimumHeight = 0
        let padding = RichTableAttachment.cellPadding
        textView.onContentHeightChange = { [weak self] height in
            guard let self else { return }
            self.attachment.setMeasuredHeight(max(height - padding.top - padding.bottom, 0), row: row, column: column)
            self.setNeedsLayout()
        }
        cell.attach(textView, style: style)
        cell.setBlocks(blocks)
        // Linked after loading, so loading isn't reported as an edit.
        cell.parentEditor = document
        cell.tableAttachment = attachment
        cell.tableCell = (row, column)
        scrollView.addSubview(textView)
        return cell
    }

    /// Row and column of a cell's editor.
    func position(of controller: RichEditorController) -> (row: Int, column: Int)? {
        for (r, row) in cells.enumerated() {
            if let c = row.firstIndex(where: { $0 === controller }) { return (r, c) }
        }
        return nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let layout = attachment.layout(forWidth: availableWidth > 0 ? availableWidth : bounds.width)
        scrollView.frame = bounds
        // Clip only when the table scrolls sideways, so a cell's "/" menu and
        // selection bar can reach outside a table that fits.
        scrollView.clipsToBounds = layout.width > bounds.width + 0.5
        scrollView.contentSize = CGSize(width: layout.width, height: layout.height)
        grid.frame = CGRect(x: 0, y: 0, width: layout.width, height: layout.height)
        grid.update(layout: layout, hasHeaderRow: attachment.table.hasHeaderRow)
        for (r, row) in cells.enumerated() where r < layout.rowHeights.count {
            for (c, cell) in row.enumerated() where c < layout.columns {
                cell.textView?.frame = layout.cellRect(row: r, column: c)
            }
        }
    }
}

/// The table's header tint and borders, under the cell editors.
final class EditorTableGridView: UIView {
    private var layout: RichTableAttachment.Layout?
    private var hasHeaderRow = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        contentMode = .redraw
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(layout: RichTableAttachment.Layout, hasHeaderRow: Bool) {
        guard layout != self.layout || hasHeaderRow != self.hasHeaderRow else { return }
        self.layout = layout
        self.hasHeaderRow = hasHeaderRow
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let layout else { return }
        RichTableAttachment.drawGrid(layout, hasHeaderRow: hasHeaderRow, in: bounds)
    }
}

// MARK: - Placing table editors in the document

extension RichEditorTextView {

    /// The document changed: table blocks may have moved, appeared or gone.
    func tablesDidChange() {
        tableRanges = nil
        setNeedsLayout()
    }

    /// Lays an `EditorTableView` over every table block (and removes the
    /// ones whose table is gone). Called from `layoutSubviews`.
    func layoutTables() {
        guard let document = editorController else { return }
        if tableRanges == nil {
            var found: [(RichTableAttachment, NSRange)] = []
            let s = textStorage
            s.enumerateAttribute(.attachment, in: NSRange(location: 0, length: s.length)) { value, range, _ in
                if let table = value as? RichTableAttachment { found.append((table, range)) }
            }
            tableRanges = found
        }
        let ranges = tableRanges ?? []
        guard !ranges.isEmpty || !tableViews.isEmpty else { return }

        var present = Set<ObjectIdentifier>()
        for (table, range) in ranges where NSMaxRange(range) <= textStorage.length {
            let id = ObjectIdentifier(table)
            present.insert(id)
            let view: EditorTableView
            if let existing = tableViews[id] {
                view = existing
            } else {
                view = EditorTableView(attachment: table, document: document)
                tableViews[id] = view
                addSubview(view)
                table.showsCellEditors(true)
            }
            layoutManager.ensureLayout(forCharacterRange: range)
            let glyph = layoutManager.glyphIndexForCharacter(at: range.location)
            let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let location = layoutManager.location(forGlyphAt: glyph)
            let size = layoutManager.attachmentSize(forGlyphAt: glyph)
            guard size.width > 0, size.height > 0 else { continue }
            // The attachment sits on the baseline (its bounds start at y = 0).
            view.frame = CGRect(x: textContainerInset.left + line.minX + location.x,
                                y: textContainerInset.top + line.minY + location.y - size.height,
                                width: size.width, height: size.height)
            view.availableWidth = table.lastAvailableWidth ?? size.width
        }
        for (id, view) in tableViews where !present.contains(id) {
            view.attachment.showsCellEditors(false)
            view.removeFromSuperview()
            tableViews[id] = nil
        }
    }

    /// The table editor under `point` (text view coordinates), if any.
    func tableView(at point: CGPoint) -> EditorTableView? {
        tableViews.values.first { $0.frame.contains(point) }
    }
}
