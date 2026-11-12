import XCTest
@testable import herdrm

final class ClaudeImageBoxesTests: XCTestCase {
    // Captured from Claude Code 2.1.302 on 2026-10-18, two images pasted.
    private let twoBoxes = """
    ╭────────────────────╮ ╭────────────────────╮
    │▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀│ │▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀│
    │▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀│ │▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀│
    │▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀│ │▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀│
    │▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀│ │▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀│
    │▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀│ │▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀│
    │▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀│ │▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀│
    │         #1         │ │         #2         │
    ╰────────────────────╯ ╰────────────────────╯

    ────────────────────────────────────────────
    ❯ [Image #1] [Image #2]
    """

    func testFindsTwoBoxesSideBySideWithTheirInteriors() {
        let boxes = ClaudeImageBoxes.boxes(in: "header\n" + twoBoxes)
        XCTAssertEqual(boxes, [
            ClaudeImageBox(number: 1, interior: CellRect(row: 2, column: 1, rows: 6, columns: 20)),
            ClaudeImageBox(number: 2, interior: CellRect(row: 2, column: 24, rows: 6, columns: 20)),
        ])
    }

    /// Claude's prompt line as it sits three rows under the boxes.
    private func prompt(_ numbers: Int...) -> String {
        "\n\n──────\n❯ " + numbers.map { "[Image #\($0)]" }.joined(separator: " ")
    }

    func testBlankInteriorStillCounts() {
        // Kitty placeholders read as blanks; the frame and label decide.
        let text = "╭────╮\n│    │\n│    │\n│ #3 │\n╰────╯" + prompt(3)
        XCTAssertEqual(ClaudeImageBoxes.boxes(in: text),
                       [ClaudeImageBox(number: 3, interior: CellRect(row: 1, column: 1, rows: 2, columns: 4))])
    }

    func testTwoDigitNumberAndWiderFrame() {
        let inner = String(repeating: "─", count: 28)
        let text = "╭\(inner)╮\n│" + String(repeating: " ", count: 28) + "│\n│" + String(repeating: " ", count: 11) + "#12" + String(repeating: " ", count: 14) + "│\n╰\(inner)╯" + prompt(12)
        XCTAssertEqual(ClaudeImageBoxes.boxes(in: text).map(\.number), [12])
        XCTAssertEqual(ClaudeImageBoxes.boxes(in: text).first?.interior.columns, 28)
    }

    func testFrameWithoutLabelIsNotABox() {
        XCTAssertEqual(ClaudeImageBoxes.boxes(in: "╭────╮\n│    │\n│    │\n╰────╯" + prompt(1)), [])
    }

    func testLabelWithoutBordersIsNotABox() {
        XCTAssertEqual(ClaudeImageBoxes.boxes(in: "│ #1 │" + prompt(1)), [])
    }

    func testBoxCutOffAtTopIsNotABox() {
        XCTAssertEqual(ClaudeImageBoxes.boxes(in: "│    │\n│ #1 │\n╰────╯" + prompt(1)), [])
    }

    func testTruncatedRightBorderIsNotABox() {
        XCTAssertEqual(ClaudeImageBoxes.boxes(in: "╭────╮\n│    │\n│ #1\n╰────╯" + prompt(1)), [])
    }

    func testFrameWithNoPromptLineBelowIsNotABox() {
        // A box diagram quoted in Claude's transcript: a valid frame, but no `[Image #N]` prompt under it.
        let frame = "╭────╮\n│    │\n│ #1 │\n╰────╯"
        XCTAssertEqual(ClaudeImageBoxes.boxes(in: frame), [])
        XCTAssertEqual(ClaudeImageBoxes.boxes(in: frame + "\n\nSome transcript text\n> more"), [])
    }

    func testPromptLineMustNameTheSameNumber() {
        let frame = "╭────╮\n│    │\n│ #1 │\n╰────╯"
        XCTAssertEqual(ClaudeImageBoxes.boxes(in: frame + prompt(2)), [])
        XCTAssertEqual(ClaudeImageBoxes.boxes(in: frame + prompt(12)), [])  // `[Image #1]` is not `[Image #12]`
    }

    func testPromptLineTooFarBelowIsNotAnAnchor() {
        let frame = "╭────╮\n│    │\n│ #1 │\n╰────╯"
        let sixDown = frame + String(repeating: "\n", count: 6) + "❯ [Image #1]"
        let sevenDown = frame + String(repeating: "\n", count: 7) + "❯ [Image #1]"
        XCTAssertEqual(ClaudeImageBoxes.boxes(in: sixDown).map(\.number), [1])
        XCTAssertEqual(ClaudeImageBoxes.boxes(in: sevenDown), [])
    }

    func testCapturedPromptAnchorsBothBoxes() {
        // Without its prompt line the captured pair is not anchored.
        let withoutPrompt = twoBoxes.components(separatedBy: "\n").dropLast(3).joined(separator: "\n")
        XCTAssertEqual(ClaudeImageBoxes.boxes(in: withoutPrompt), [])
    }

    func testEmptyViewport() {
        XCTAssertEqual(ClaudeImageBoxes.boxes(in: ""), [])
    }
}
