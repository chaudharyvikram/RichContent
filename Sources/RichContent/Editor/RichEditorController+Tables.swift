import UIKit

extension RichEditorController {

    /// The editor the caret is in: a table cell's editor while a cell is
    /// being edited, otherwise this one. Custom toolbars should send
    /// formatting to it (`RichEditorToolbar` does).
    public var focusedEditor: RichEditorController { activeCellEditor ?? self }

    /// Focus moved between the document and its cells; settle `isFocused`
    /// and `activeCellEditor` once the new first responder is in place.
    func refreshFocus() {
        let cellFocused = activeCellEditor?.textView?.isFirstResponder == true
        if activeCellEditor != nil, !cellFocused { activeCellEditor = nil }
        let focused = (textView?.isFirstResponder ?? false) || cellFocused
        if isFocused != focused { isFocused = focused }
    }

    // MARK: Table cells (called by a cell's editor on its document's editor)

    func cellDidBeginEditing(_ cell: RichEditorController) {
        activeCellEditor = cell
        if !isFocused { isFocused = true }
    }

    func cellDidEndEditing(_ cell: RichEditorController) {
        DispatchQueue.main.async { [weak self] in self?.refreshFocus() }
    }

    /// A cell was edited: store its blocks in the table and report the change.
    func cellContentDidChange(_ cell: RichEditorController) {
        guard let attachment = cell.tableAttachment, let position = cell.tableCell else { return }
        attachment.setCell(row: position.row, column: position.column,
                           blocks: EditorDocument.blocks(from: cell.attributedText))
        textView?.setNeedsLayout()
        onChange?(self)
    }
}

// MARK: - Table structure

extension RichEditorController {

    /// `true` while the caret is in a table cell.
    public var isInTable: Bool { tableTarget != nil }

    /// Whether the table being edited has a header row.
    public var tableHasHeaderRow: Bool { tableTarget?.attachment.table.hasHeaderRow ?? false }

    /// Inserts an empty table (with a header row) below the current block
    /// and puts the caret in its first cell.
    public func insertTable(rows: Int = 3, columns: Int = 3) {
        guard parentEditor == nil, configuration.allowedBlocks.contains(.table), let tv = textView else { return }
        var block = EditorBlock(.table, level: info(ofParagraphAt: selectedRange.location).level)
        block.table = .empty(rows: rows, columns: columns)
        let existing = Set(tv.tableViews.keys)
        insertAttachmentBlock(block, actionName: "Table")
        tv.layoutIfNeeded()
        tv.tableViews.first { !existing.contains($0.key) }?.value.cells.first?.first?.focus()
    }

    /// Adds a row below (or above) the caret's row and moves the caret into it.
    public func insertTableRow(below: Bool = true) {
        editTable("Insert Row") { table, focus in
            let row = below ? focus.row + 1 : focus.row
            table.insertRow(at: row)
            focus.row = row
        }
    }

    /// Adds a column right (or left) of the caret's column and moves the caret into it.
    public func insertTableColumn(right: Bool = true) {
        editTable("Insert Column") { table, focus in
            let column = right ? focus.column + 1 : focus.column
            table.insertColumn(at: column)
            focus.column = column
        }
    }

    /// Deletes the caret's row (the whole table when it is the only row).
    public func deleteTableRow() {
        guard let target = tableTarget else { return }
        guard target.attachment.table.rowCount > 1 else { deleteTable(); return }
        editTable("Delete Row") { table, focus in
            table.removeRow(at: focus.row)
            focus.row = min(focus.row, table.rowCount - 1)
        }
    }

    /// Deletes the caret's column (the whole table when it is the only column).
    public func deleteTableColumn() {
        guard let target = tableTarget else { return }
        guard target.attachment.table.columnCount > 1 else { deleteTable(); return }
        editTable("Delete Column") { table, focus in
            table.removeColumn(at: focus.column)
            focus.column = min(focus.column, table.columnCount - 1)
        }
    }

