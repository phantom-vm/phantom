import AppKit
import SwiftUI

/// The log list, as an `NSTableView`.
///
/// SwiftUI's `List` is already NSTableView-backed on macOS, so this is not a change of
/// engine — it is a change of control, and the control that matters is **update
/// granularity**. `List` hands its whole collection to the diffing machinery on every
/// change: to discover ten appended lines it compares every identifier in the buffer,
/// which is O(buffer) per append and a ceiling no constant-factor tuning moves.
///
/// `LogBuffer` only ever appends at the tail and trims from the head, and its ids are
/// monotonic. That makes the difference between two states fully determined by the
/// first id, the last id and the count — so this needs no diffing algorithm at all,
/// just `removeRows` for what was trimmed and `insertRows` for what arrived. O(changed).
///
/// The rest of the reason to own the table:
///
/// - **No text measurement.** `rowHeight` is set explicitly and cells truncate rather
///   than wrap, so laying out the list never depends on the length of a line.
/// - **Recycled cells.** One reused `NSTextField` per visible row, instead of a SwiftUI
///   view graph per row.
/// - **Follow the tail, unless the reader scrolled up.** Every usable log viewer does
///   this, and it cannot be expressed with `defaultScrollAnchor(.bottom)`: whether to
///   stick to the bottom depends on where the reader currently is.
struct LogTableView: NSViewRepresentable {
    let lines: [LogBuffer.Line]
    @Binding var selection: LogBuffer.Line.ID?

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.rowSizeStyle = .custom
        table.rowHeight = Coordinator.rowHeight
        table.usesAlternatingRowBackgroundColors = false
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.intercellSpacing = NSSize(width: 0, height: 1)
        table.dataSource = context.coordinator
        table.delegate = context.coordinator

        let column = NSTableColumn(identifier: Coordinator.columnID)
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)

        let scrollView = NSScrollView()
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        context.coordinator.table = table
        context.coordinator.scrollView = scrollView
        context.coordinator.apply(lines)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.selectionBinding = $selection
        context.coordinator.apply(lines)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        static let rowHeight: CGFloat = 15
        static let columnID = NSUserInterfaceItemIdentifier("line")

        fileprivate var table: NSTableView?
        fileprivate var scrollView: NSScrollView?

        var selectionBinding: Binding<LogBuffer.Line.ID?>

        /// The table's own copy of what it is showing. `apply` reconciles this with the
        /// incoming buffer; `numberOfRows` and the cell factory read only this, so the
        /// table's view of the world is never half-updated.
        private var rows: [LogBuffer.Line] = []

        /// Cached so recognising "nothing changed" costs a comparison of two integers
        /// rather than a walk of the whole array.
        private var rowsFirstID: Int? { rows.first?.id }

        /// Set while `apply` is changing the selection so the delegate callback does not
        /// write that change back as if the user had made it.
        private var applyingSelection = false

        init(selection: Binding<LogBuffer.Line.ID?>) {
            self.selectionBinding = selection
        }

        // MARK: Reconciling

        func apply(_ incoming: [LogBuffer.Line]) {
            guard let table else { return }

            // Comparing the arrays themselves would be O(buffer) on every render, which
            // is the cost this whole type exists to avoid. First id and count identify a
            // LogBuffer state completely, because its ids are contiguous and its entries
            // immutable.
            let incomingFirstID = incoming.first?.id
            guard incomingFirstID != rowsFirstID || incoming.count != rows.count else { return }

            guard let plan = ChangePlan(
                oldFirstID: rowsFirstID,
                oldCount: rows.count,
                newFirstID: incomingFirstID,
                newCount: incoming.count
            ) else {
                // A cleared or restarted buffer: correct to reload, and rare.
                rows = incoming
                table.reloadData()
                restoreSelection()
                return
            }

            let wasAtBottom = isScrolledToBottom
            rows = incoming

            table.beginUpdates()
            if plan.trimmedFromHead > 0 {
                table.removeRows(at: IndexSet(integersIn: 0..<plan.trimmedFromHead), withAnimation: [])
            }
            if plan.appendedAtTail > 0 {
                let start = rows.count - plan.appendedAtTail
                table.insertRows(at: IndexSet(integersIn: start..<rows.count), withAnimation: [])
            }
            table.endUpdates()

            // Trimming shifts row indices, so a kept selection has to be re-applied.
            if plan.trimmedFromHead > 0 {
                restoreSelection()
            }

            // Only chase the tail if the reader was already there. Someone who has
            // scrolled up to read something must not be yanked back by the next line.
            if wasAtBottom, !rows.isEmpty {
                table.scrollRowToVisible(rows.count - 1)
            }
        }

        private var isScrolledToBottom: Bool {
            guard let scrollView, let table, !rows.isEmpty else { return true }
            let visible = scrollView.contentView.documentVisibleRect
            let contentHeight = table.bounds.height
            // Within one row of the end counts as "at the bottom", so the view keeps
            // following while lines stream in and nudge the offset.
            return visible.maxY >= contentHeight - Self.rowHeight * 2
        }

        private func restoreSelection() {
            guard let table else { return }
            applyingSelection = true
            defer { applyingSelection = false }

            if let id = selectionBinding.wrappedValue,
               let row = rows.firstIndex(where: { $0.id == id }) {
                table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            } else {
                table.deselectAll(nil)
            }
        }

        // MARK: NSTableViewDataSource

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        // MARK: NSTableViewDelegate

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row < rows.count else { return nil }

            let field: NSTextField
            if let reused = tableView.makeView(withIdentifier: Self.columnID, owner: self) as? NSTextField {
                field = reused
            } else {
                field = NSTextField(labelWithString: "")
                field.identifier = Self.columnID
                field.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
                field.lineBreakMode = .byTruncatingTail
                field.usesSingleLineMode = true
                field.cell?.truncatesLastVisibleLine = true
                field.isBezeled = false
                field.drawsBackground = false
            }
            field.stringValue = rows[row].text
            return field
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !applyingSelection, let table else { return }
            let row = table.selectedRow
            selectionBinding.wrappedValue = rows.indices.contains(row) ? rows[row].id : nil
        }
    }
}

