import XCTest
@testable import herdrm

/// Right-clicking a space's row offers New Agent and New Terminal, and the
/// sheet they open starts in that space, whichever space is selected.
@MainActor
final class SidebarSpaceRowMenuUIUXTests: XCTestCase {
    func testSpaceMenuOffersNewAgentAndNewTerminal() throws {
        let sidebar = try SidebarHarness(spaces: 3, agents: 4, pinnedHeaders: false)
        let items = try sidebar.spaceMenu("Space 2")

        XCTAssertTrue(items.contains(String(localized: "Rename Space…")), "known-yes: the row's menu is read: \(items)")
        XCTAssertTrue(items.contains(String(localized: "New Agent…")), "\(items)")
        XCTAssertTrue(items.contains(String(localized: "New Terminal…")), "\(items)")
    }

    func testNewAgentFromASpaceStartsInThatSpace() throws {
        let sidebar = try SidebarHarness(spaces: 3, agents: 4, sheets: true, pinnedHeaders: false)
        let spaces = sidebar.model.visibleSpaces
        sidebar.model.selectSpace(spaces[0].ref)

        try sidebar.chooseFromSpaceMenu("Space 3", String(localized: "New Agent…"))
        XCTAssertTrue(sidebar.model.showNewAgent)
        XCTAssertTrue(sidebar.sheetTexts.contains { $0.contains("Space 3") }, "\(sidebar.sheetTexts)")
        XCTAssertEqual(sidebar.model.selectedSpace, spaces[0].ref, "the selection stays where it was")
    }

    func testNewTerminalFromASpaceStartsInThatSpace() throws {
        let sidebar = try SidebarHarness(spaces: 3, agents: 4, sheets: true, pinnedHeaders: false)
        let spaces = sidebar.model.visibleSpaces
        sidebar.model.selectSpace(spaces[0].ref)

        try sidebar.chooseFromSpaceMenu("Space 3", String(localized: "New Terminal…"))
        XCTAssertTrue(sidebar.model.showNewTerminal)
        XCTAssertTrue(sidebar.sheetTexts.contains { $0.contains("Space 3") }, "\(sidebar.sheetTexts)")
        XCTAssertEqual(sidebar.model.selectedSpace, spaces[0].ref, "the selection stays where it was")
    }

    func testHeaderButtonStillOpensOnTheSelectedSpace() throws {
        let sidebar = try SidebarHarness(spaces: 3, agents: 4, sheets: true, pinnedHeaders: false)
        let spaces = sidebar.model.visibleSpaces
        sidebar.model.selectSpace(spaces[1].ref)
        try sidebar.chooseFromSpaceMenu("Space 3", String(localized: "New Agent…"))
        sidebar.dismissSheet()

        try sidebar.pressHeaderButton(.agents, named: String(localized: "New Agent"))
        XCTAssertTrue(sidebar.sheetTexts.contains { $0.contains("Space 2") }, "a space picked from a menu leaked into the next sheet: \(sidebar.sheetTexts)")
    }
}
