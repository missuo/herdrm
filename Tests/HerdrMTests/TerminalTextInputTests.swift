import AppKit
import XCTest
@testable import herdrm

@MainActor
final class TerminalTextInputTests: XCTestCase {
    func testIdleTerminalReportsAValidInsertionPointToInputMethods() {
        let view = LineBreakTerminalView(frame: .zero)
        XCTAssertFalse(view.hasMarkedText())
        XCTAssertEqual(view.selectedRange(), view.accessibilitySelectedTextRange())
        XCTAssertEqual(view.markedRange(), NSRange(location: 0, length: 0))
        XCTAssertEqual(view.characterIndex(for: .zero), 0)
    }

    func testCompositionKeepsItsOwnSelectionAndMarkedRange() {
        let view = LineBreakTerminalView(frame: .zero)
        view.setMarkedText("nihao", selectedRange: NSRange(location: 2, length: 3),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())
        XCTAssertEqual(view.selectedRange(), NSRange(location: 2, length: 3))
        XCTAssertEqual(view.markedRange(), NSRange(location: 0, length: 5))
        view.unmarkText()
        XCTAssertFalse(view.hasMarkedText())
        XCTAssertEqual(view.selectedRange(), NSRange(location: 0, length: 0))
        XCTAssertEqual(view.markedRange(), NSRange(location: 0, length: 0))
    }

    func testInputMethodGeometryReportsTheRequestedRange() {
        let view = LineBreakTerminalView(frame: .zero)
        var actual = NSRange(location: NSNotFound, length: 0)
        let requested = NSRange(location: 0, length: 0)
        let rect = view.firstRect(forCharacterRange: requested, actualRange: &actual)
        XCTAssertEqual(actual, requested)
        XCTAssertEqual(rect.width, 0)
    }
}
