import XCTest
@testable import herdrm

/// #122: layouts that type characters with Option (German ⌥L → @) need
/// Option left as Option inside the terminal.
final class TerminalOptionAsAltTests: XCTestCase {
    @MainActor
    func testSettingControlsGhosttyOptionAsAlt() {
        let expected: [(TerminalOptionAsAlt, String)] = [(.both, "true"), (.off, "false")]
        for (setting, value) in expected {
            let lines = GhosttyRuntime.fontConfiguration(
                fontName: "", fontSize: 14, fontWeight: 0, thinStrokes: true,
                lineSpacing: 1, copyOnSelect: true, optionAsAlt: setting
            ).rendered.split(separator: "\n")
            XCTAssertTrue(lines.contains(Substring("macos-option-as-alt = \(value)")), "\(setting)")
            XCTAssertEqual(lines.filter { $0.hasPrefix("macos-option-as-alt") }.count, 1)
        }
    }

    @MainActor
    func testOptionIsMetaUntilTheUserTurnsItOff() {
        let suite = "TerminalOptionAsAltTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let stored = defaults.string(forKey: TerminalDefaults.optionAsAltKey)
            .flatMap(TerminalOptionAsAlt.init(rawValue:)) ?? .both
        XCTAssertEqual(stored, .both)

        defaults.set(TerminalOptionAsAlt.off.rawValue, forKey: TerminalDefaults.optionAsAltKey)
        XCTAssertEqual(
            defaults.string(forKey: TerminalDefaults.optionAsAltKey).flatMap(TerminalOptionAsAlt.init(rawValue:)),
            .off
        )
    }
}
