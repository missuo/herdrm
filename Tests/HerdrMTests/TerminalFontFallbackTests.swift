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
        let symbols = CharacterSet(charactersIn: "\u{E0B0}\u{E0B1}\u{F179}\u{F0001}\u{100001}A")
        let primary = CharacterSet(charactersIn: "\u{E0B0}\u{F179}\u{100001}")
        XCTAssertEqual(TerminalFontFallback.ranges(primary: primary as CFCharacterSet, symbols: symbols as CFCharacterSet), [
            0xE0B1...0xE0B1, 0xF0001...0xF0001,
        ])
    }

    func testPatchedFontKeepsItsOwnIcons() {
        let symbols = CharacterSet(charactersIn: "\u{E0B0}\u{F179}\u{F017}\u{E73C}\u{F0001}")
        XCTAssertTrue(TerminalFontFallback.ranges(primary: symbols as CFCharacterSet, symbols: symbols as CFCharacterSet).isEmpty)
    }

    func testAdjacentMissingSymbolsAreCoalescedWithoutOverridingAnExistingGlyph() {
        let symbols = CharacterSet(charactersIn: "\u{E000}\u{E001}\u{E002}\u{E003}\u{E004}")
        let primary = CharacterSet(charactersIn: "\u{E002}")
        XCTAssertEqual(TerminalFontFallback.ranges(primary: primary as CFCharacterSet, symbols: symbols as CFCharacterSet), [
            0xE000...0xE001, 0xE003...0xE004,
        ])
    }
}
