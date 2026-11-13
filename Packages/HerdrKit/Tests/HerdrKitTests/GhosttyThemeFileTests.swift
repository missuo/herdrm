#if os(macOS)
import XCTest

@testable import HerdrKit

/// Ghostty theme files and the config's `theme` key (issue #77: custom and
/// built-in terminal themes).
final class GhosttyThemeFileTests: XCTestCase {
    func testParsesAThemeFileInGhosttysExportFormat() throws {
        let colors = try XCTUnwrap(GhosttyThemeColors.parse(
            """
            # London Bonfire Night
            palette = 0=#1d1f21
            palette = 1=#CC6666
            palette = 15 = ffffff
            background = #1C1B22
            foreground = #e0def4
            cursor-color = #fa6c00
            cursor-text = 1c1b22
            selection-background = "#403d52"
            selection-foreground = #e0def4
            """
        ))
        XCTAssertEqual(colors.background, "1c1b22")
        XCTAssertEqual(colors.foreground, "e0def4")
        XCTAssertEqual(colors.cursorColor, "fa6c00")
        XCTAssertEqual(colors.cursorText, "1c1b22")
        XCTAssertEqual(colors.selectionBackground, "403d52")
        XCTAssertEqual(colors.selectionForeground, "e0def4")
        XCTAssertEqual(colors.palette, [0: "1d1f21", 1: "cc6666", 15: "ffffff"])
    }

    func testShortHexExpandsAndNamedOrBrokenColorsAreSkipped() throws {
        let colors = try XCTUnwrap(GhosttyThemeColors.parse(
            """
            background = #000
            foreground = #fFf
            cursor-color = orange
            palette = 2=#12345
            palette = 300=#000000
            palette = x=#000000
            font-size = 14
            """
        ))
        XCTAssertEqual(colors.background, "000000")
        XCTAssertEqual(colors.foreground, "ffffff")
        XCTAssertNil(colors.cursorColor, "X11 color names aren't supported; the key is skipped")
        XCTAssertEqual(colors.palette, [:])
    }

    func testAFileWithoutBackgroundOrForegroundIsNotATheme() {
        XCTAssertNil(GhosttyThemeColors.parse("palette = 0=#000000\nforeground = #ffffff"))
        XCTAssertNil(GhosttyThemeColors.parse("background = #000000"))
        XCTAssertNil(GhosttyThemeColors.parse("font-family = Menlo\n"))
        XCTAssertNil(GhosttyThemeColors.parse(""))
    }

    func testConfigThemeKeyPicksTheSideForTheAppearance() {
        let single = GhosttyConfigImporter.parse("theme = Dracula")
        XCTAssertEqual(single.theme, "Dracula")
        XCTAssertFalse(single.isEmpty)
        XCTAssertEqual(single.themeName(dark: true), "Dracula")
        XCTAssertEqual(single.themeName(dark: false), "Dracula")

        let split = GhosttyConfigImporter.parse("theme = light:Catppuccin Latte,dark:Catppuccin Mocha")
        XCTAssertEqual(split.themeName(dark: true), "Catppuccin Mocha")
        XCTAssertEqual(split.themeName(dark: false), "Catppuccin Latte")

        let darkOnly = GhosttyConfigImporter.parse("theme = dark:Nord")
        XCTAssertEqual(darkOnly.themeName(dark: false), "Nord", "one side serves both when the other is missing")

        XCTAssertNil(GhosttyConfigImporter.parse("font-size = 12").themeName(dark: true))
    }
}
#endif
