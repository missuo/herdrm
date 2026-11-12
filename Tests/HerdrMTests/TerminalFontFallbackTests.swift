import CoreText
import XCTest
@testable import herdrm

final class TerminalFontFallbackTests: XCTestCase {
    @MainActor
    func testThinStrokesControlsRendererThickening() {
        for thinStrokes in [true, false] {
            let config = GhosttyRuntime.fontConfiguration(
                fontName: "", fontSize: 14, fontWeight: 0, thinStrokes: thinStrokes,
                lineSpacing: 1, copyOnSelect: true
            )
            XCTAssertTrue(config.rendered.contains("font-thicken = \(!thinStrokes)"))
        }
    }

    func testOnlyMissingSymbolsUseFallbackIncludingSupplementaryPlanes() {
        let symbols = characterSet(0xE0B0, 0xE0B1, 0xF179, 0xF0001, 0x100001, 0x100002, 0x41)
        let primary = characterSet(0xE0B0, 0xF179, 0x100001)
        XCTAssertTrue(CFCharacterSetIsLongCharacterMember(symbols, 0xF0001))
        XCTAssertTrue(CFCharacterSetIsLongCharacterMember(symbols, 0x100002))
        XCTAssertFalse(CFCharacterSetIsLongCharacterMember(primary, 0xF0001))
        XCTAssertEqual(TerminalFontFallback.ranges(primary: primary, symbols: symbols), [
            0xE0B1...0xE0B1, 0xF0001...0xF0001, 0x100002...0x100002,
        ])
    }

    func testPatchedFontKeepsItsOwnIcons() {
        let symbols = characterSet(0xE0B0, 0xF179, 0xF017, 0xE73C, 0xF0001)
        XCTAssertTrue(TerminalFontFallback.ranges(primary: symbols, symbols: symbols).isEmpty)
    }

    func testAdjacentMissingSymbolsAreCoalescedWithoutOverridingAnExistingGlyph() {
        let symbols = characterSet(0xE000, 0xE001, 0xE002, 0xE003, 0xE004)
        let primary = characterSet(0xE002)
        XCTAssertEqual(TerminalFontFallback.ranges(primary: primary, symbols: symbols), [
            0xE000...0xE001, 0xE003...0xE004,
        ])
    }

    private func characterSet(_ scalars: UInt32...) -> CFCharacterSet {
        let set = CFCharacterSetCreateMutable(nil)!
        for scalar in scalars {
            CFCharacterSetAddCharactersInRange(set, CFRange(location: Int(scalar), length: 1))
        }
        return set
    }
}