    /// Turns the first row into a header row, or back into a normal row.
    public func toggleTableHeaderRow() {
        editTable("Header Row") { table, _ in table.hasHeaderRow.toggle() }
    }

    /// Deletes the table being edited; the caret goes back to the document.
    public func deleteTable() {
        guard let target = tableTarget, let tv = target.root.textView,
              let range = target.root.range(of: target.attachment) else { return }
        tv.becomeFirstResponder()
        target.root.activeCellEditor = nil
        tv.selectedRange = NSRange(location: range.location, length: 0)
        target.root.deleteBlock()
    }

    /// Tab / Shift-Tab in a cell: the next / previous cell. Tab in the last
    /// cell adds a row. `false` when this isn't a cell.
    func moveToAdjacentCell(forward: Bool) -> Bool {
        guard let target = tableTarget, let view = target.root.tableView(for: target.attachment) else { return false }
        let table = target.attachment.table
        let index = target.row * table.columnCount + target.column + (forward ? 1 : -1)
        if index < 0 { return true }
        if index >= table.rowCount * table.columnCount {
            editTable("Insert Row") { table, focus in
                table.insertRow(at: table.rowCount)
                focus = (table.rowCount - 1, 0)
            }
            return true
        }
        let cell = view.cells[index / table.columnCount][index % table.columnCount]
        cell.focus()
        if let tv = cell.textView { tv.selectedRange = NSRange(location: 0, length: tv.textStorage.length) }
        return true
    }

    // MARK: Helpers

    /// The table cell being edited: from the document's editor or a cell's.
    private var tableTarget: (root: RichEditorController, attachment: RichTableAttachment, row: Int, column: Int)? {
        let root = parentEditor ?? self
        let cell = parentEditor == nil ? activeCellEditor : Optional(self)
        guard let cell, let attachment = cell.tableAttachment, let position = cell.tableCell else { return nil }
        return (root, attachment, position.row, position.column)
    }

    private func editTable(_ actionName: String, _ change: (inout EditorTable, inout (row: Int, column: Int)) -> Void) {
        guard let target = tableTarget else { return }
        var table = target.attachment.table
        var focus = (row: target.row, column: target.column)
        change(&table, &focus)
        table.normalize()
        target.root.setTable(table, of: target.attachment, focus: focus, actionName: actionName)
    }

    /// Replaces a table's content (undoable) and rebuilds its cell editors.
    func setTable(_ table: EditorTable, of attachment: RichTableAttachment,
                  focus: (row: Int, column: Int)?, actionName: String) {
        let old = attachment.table
        if let undoManager = textView?.undoManager {
            undoManager.registerUndo(withTarget: self) { target in
                target.setTable(old, of: attachment, focus: nil, actionName: actionName)
            }
            undoManager.setActionName(actionName)
        }
        attachment.update(table: table)
        let view = tableView(for: attachment)
        view?.rebuildCells(focus: focus)
        // The cell editors were replaced: point at the new one (its focus
        // reports the same once it lands) or at none.
        if activeCellEditor?.tableAttachment === attachment {
            if let focus, let view, view.cells.indices.contains(focus.row), view.cells[focus.row].indices.contains(focus.column) {
                activeCellEditor = view.cells[focus.row][focus.column]
            } else {
                activeCellEditor = nil
            }
        }
        textView?.setNeedsLayout()
        objectWillChange.send()     // the toolbar's table menu (header row)
        onChange?(self)
    }

    func tableView(for attachment: RichTableAttachment) -> EditorTableView? {
        textView?.tableViews[ObjectIdentifier(attachment)]
    }

    /// Where `attachment` is in this editor's document.
    func range(of attachment: NSTextAttachment) -> NSRange? {
        guard let s = textView?.textStorage else { return nil }
        var found: NSRange?
        s.enumerateAttribute(.attachment, in: NSRange(location: 0, length: s.length)) { value, range, stop in
            if (value as AnyObject?) === attachment { found = range; stop.pointee = true }
        }
        return found
    }
}