// MARK: - Change Plan

/// How one `LogBuffer` state differs from the previous one.
///
/// `LogBuffer` ids are **contiguous**: `nextID` rises by one per append and trimming only
/// removes from the head, so the retained lines are always a contiguous id range. That
/// makes the whole difference derivable from each state's first id and count — no array
/// is scanned and no element is compared, so this is O(1) rather than O(buffer). It is
/// also why there is no "did the middle change" question to get wrong: the line with a
/// given id is immutable, since nothing in `LogBuffer` rewrites an existing entry.
///
/// `nil` when the two states cannot be related by trimming and appending — the buffer was
/// cleared, or `removeAll` restarted it — in which case the caller reloads instead.
struct ChangePlan: Equatable {
    let trimmedFromHead: Int
    let appendedAtTail: Int

    init?(oldFirstID: Int?, oldCount: Int, newFirstID: Int?, newCount: Int) {
        // Nothing was showing: everything present is an append.
        guard let oldFirstID, oldCount > 0 else {
            trimmedFromHead = 0
            appendedAtTail = newCount
            return
        }
        // Everything went away, or the buffer restarted below the old range.
        guard let newFirstID, newCount > 0, newFirstID >= oldFirstID else { return nil }

        let trimmed = newFirstID - oldFirstID
        let kept = oldCount - trimmed
        // A trim cannot remove more than was there, and the tail never shrinks.
        guard kept >= 0, newCount >= kept else { return nil }

        trimmedFromHead = trimmed
        appendedAtTail = newCount - kept
    }

    init?(from old: [LogBuffer.Line], to new: [LogBuffer.Line]) {
        self.init(
            oldFirstID: old.first?.id,
            oldCount: old.count,
            newFirstID: new.first?.id,
            newCount: new.count
        )
    }
}
