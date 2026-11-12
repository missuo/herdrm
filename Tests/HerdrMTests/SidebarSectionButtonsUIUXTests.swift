import XCTest
@testable import herdrm

/// Each section header carries a small "new" button at its right end: the
/// action sits on the header of the list it adds to, pinned or not.
@MainActor
final class SidebarSectionButtonsUIUXTests: XCTestCase {
    func testSpacesHeaderButtonOpensNewSpace() throws {
        let sidebar = try SidebarHarness(spaces: 14, agents: 20)
        sidebar.scroll(.offset(180))
        XCTAssertEqual(sidebar.pinnedHeader, .spaces)

        try sidebar.clickPinnedHeaderButton()
        XCTAssertTrue(sidebar.model.showNewSpace)
    }

    func testAgentsHeaderButtonOpensNewAgent() throws {
        let sidebar = try SidebarHarness(spaces: 14, agents: 20)
        let expanded = sidebar.listHeight
        sidebar.scroll(.bottom)
        XCTAssertEqual(sidebar.pinnedHeader, .agents)

        try sidebar.clickPinnedHeaderButton()
        XCTAssertTrue(sidebar.model.showNewAgent)
        XCTAssertFalse(sidebar.model.showNewTerminal)
        XCTAssertEqual(sidebar.listHeight, expanded, accuracy: 2, "the button does not collapse the section")
    }

    func testTerminalsHeaderButtonOpensNewTerminal() throws {
        let sidebar = try SidebarHarness(spaces: 14, agents: 20, terminals: 20)
        let expanded = sidebar.listHeight
        sidebar.scroll(.bottom)
        XCTAssertEqual(sidebar.pinnedHeader, .terminals)

        try sidebar.clickPinnedHeaderButton()
        XCTAssertTrue(sidebar.model.showNewTerminal)
        XCTAssertFalse(sidebar.model.showNewAgent)
        XCTAssertEqual(sidebar.listHeight, expanded, accuracy: 2, "the button does not collapse the section")
    }

    func testVoiceOverReadsEachHeaderButtonByName() throws {
        let sidebar = try SidebarHarness(spaces: 14, agents: 20, terminals: 20)

        XCTAssertTrue(sidebar.headerButtons(.spaces).contains(String(localized: "New Space")), "\(sidebar.headerButtons(.spaces))")
        XCTAssertTrue(sidebar.headerButtons(.agents).contains(String(localized: "New Agent")), "\(sidebar.headerButtons(.agents))")
        XCTAssertTrue(sidebar.headerButtons(.terminals).contains(String(localized: "New Terminal")), "\(sidebar.headerButtons(.terminals))")
    }

    func testAgentsHeaderButtonPresentsTheNewAgentSheet() throws {
        let sidebar = try SidebarHarness(spaces: 14, agents: 20, sheets: true)
        XCTAssertEqual(sidebar.sheetButtons, [])

        try sidebar.pressHeaderButton(.agents, named: String(localized: "New Agent"))
        XCTAssertTrue(sidebar.sheetButtons.contains(String(localized: "Start Agent")), "\(sidebar.sheetButtons)")
    }

    func testTerminalsHeaderButtonPresentsTheNewTerminalSheet() throws {
        let sidebar = try SidebarHarness(spaces: 14, agents: 20, terminals: 20, sheets: true)

        try sidebar.pressHeaderButton(.terminals, named: String(localized: "New Terminal"))
        XCTAssertTrue(sidebar.sheetButtons.contains(String(localized: "Open Terminal")), "\(sidebar.sheetButtons)")
    }

    func testClickingAHeaderTitleOpensNothing() throws {
        let sidebar = try SidebarHarness(spaces: 14, agents: 20)
        sidebar.scroll(.bottom)

        try sidebar.clickPinnedHeader()
        XCTAssertFalse(sidebar.model.showNewAgent)
        XCTAssertFalse(sidebar.model.showNewSpace)
    }

    /// The panel belongs to a pane's Space, so it opens from the pane's titlebar
    /// and row menu, not from a sidebar action row.
    func testProjectIsNotASidebarActionRow() throws {
        let sidebar = try SidebarHarness(spaces: 3, agents: 4, pinnedHeaders: false)
        let names = sidebar.actionRowNames()
        XCTAssertTrue(names.contains(String(localized: "Files")), "\(names)")
        XCTAssertFalse(names.contains(String(localized: "Project")), "\(names)")
    }
}
