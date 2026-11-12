import Foundation

/// A rectangle of terminal cells; row and column count from the viewport's top-left.
struct CellRect: Equatable {
    var row: Int
    var column: Int
    var rows: Int
    var columns: Int
}

/// One of the bordered `#N` boxes Claude Code draws above its prompt for a pasted image.
struct ClaudeImageBox: Equatable {
    var number: Int
    /// Picture cells inside the frame: excludes the border and the `#N` label row.
    var interior: CellRect
}

/// Finds Claude Code's image boxes in the terminal's viewport text, which is the viewport read
/// row by row and joined with "\n" (`InMemoryTerminalSession.readViewportText`).
///
/// A box is a rounded frame (`╭─╮`, `│ │`, `╰─╯`) whose last interior row is a `#N` label. The
/// picture cells hold kitty placeholders that read as blanks or half blocks, so only the frame
/// and the label identify a box. Detection starts from each bottom border and walks up. Columns
/// are counted in characters, which matches cells for the single-width glyphs a box is made of.
///
/// A box counts only when Claude's prompt line sits just below it, naming the same attachment
/// (`❯ [Image #1] [Image #2]`), so a box diagram quoted in the transcript is not mistaken for one.
enum ClaudeImageBoxes {
    /// How many rows below a box's bottom border the prompt line may sit. Claude draws a blank row
    /// and its separator in between, so the prompt is three rows down.
    static let promptSearchRows = 6

    /// Boxes in `viewportText`, left to right, top to bottom.
    static func boxes(in viewportText: String) -> [ClaudeImageBox] {
        let lines = viewportText.split(separator: "\n", omittingEmptySubsequences: false)
        let rows = lines.map(Array.init)
        var found: [ClaudeImageBox] = []
        for (r, row) in rows.enumerated() where r >= 1 {
            for c in row.indices where row[c] == "╰" {
                guard let box = box(bottomRow: r, left: c, in: rows) else { continue }
                let token = "[Image #\(box.number)]"
                let below = lines.dropFirst(r + 1).prefix(promptSearchRows)
                if below.contains(where: { $0.contains(token) }) { found.append(box) }
            }
        }
        return found.sorted {
            ($0.interior.row, $0.interior.column) < ($1.interior.row, $1.interior.column)
        }
    }

    private static func box(bottomRow r: Int, left c: Int, in rows: [[Character]]) -> ClaudeImageBox? {
        // Bottom border: ╰ then ─ up to a ╯, which fixes the frame's columns.
        let bottom = rows[r]
        var right = c + 1
        while right < bottom.count, bottom[right] == "─" { right += 1 }
        guard right < bottom.count, bottom[right] == "╯", right - c >= 3 else { return nil }
        let innerWidth = right - c - 1

        // Label row directly above: │ spaces #digits spaces │.
        guard let number = label(rows[r - 1], left: c, right: right) else { return nil }

        // Walk up through interior rows to the top border.
        var i = r - 2
        while i >= 0 {
            let row = rows[i]
            guard row.count > right else { return nil }
            if row[c] == "╭", row[right] == "╮", row[(c + 1)..<right].allSatisfy({ $0 == "─" }) {
                return ClaudeImageBox(
                    number: number,
                    interior: CellRect(row: i + 1, column: c + 1, rows: r - i - 2, columns: innerWidth)
                )
            }
            guard row[c] == "│", row[right] == "│" else { return nil }
            i -= 1
        }
        return nil
    }

    private static func label(_ row: [Character], left: Int, right: Int) -> Int? {
        guard row.count > right, row[left] == "│", row[right] == "│" else { return nil }
        let inner = String(row[(left + 1)..<right]).trimmingCharacters(in: .whitespaces)
        guard inner.hasPrefix("#") else { return nil }
        let digits = inner.dropFirst()
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(digits)
    }
}
