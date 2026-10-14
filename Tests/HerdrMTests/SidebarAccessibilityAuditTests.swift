import AppKit
import XCTest
@testable import herdrm

/// Every control in the sidebar has a name VoiceOver can read, and none is
/// read by its icon's name ("Gear Shape", "New Folder") instead of what it does.
@MainActor
final class SidebarAccessibilityAuditTests: XCTestCase {
    func testEveryControlHasANameOfItsOwn() throws {
        let sidebar = try SidebarHarness(spaces: 14, agents: 20, terminals: 3)
        let iconNames = try Self.iconNames()
        XCTAssertTrue(iconNames.contains("gear shape"), "known-yes: the scan reads the icons the app draws")

        // Rows whose visible title happens to be their icon's name.
        let titled: Set<String> = [String(localized: "Search").lowercased()]
        let problems = sidebar.controls.compactMap { control -> String? in
            guard let name = control.name, !name.isEmpty else { return "\(control.role) \(control.identifier ?? "") has no name" }
            return iconNames.contains(name.lowercased()) && !titled.contains(name.lowercased()) ? "\(control.role) \(control.identifier ?? "") is read as its icon, \"\(name)\"" : nil
        }
        XCTAssertFalse(sidebar.controls.isEmpty, "known-yes: controls were found")
        XCTAssertEqual(problems, [], problems.joined(separator: "\n"))
    }

    /// What VoiceOver says for each SF Symbol the app draws, when nothing names
    /// the control: the symbol's own accessibility description.
    private static func iconNames() throws -> Set<String> {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Sources/HerdrM").standardizedFileURL
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        let pattern = try NSRegularExpression(pattern: #"systemName: "([^"]+)""#)
        var names: Set<String> = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range(at: 1), in: text),
                      let description = NSImage(systemSymbolName: String(text[range]), accessibilityDescription: nil)?.accessibilityDescription
                else { continue }
                names.insert(description.lowercased())
            }
        }
        return names
    }
}
