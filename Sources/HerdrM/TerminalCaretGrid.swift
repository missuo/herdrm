import CoreGraphics
import Foundation

/// Maps between a terminal cell and an offset in the terminal's accessibility text, which is the
/// viewport read row by row and joined with "\n" (`InMemoryTerminalSession.readViewportText`).
///
/// Tools that work at the insertion point (inline autocomplete overlays, dictation) need both
/// directions: the cursor's offset for `AXSelectedTextRange`, so the text before it is the line
/// being typed, and a cell for any offset for `AXBoundsForRange`, so they can draw beside it.
///
/// A column is counted as one UTF-16 unit of the row's text. That holds for the single-width
/// characters prompt lines are made of; a row with wide glyphs (CJK, emoji) before the cursor
/// lands a little off. Offsets are clamped to their row, so they never spill into the next one.
enum TerminalCaretGrid {
    struct Cell: Equatable {
        var row: Int
        var column: Int
    }

    /// The cell whose top-left corner is at (`minX`, `minYFromTop`) in view space measured from the
    /// top. Ghostty's window padding is smaller than a cell, so flooring lands in the right cell.
    static func cell(minX: CGFloat, minYFromTop: CGFloat, cellWidth: CGFloat, cellHeight: CGFloat) -> Cell? {
        guard cellWidth > 0, cellHeight > 0, minX.isFinite, minYFromTop.isFinite else { return nil }
        return Cell(
            row: max(0, Int((minYFromTop / cellHeight).rounded(.down))),
            column: max(0, Int((minX / cellWidth).rounded(.down)))
        )
    }

    /// The offset in `text` of `cell`, clamped to the last row and to the end of its row: the
    /// viewport read drops a row's trailing blanks, so a cursor after typed spaces sits past it.
    static func offset(of cell: Cell, in text: String) -> Int {
        let rows = rowLengths(text)
        let row = min(max(cell.row, 0), rows.count - 1)
        let rowStart = rows[..<row].reduce(0) { $0 + $1 + 1 }
        return rowStart + min(max(cell.column, 0), rows[row])
    }

    /// The cell holding `offset` in `text`; an offset on a row's "\n" is the cell just past its end.
    static func cell(at offset: Int, in text: String) -> Cell {
        var remaining = max(offset, 0)
        let rows = rowLengths(text)
        for (index, length) in rows.enumerated() {
            if remaining <= length || index == rows.count - 1 {
                return Cell(row: index, column: min(remaining, length))
            }
            remaining -= length + 1
        }
        return Cell(row: 0, column: 0)
    }

    /// UTF-16 length of each row; never empty, since an empty viewport is one empty row.
    private static func rowLengths(_ text: String) -> [Int] {
        (text as NSString).components(separatedBy: "\n").map { ($0 as NSString).length }
    }
}
