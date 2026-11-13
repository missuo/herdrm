import XCTest
@testable import herdrm

/// #77: built-in, Ghostty and imported terminal themes.
final class TerminalThemeTests: XCTestCase {
    private var customDirectory: URL!
    private var ghosttyDirectory: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("TerminalThemeTests-\(UUID().uuidString)", isDirectory: true)
        customDirectory = base.appendingPathComponent("custom", isDirectory: true)
        ghosttyDirectory = base.appendingPathComponent("ghostty", isDirectory: true)
        try FileManager.default.createDirectory(at: ghosttyDirectory, withIntermediateDirectories: true)
        TerminalThemeLibrary.customDirectoryOverride = customDirectory
        TerminalThemeLibrary.ghosttyDirectoryOverride = ghosttyDirectory
        TerminalThemeLibrary.invalidate()
    }

    override func tearDownWithError() throws {
        TerminalThemeLibrary.customDirectoryOverride = nil
        TerminalThemeLibrary.ghosttyDirectoryOverride = nil
        TerminalThemeLibrary.invalidate()
        try? FileManager.default.removeItem(at: customDirectory.deletingLastPathComponent())
    }

    private let bonfire = """
        # a Ghostty theme file
        palette = 0=#1d1f21
        palette = 1=#ff6c00
        background = #1c1b22
        foreground = #e0def4
        """

    func testIDsRoundTripAndTheDefaultHasNoTheme() {
        XCTAssertNil(TerminalThemeID.parse(""))
        XCTAssertNil(TerminalThemeID.parse("builtin:"))
        XCTAssertNil(TerminalThemeID.parse("other:Dracula"))
        let parsed = TerminalThemeID.parse(TerminalThemeID.make(.custom, "A: B"))
        XCTAssertEqual(parsed?.source, .custom)
        XCTAssertEqual(parsed?.name, "A: B", "only the first colon separates the source")
        XCTAssertNil(TerminalThemeLibrary.definition(for: TerminalThemeID.default))
    }

    func testBuiltInThemesResolveFromTheCatalog() throws {
        XCTAssertGreaterThan(TerminalThemeLibrary.allEntries().filter { $0.source == .builtin }.count, 400)
        let dracula = try XCTUnwrap(TerminalThemeLibrary.definition(for: "builtin:Dracula"))
        XCTAssertEqual(dracula.background, "282a36")
        XCTAssertNil(TerminalThemeLibrary.definition(for: "builtin:No Such Theme"))
    }

    func testImportingAFileAddsAndSelectsACustomTheme() throws {
        let source = customDirectory.deletingLastPathComponent().appendingPathComponent("London Bonfire Night.conf")
        try bonfire.write(to: source, atomically: true, encoding: .utf8)

        let id = try TerminalThemeLibrary.importTheme(from: source)
        XCTAssertEqual(id, "custom:London Bonfire Night", "a config-ish extension is not part of the name")
        let theme = try XCTUnwrap(TerminalThemeLibrary.definition(for: id))
        XCTAssertEqual(theme.background, "1c1b22")
        XCTAssertEqual(theme.palette[1], "ff6c00")
        XCTAssertEqual(TerminalThemeLibrary.allEntries().first?.id, id, "imported themes list first")

        TerminalThemeLibrary.removeImported(id)
        XCTAssertNil(TerminalThemeLibrary.definition(for: id), "a removed theme falls back to the default")
    }

    func testImportRejectsFilesThatAreNotThemes() throws {
        let source = customDirectory.deletingLastPathComponent().appendingPathComponent("config")
        try "font-family = Menlo\n".write(to: source, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try TerminalThemeLibrary.importTheme(from: source))
        XCTAssertFalse(FileManager.default.fileExists(atPath: customDirectory.appendingPathComponent("config").path))
    }

    func testThemeNamesKeepUnknownExtensions() {
        XCTAssertEqual(TerminalThemeLibrary.themeName(forFileNamed: "Nord.conf"), "Nord")
        XCTAssertEqual(TerminalThemeLibrary.themeName(forFileNamed: "Nord"), "Nord")
        XCTAssertEqual(TerminalThemeLibrary.themeName(forFileNamed: "Dracula+"), "Dracula+")
        XCTAssertEqual(TerminalThemeLibrary.themeName(forFileNamed: "Builtin Solarized.Dark"), "Builtin Solarized.Dark")
    }

    func testGhosttyConfigThemeNamesResolveLikeGhostty() throws {
        XCTAssertEqual(TerminalThemeLibrary.id(forGhosttyThemeNamed: "Dracula"), "builtin:Dracula")
        XCTAssertEqual(TerminalThemeLibrary.id(forGhosttyThemeNamed: "dracula"), "builtin:Dracula")
        XCTAssertNil(TerminalThemeLibrary.id(forGhosttyThemeNamed: "No Such Theme"))

        // A user theme in ~/.config/ghostty/themes wins over the catalog, as in Ghostty.
        try bonfire.write(to: ghosttyDirectory.appendingPathComponent("Dracula"), atomically: true, encoding: .utf8)
        TerminalThemeLibrary.invalidate()
        XCTAssertEqual(TerminalThemeLibrary.id(forGhosttyThemeNamed: "Dracula"), "ghostty:Dracula")
    }

    func testTheLightAdapterFollowsTheBackgroundActuallyShown() throws {
        let defaultDark = TerminalThemeLibrary.effectiveBackground(theme: nil, dark: true)
        XCTAssertEqual(defaultDark.hex, TerminalDefaults.darkBackgroundHex)
        XCTAssertTrue(defaultDark.isDark)
        let defaultLight = TerminalThemeLibrary.effectiveBackground(theme: nil, dark: false)
        XCTAssertEqual(defaultLight.hex, TerminalDefaults.lightBackgroundHex)
        XCTAssertFalse(defaultLight.isDark)

        // A chosen theme decides by its own background, whatever the app appearance.
        let latte = TerminalThemeLibrary.definition(for: "builtin:Catppuccin Latte")
        XCTAssertNotNil(latte)
        let lightTheme = TerminalThemeLibrary.effectiveBackground(theme: latte, dark: true)
        XCTAssertEqual(lightTheme.hex, "#EFF1F5")
        XCTAssertFalse(lightTheme.isDark)
        let darkTheme = TerminalThemeLibrary.effectiveBackground(
            theme: TerminalThemeLibrary.definition(for: "builtin:Dracula"), dark: false
        )
        XCTAssertTrue(darkTheme.isDark)
    }
}
