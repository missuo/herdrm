import XCTest
@testable import herdrm

final class TerminalCaretGridTests: XCTestCase {
    private let screen = "header\n\n> git ch\nfooter"

    func testCursorCellMapsToItsOffsetOnTheTypedLine() {
        // Row 2, after "> git ch" (8 columns): the text before it ends with the typed fragment.
        let offset = TerminalCaretGrid.offset(of: .init(row: 2, column: 8), in: screen)
        XCTAssertEqual((screen as NSString).substring(to: offset), "header\n\n> git ch")
    }

    func testCursorPastTheTrimmedRowEndClampsToTheRow() {
        // "> git ch " with its trailing blank dropped by the viewport read.
        let offset = TerminalCaretGrid.offset(of: .init(row: 2, column: 9), in: screen)
        XCTAssertEqual(offset, 16)
        XCTAssertEqual(TerminalCaretGrid.cell(at: offset, in: screen), .init(row: 2, column: 8))
    }

    func testRowsBeyondTheViewportClampToTheLastRow() {
        XCTAssertEqual(TerminalCaretGrid.offset(of: .init(row: 9, column: 2), in: screen), 19)
        XCTAssertEqual(TerminalCaretGrid.offset(of: .init(row: 0, column: 0), in: ""), 0)
    }

    func testOffsetsRoundTripThroughCells() {
        let length = (screen as NSString).length
        for offset in 0...length {
            let cell = TerminalCaretGrid.cell(at: offset, in: screen)
            XCTAssertEqual(TerminalCaretGrid.offset(of: cell, in: screen), offset, "offset \(offset)")
        }
    }

    func testCursorCellFromTheIMEPointRoundsPastThePadding() {
        // 2pt padding, 8.5 x 17 cells: the cursor at row 3, column 5. Its bottom edge is the top
        // of row 4.
        let cell = TerminalCaretGrid.cursorCell(
            x: 2 + 5 * 8.5, bottomFromTop: 2 + 4 * 17, cellWidth: 8.5, cellHeight: 17, padding: 2
        )
        XCTAssertEqual(cell, .init(row: 3, column: 5))
        // Sub-point drift still lands in the same cell.
        XCTAssertEqual(
            TerminalCaretGrid.cursorCell(x: 44.9, bottomFromTop: 70.3, cellWidth: 8.5, cellHeight: 17, padding: 2),
            .init(row: 3, column: 5)
        )
        XCTAssertNil(TerminalCaretGrid.cursorCell(x: 10, bottomFromTop: 10, cellWidth: 0, cellHeight: 17, padding: 2))
    }
}
