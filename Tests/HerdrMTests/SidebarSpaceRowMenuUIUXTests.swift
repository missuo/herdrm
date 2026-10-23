import XCTest
import HerdrKit
@testable import herdrm

/// Right-clicking a space's row offers New Agent and New Terminal, and the
/// sheet they open starts in that space, whichever space is selected.
@MainActor
final class SidebarSpaceRowMenuUIUXTests: XCTestCase {
    private let remote = Device(name: "test-server", kind: .ssh(target: "test.invalid"))

    func testGlobalNewAgentUsesTheViewedRemoteAgentInAllSpaces() throws {
        let sidebar = try SidebarHarness(spaces: 3, agents: 3, device: remote, sheets: true, pinnedHeaders: false)
        try sidebar.clickAgentTitleWithoutSettling("Agent 2")
        XCTAssertNil(sidebar.model.selectedSpace, "Viewing an agent does not narrow All Spaces")
        let entry = try XCTUnwrap(sidebar.model.selectedAttachedEntry)
        let space = try XCTUnwrap(sidebar.model.visibleSpaces.first { $0.workspace.workspaceID == entry.workspaceID })

        try sidebar.clickAction(named: String(localized: "New Agent"))

        XCTAssertTrue(sidebar.sheetTexts.contains { $0.contains(remote.name) }, "\(sidebar.sheetTexts)")
        XCTAssertTrue(sidebar.sheetTexts.contains { $0.contains(space.workspace.label) }, "\(sidebar.sheetTexts)")
    }

    func testNewTerminalKeepsTheRemoteSpaceFromItsMenu() throws {
        let sidebar = try SidebarHarness(spaces: 3, agents: 0, device: remote, sheets: true, pinnedHeaders: false)
        let spaces = sidebar.model.visibleSpaces
        sidebar.model.selectSpace(spaces[0].ref)

        try sidebar.chooseFromSpaceMenu("Space 3", String(localized: "New Terminal…"))

        XCTAssertTrue(sidebar.sheetTexts.contains { $0.contains("Space 3") }, "\(sidebar.sheetTexts)")
        XCTAssertEqual(sidebar.model.selectedSpace, spaces[0].ref)
        XCTAssertNil(sidebar.model.newItemSpace)
    }

    func testNewAgentKeepsTheRemoteSpaceFromItsMenu() throws {
        let sidebar = try SidebarHarness(spaces: 3, agents: 0, device: remote, sheets: true, pinnedHeaders: false)
        let spaces = sidebar.model.visibleSpaces
        sidebar.model.selectSpace(spaces[0].ref)

        try sidebar.chooseFromSpaceMenu("Space 3", String(localized: "New Agent…"))

        XCTAssertTrue(sidebar.sheetTexts.contains { $0.contains("Space 3") }, "\(sidebar.sheetTexts)")
        XCTAssertEqual(sidebar.model.selectedSpace, spaces[0].ref)
        XCTAssertNil(sidebar.model.newItemSpace)
    }

    func testGlobalNewTerminalKeepsTheSelectedRemoteSpaceAfterDismissingAMenuSheet() throws {
        let sidebar = try SidebarHarness(spaces: 3, agents: 0, device: remote, sheets: true, pinnedHeaders: false)
        sidebar.model.selectSpace(sidebar.model.visibleSpaces[1].ref)
        try sidebar.chooseFromSpaceMenu("Space 3", String(localized: "New Terminal…"))
        sidebar.dismissSheet()

        try sidebar.clickAction(named: String(localized: "New Terminal"))

        XCTAssertTrue(sidebar.sheetTexts.contains { $0.contains("Space 2") }, "\(sidebar.sheetTexts)")
    }

    func testManuallyChangingDeviceStillResetsTheSpace() throws {
        let sidebar = try SidebarHarness(spaces: 3, agents: 0, device: remote, sheets: true, pinnedHeaders: false)

        try sidebar.chooseFromSpaceMenu("Space 3", String(localized: "New Terminal…"))
        try sidebar.selectSheetDevice(from: remote.name, to: Device.local.name)
        XCTAssertTrue(sidebar.sheetTexts.contains(String(localized: "Start a login shell on this Mac")), "\(sidebar.sheetTexts)")
        sidebar.dismissSheet()

        try sidebar.chooseFromSpaceMenu("Space 3", String(localized: "New Agent…"))
        try sidebar.selectSheetDevice(from: remote.name, to: Device.local.name)
        XCTAssertTrue(sidebar.sheetTexts.contains {
            $0.contains(String(localized: "the focused space"))
        }, "\(sidebar.sheetTexts)")
    }

    func testSpaceMenuOffersNewAgentAndNewTerminal() throws {
        let sidebar = try SidebarHarness(spaces: 3, agents: 4, pinnedHeaders: false)
        let items = try sidebar.spaceMenu("Space 2")

        XCTAssertTrue(items.contains(String(localized: "Rename Space…")), "known-yes: the row's menu is read: \(items)")
        XCTAssertTrue(items.contains(String(localized: "New Agent…")), "\(items)")
        XCTAssertTrue(items.contains(String(localized: "New Terminal…")), "\(items)")
        XCTAssertTrue(items.contains(String(localized: "Project…")), "\(items)")
    }

    func testProjectFromASpaceOpensTheProjectPaneOnThatSpace() throws {
        let sidebar = try SidebarHarness(spaces: 3, agents: 4, pinnedHeaders: false)
        let spaces = sidebar.model.visibleSpaces

        try sidebar.chooseFromSpaceMenu("Space 3", String(localized: "Project…"))
        XCTAssertEqual(sidebar.model.detailMode, .project)
        XCTAssertEqual(sidebar.model.projectSpace, spaces[2].ref)
        XCTAssertNil(sidebar.model.selectedSpace, "the sidebar's Space filter is left as it was")
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
