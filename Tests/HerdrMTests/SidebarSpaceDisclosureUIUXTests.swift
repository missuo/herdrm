import XCTest
@testable import herdrm

/// Grouped by space, each space row lists its panes under it. The chevron at
/// the row's left end folds that list; the rest of the row selects the space.
@MainActor
final class SidebarSpaceDisclosureUIUXTests: XCTestCase {
    private var savedGrouping: Any?
    private var savedCollapsed: Any?

    override func setUp() async throws {
        savedGrouping = UserDefaults.standard.object(forKey: SidebarDefaults.groupBySpaceKey)
        savedCollapsed = UserDefaults.standard.object(forKey: AppModel.collapsedSpacesKey)
        UserDefaults.standard.set(true, forKey: SidebarDefaults.groupBySpaceKey)
        UserDefaults.standard.removeObject(forKey: AppModel.collapsedSpacesKey)
    }

    override func tearDown() async throws {
        UserDefaults.standard.set(savedGrouping, forKey: SidebarDefaults.groupBySpaceKey)
        UserDefaults.standard.set(savedCollapsed, forKey: AppModel.collapsedSpacesKey)
    }

    func testClickingTheChevronFoldsAndUnfoldsTheSpace() throws {
        let sidebar = try SidebarHarness(spaces: 3, agents: 4, pinnedHeaders: false)
        let space = try XCTUnwrap(sidebar.model.visibleSpaces.first)
        let expandedHeight = sidebar.listHeight
        XCTAssertTrue(sidebar.model.isSpaceExpanded(space), "known-yes: spaces start unfolded")

        try sidebar.clickSpaceDisclosure("Space 1")
        XCTAssertFalse(sidebar.model.isSpaceExpanded(space), "chevron click did not fold the space")
        XCTAssertLessThan(sidebar.listHeight, expandedHeight - 1, "the space's panes are still listed")
        XCTAssertNil(sidebar.model.selectedSpace, "the chevron selected the space instead")

        try sidebar.clickSpaceDisclosure("Space 1")
        XCTAssertTrue(sidebar.model.isSpaceExpanded(space), "second click did not unfold the space")
        XCTAssertEqual(sidebar.listHeight, expandedHeight, accuracy: 1)
    }

    func testClickingTheSpaceTitleSelectsItAndLeavesItUnfolded() throws {
        let sidebar = try SidebarHarness(spaces: 3, agents: 4, pinnedHeaders: false)
        let space = try XCTUnwrap(sidebar.model.visibleSpaces.first)

        try sidebar.clickSpaceTitle("Space 1")
        XCTAssertEqual(sidebar.model.selectedSpace, space.ref)
        XCTAssertTrue(sidebar.model.isSpaceExpanded(space))
    }

    func testVoiceOverReadsTheChevronAsCollapseOrExpand() throws {
        let sidebar = try SidebarHarness(spaces: 3, agents: 4, pinnedHeaders: false)
        let space = try XCTUnwrap(sidebar.model.visibleSpaces.first)
        XCTAssertEqual(try sidebar.spaceDisclosureName("Space 1"), String(localized: "Collapse space"))

        sidebar.model.toggleSpaceExpanded(space)
        XCTAssertEqual(try sidebar.spaceDisclosureName("Space 1"), String(localized: "Expand space"))
    }
}
