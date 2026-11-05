import AppKit
import HerdrKit
import XCTest
@testable import herdrm

@MainActor
final class SidebarSpaceRevealUIUXTests: XCTestCase {
    private let remote = Device(name: "test-server", kind: .ssh(target: "test.invalid"))
    private var savedGrouping: Any?
    private var savedDeviceFilter: Any?
    private var savedCollapsed: Any?

    override func setUpWithError() throws {
        savedGrouping = UserDefaults.standard.object(forKey: SidebarDefaults.groupBySpaceKey)
        savedDeviceFilter = UserDefaults.standard.object(forKey: "device.filter")
        savedCollapsed = UserDefaults.standard.object(forKey: AppModel.collapsedSpacesKey)
        UserDefaults.standard.set(false, forKey: SidebarDefaults.groupBySpaceKey)
        UserDefaults.standard.removeObject(forKey: "device.filter")
        UserDefaults.standard.removeObject(forKey: AppModel.collapsedSpacesKey)
    }

    override func tearDownWithError() throws {
        UserDefaults.standard.set(savedGrouping, forKey: SidebarDefaults.groupBySpaceKey)
        UserDefaults.standard.set(savedDeviceFilter, forKey: "device.filter")
        UserDefaults.standard.set(savedCollapsed, forKey: AppModel.collapsedSpacesKey)
    }

    func testClickingAgentAndTerminalRowsKeepsFlatSidebarStill() throws {
        try assertPaneClicksKeepSidebarStill(grouped: false)
    }

    func testClickingAgentAndTerminalRowsKeepsGroupedSidebarStill() throws {
        try assertPaneClicksKeepSidebarStill(grouped: true)
    }

    private func assertPaneClicksKeepSidebarStill(grouped: Bool) throws {
        UserDefaults.standard.set(grouped, forKey: SidebarDefaults.groupBySpaceKey)
        let agentWorkspace = grouped ? "ws-12" : "ws-0"
        let terminalWorkspace = grouped ? "ws-13" : "ws-1"
        let agentSpace = grouped ? "Space 13" : "Space 1"
        let terminalSpace = grouped ? "Space 14" : "Space 2"
        let agentRef = PaneRef(deviceID: remote.id, paneID: "pane-0")
        let terminalRef = PaneRef(deviceID: remote.id, paneID: "term-pane-0")
        let sidebar = try SidebarHarness(spaces: grouped ? 40 : 25, agents: 1, terminals: 1, device: remote,
                                         pinnedHeaders: false, height: grouped ? 800 : 600,
                                         configureModel: { model in
            model.sessions[self.remote.id]?.agents = [try self.decode(AgentInfo.self, [
                "agent": "claude", "name": "Agent 1", "workspace_id": agentWorkspace,
                "tab_id": "tab-0", "pane_id": "pane-0",
            ])]
            model.sessions[self.remote.id]?.panes = [try self.terminal(in: terminalWorkspace)]
        })
        sidebar.mountInputTerminals(for: [agentRef, terminalRef])
        let clicks: [(title: String, pane: PaneRef, space: String, accessibility: Bool)] = [
            ("Agent 1", agentRef, agentSpace, false),
            ("Terminal test1", terminalRef, terminalSpace, false),
            ("Terminal test1", terminalRef, terminalSpace, false),
            ("Agent 1", agentRef, agentSpace, false),
            ("Agent 1", agentRef, agentSpace, true),
            ("Terminal test1", terminalRef, terminalSpace, true),
        ]
        for (index, click) in clicks.enumerated() {
            let context = "\(grouped ? "grouped" : "flat") click \(index + 1): \(click.title) (\(click.accessibility ? "AX" : "mouse"))"
            sidebar.scroll(grouped ? .offset(300) : .bottom)
            let originalOffset = sidebar.scrollOffset
            let originalListHeight = sidebar.listHeight
            let originalMaxOffset = sidebar.maxOffset
            let originalAgentRow = try sidebar.paneRowFrame("Agent 1")
            let originalTerminalRow = try sidebar.paneRowFrame("Terminal test1")
            if click.accessibility {
                try sidebar.pressPaneTitle(click.title)
            } else if click.pane == agentRef {
                try sidebar.clickAgentTitleWithoutSettling(click.title)
            } else {
                try sidebar.clickTerminalTitleWithoutSettling(click.title)
            }
            sidebar.settleSidebar()

            XCTAssertEqual(sidebar.model.selectedPane, click.pane,
                           "The sidebar click must still switch the right-hand pane")
            XCTAssertFalse(try sidebar.spaceRowIsSelected(click.space))
            XCTAssertNil(sidebar.model.selectedSpace, "Selecting a pane must preserve All Spaces")
            XCTAssertTrue(try sidebar.spaceRowIsSelected("All Spaces"), "The highlight must match the active filter")
            let agentRowAfterClick = try sidebar.paneRowFrame("Agent 1")
            let terminalRowAfterClick = try sidebar.paneRowFrame("Terminal test1")
            let layout = "listHeight \(originalListHeight) -> \(sidebar.listHeight), maxOffset \(originalMaxOffset) -> \(sidebar.maxOffset)"
            XCTAssertEqual(sidebar.scrollOffset, originalOffset, accuracy: 1,
                           "\(context): scroll offset \(originalOffset) -> \(sidebar.scrollOffset); \(layout)")
            XCTAssertEqual(agentRowAfterClick.minY, originalAgentRow.minY, accuracy: 1,
                           "\(context): Agent row frame \(originalAgentRow) -> \(agentRowAfterClick); \(layout)")
            XCTAssertEqual(terminalRowAfterClick.minY, originalTerminalRow.minY, accuracy: 1,
                           "\(context): Terminal row frame \(originalTerminalRow) -> \(terminalRowAfterClick); \(layout)")

            // The terminal's programmatic first-responder callback follows the
            // sidebar selection. It must not cause a second, delayed scroll.
            sidebar.model.focusVisiblePane(click.pane)
            sidebar.settleSidebar()
            XCTAssertEqual(sidebar.scrollOffset, originalOffset, accuracy: 1,
                           "\(context): passive focus scroll offset \(originalOffset) -> \(sidebar.scrollOffset)")

            for inputClick in 1...2 {
                try sidebar.clickInputTerminal(click.pane)
                XCTAssertEqual(sidebar.model.selectedPane, click.pane)
                XCTAssertEqual(sidebar.scrollOffset, originalOffset, accuracy: 1,
                               "\(context), input click \(inputClick): focusing input must not scroll to the space")
                XCTAssertEqual(try sidebar.paneRowFrame("Agent 1").minY, originalAgentRow.minY, accuracy: 1,
                               "\(context), input click \(inputClick): the Agent row must stay in place")
                XCTAssertEqual(try sidebar.paneRowFrame("Terminal test1").minY, originalTerminalRow.minY, accuracy: 1,
                               "\(context), input click \(inputClick): the terminal row must stay in place")
                XCTAssertNil(sidebar.model.selectedSpace, "Input focus must preserve All Spaces")
                XCTAssertTrue(try sidebar.spaceRowIsSelected("All Spaces"), "The highlight must match the active filter")
            }
        }

        sidebar.scroll(.bottom)
        let manuallyChosenOffset = sidebar.scrollOffset
        sidebar.model.sessions[remote.id]?.agents = sidebar.model.session(remote.id).agents.map {
            $0.updatingStatus(.working)
        }
        sidebar.settleSidebar()
        XCTAssertEqual(sidebar.scrollOffset, manuallyChosenOffset, accuracy: 1,
                       "A background status refresh must not undo manual scrolling")
        XCTAssertFalse(sidebar.visibleSpaceRow(terminalSpace))

        sidebar.model.reveal(terminalRef)
        sidebar.settleSidebar()
        XCTAssertTrue(sidebar.visibleSpaceRow(terminalSpace), "Search and notification navigation must still reveal the same pane")
        XCTAssertFalse(try sidebar.spaceRowIsSelected(terminalSpace))
        XCTAssertNil(sidebar.model.selectedSpace)
        XCTAssertTrue(try sidebar.spaceRowIsSelected("All Spaces"), "The highlight must match the active filter")
    }

    func testRestoredRemoteTerminalRevealsOnceButRepeatedInputClicksPreserveScrolling() throws {
        let terminalRef = PaneRef(deviceID: remote.id, paneID: "term-pane-0")
        let sidebar = try SidebarHarness(spaces: 25, agents: 1, terminals: 1, device: remote,
                                         pinnedHeaders: false, configureModel: { model in
            model.sessions[self.remote.id]?.panes = [try self.terminal(in: "ws-24")]
            // Restore the right-hand terminal before the sidebar first mounts.
            model.selectedPane = terminalRef
        })
        sidebar.mountInputTerminals(for: [terminalRef])
        sidebar.settleSidebar()

        XCTAssertNotNil(sidebar.model.selectedTerminalEntry)
        XCTAssertTrue(sidebar.visibleSpaceRow("Space 25"))
        XCTAssertFalse(try sidebar.spaceRowIsSelected("Space 25"))
        XCTAssertNil(sidebar.model.selectedSpace)
        XCTAssertTrue(try sidebar.spaceRowIsSelected("All Spaces"), "The highlight must match the active filter")

        sidebar.scroll(.top)
        XCTAssertFalse(sidebar.visibleSpaceRow("Space 25"))
        let manuallyChosenOffset = sidebar.scrollOffset
        for _ in 1...2 {
            try sidebar.clickInputTerminal(terminalRef)
            XCTAssertEqual(sidebar.scrollOffset, manuallyChosenOffset, accuracy: 1)
            XCTAssertFalse(sidebar.visibleSpaceRow("Space 25"), "Input focus must respect manual sidebar scrolling")
        }
        XCTAssertFalse(try sidebar.spaceRowIsSelected("Space 25"))
        XCTAssertNil(sidebar.model.selectedSpace)
        XCTAssertTrue(try sidebar.spaceRowIsSelected("All Spaces"), "The highlight must match the active filter")
        XCTAssertEqual(sidebar.model.visibleSpaces.count, 25)
    }

    func testClickingSplitPaneInputsKeepsFlatSidebarStill() throws {
        try assertSplitPaneInputsKeepSidebarStill(grouped: false)
    }

    func testClickingSplitPaneInputsKeepsGroupedSidebarStill() throws {
        try assertSplitPaneInputsKeepSidebarStill(grouped: true)
    }

    private func assertSplitPaneInputsKeepSidebarStill(grouped: Bool) throws {
        UserDefaults.standard.set(grouped, forKey: SidebarDefaults.groupBySpaceKey)
        let workspace = grouped ? "ws-12" : "ws-0"
        let space = grouped ? "Space 13" : "Space 1"
        let agentRef = PaneRef(deviceID: remote.id, paneID: "pane-0")
        let terminalRef = PaneRef(deviceID: remote.id, paneID: "term-pane-0")
        let sidebar = try SidebarHarness(spaces: grouped ? 40 : 25, agents: 1, terminals: 1, device: remote,
                                         pinnedHeaders: false, height: grouped ? 800 : 600,
                                         configureModel: { model in
            model.sessions[self.remote.id]?.agents = [try self.decode(AgentInfo.self, [
                "agent": "claude", "name": "Agent 1", "workspace_id": workspace,
                "tab_id": "tab-0", "pane_id": "pane-0",
            ])]
            model.sessions[self.remote.id]?.panes = [try self.terminal(in: workspace, tabID: "tab-0")]
            model.showsTabLayout = true
            model.tabLayouts[TabRef(deviceID: self.remote.id, tabID: "tab-0")] = TabLayoutDescription(
                workspaceID: workspace, tabID: "tab-0", zoomed: false, focusedPaneID: agentRef.paneID,
                root: .split(direction: .right, ratio: 0.5,
                             first: .pane(paneID: agentRef.paneID), second: .pane(paneID: terminalRef.paneID)))
            model.selectedPane = agentRef
        })
        sidebar.mountInputTerminals(for: [agentRef, terminalRef])
        XCTAssertEqual(sidebar.model.visiblePaneRefs, Set([agentRef, terminalRef]))
        sidebar.scroll(grouped ? .offset(300) : .bottom)
        let originalOffset = sidebar.scrollOffset
        let originalAgentRow = try sidebar.paneRowFrame("Agent 1")
        let originalTerminalRow = try sidebar.paneRowFrame("Terminal test1")

        for (index, pane) in [terminalRef, terminalRef, agentRef, agentRef].enumerated() {
            try sidebar.clickInputTerminal(pane)
            XCTAssertEqual(sidebar.model.selectedPane, pane, "The clicked split pane must become selected")
            XCTAssertEqual(sidebar.scrollOffset, originalOffset, accuracy: 1,
                           "\(grouped ? "grouped" : "flat") split click \(index + 1): input focus must not scroll the sidebar")
            XCTAssertEqual(try sidebar.paneRowFrame("Agent 1").minY, originalAgentRow.minY, accuracy: 1)
            XCTAssertEqual(try sidebar.paneRowFrame("Terminal test1").minY, originalTerminalRow.minY, accuracy: 1)
            XCTAssertFalse(try sidebar.spaceRowIsSelected(space))
            XCTAssertNil(sidebar.model.selectedSpace)
            XCTAssertTrue(try sidebar.spaceRowIsSelected("All Spaces"), "The highlight must match the active filter")
        }
    }

    func testFilesDefersBackgroundSelectionRevealUntilTheTerminalReturns() throws {
        let sidebar = try SidebarHarness(spaces: 25, agents: 1, terminals: 1, device: remote,
                                         pinnedHeaders: false, configureModel: { model in
            model.sessions[self.remote.id]?.panes = [try self.terminal(in: "ws-24")]
            model.selectedPane = PaneRef(deviceID: self.remote.id, paneID: "pane-0")
        })
        sidebar.settleSidebar()
        sidebar.model.detailMode = .files
        sidebar.settleSidebar()
        sidebar.scroll(.top)
        let coveredOffset = sidebar.scrollOffset

        sidebar.model.selectedPane = PaneRef(deviceID: remote.id, paneID: "term-pane-0")
        sidebar.settleSidebar()
        XCTAssertEqual(sidebar.model.detailMode, .files)
        XCTAssertEqual(sidebar.scrollOffset, coveredOffset, accuracy: 1)
        XCTAssertFalse(sidebar.visibleSpaceRow("Space 25"), "Files still covers the newly selected terminal")

        sidebar.model.detailMode = .terminal
        sidebar.settleSidebar()
        XCTAssertTrue(sidebar.visibleSpaceRow("Space 25"))
        XCTAssertFalse(try sidebar.spaceRowIsSelected("Space 25"))
        XCTAssertNil(sidebar.model.selectedSpace)
        XCTAssertTrue(try sidebar.spaceRowIsSelected("All Spaces"), "The highlight must match the active filter")
    }

    func testSharedWorkspaceIDsRevealOnlyOwningSpaceWithoutChangingAllSpacesFilter() throws {
        let other = Device(name: "other-test-server", kind: .ssh(target: "other.invalid"))
        let sidebar = try SidebarHarness(spaces: 25, agents: 1, device: remote,
                                         pinnedHeaders: false, configureModel: { model in
            var state = DeviceSessionState()
            state.workspaces = [try self.decode(WorkspaceInfo.self, [
                "workspace_id": "ws-0", "number": 1, "label": "Other Space 1",
            ])]
            state.agents = [try self.decode(AgentInfo.self, [
                "agent": "claude", "name": "Other Agent 1", "workspace_id": "ws-0",
                "tab_id": "other-tab-0", "pane_id": "other-pane-0",
            ])]
            model.devices.append(other)
            model.sessions[other.id] = state
        })
        sidebar.model.selectedPane = PaneRef(deviceID: remote.id, paneID: "pane-0")
        sidebar.settleSidebar()
        XCTAssertFalse(try sidebar.spaceRowIsSelected("Space 1"))

        sidebar.model.reveal(PaneRef(deviceID: other.id, paneID: "other-pane-0"))
        sidebar.settleSidebar()
        XCTAssertTrue(sidebar.visibleSpaceRow("Other Space 1"))
        XCTAssertFalse(try sidebar.spaceRowIsSelected("Other Space 1"))
        XCTAssertNil(sidebar.model.selectedSpace)
        XCTAssertTrue(try sidebar.spaceRowIsSelected("All Spaces"), "The highlight must match the active filter")
        XCTAssertNil(sidebar.model.deviceFilter)
        XCTAssertEqual(sidebar.model.visibleAgents.count, 2)

        sidebar.scroll(.top)
        XCTAssertFalse(try sidebar.spaceRowIsSelected("Space 1"),
                       "The same workspace ID on another device must not share the highlight")
    }

    func testClickingAdjacentSpacesAndTerminalInputKeepsTheirRowsStill() throws {
        let agentRef = PaneRef(deviceID: remote.id, paneID: "pane-0")
        let terminalRef = PaneRef(deviceID: remote.id, paneID: "term-pane-0")
        let sidebar = try SidebarHarness(spaces: 25, agents: 1, terminals: 1, device: remote,
                                         pinnedHeaders: false, configureModel: { model in
            model.sessions[self.remote.id]?.agents = [try self.decode(AgentInfo.self, [
                "agent": "claude", "name": "Agent 1", "workspace_id": "ws-12",
                "tab_id": "tab-0", "pane_id": "pane-0",
            ])]
            model.sessions[self.remote.id]?.panes = [try self.terminal(in: "ws-13")]
        })
        sidebar.mountInputTerminals(for: [agentRef, terminalRef])
        sidebar.scroll(.offset(300))
        XCTAssertTrue(sidebar.visibleSpaceRow("Space 13"))
        XCTAssertTrue(sidebar.visibleSpaceRow("Space 14"))
        let originalOffset = sidebar.scrollOffset
        let originalAgentRow = try sidebar.spaceRowFrame("Space 13")
        let originalTerminalRow = try sidebar.spaceRowFrame("Space 14")

        let clicks: [(String, String, PaneRef)] = [
            ("Space 13", "ws-12", agentRef),
            ("Space 14", "ws-13", terminalRef),
            ("Space 14", "ws-13", terminalRef),
        ]
        for (title, workspaceID, pane) in clicks {
            try sidebar.clickSpaceTitle(title)
            sidebar.settleSidebar()

            XCTAssertEqual(sidebar.model.selectedSpace, SpaceRef(deviceID: remote.id, workspaceID: workspaceID))
            XCTAssertEqual(sidebar.model.selectedPane, pane, "Clicking the space must still switch the right-hand pane")
            XCTAssertTrue(try sidebar.spaceRowIsSelected(title))
            XCTAssertEqual(sidebar.scrollOffset, originalOffset, accuracy: 1,
                           "Clicking a visible space must not move the list under the pointer")
            XCTAssertEqual(try sidebar.spaceRowFrame("Space 13").minY, originalAgentRow.minY, accuracy: 1)
            XCTAssertEqual(try sidebar.spaceRowFrame("Space 14").minY, originalTerminalRow.minY, accuracy: 1)

            // Selecting the right-hand pane assigns first responder and then
            // delivers the same callback through SplitFocusTracker's KVO.
            sidebar.model.focusVisiblePane(pane)
            sidebar.settleSidebar()
            XCTAssertEqual(sidebar.scrollOffset, originalOffset, accuracy: 1,
                           "Programmatic terminal focus after a sidebar click must not trigger a second scroll")
            XCTAssertEqual(try sidebar.spaceRowFrame("Space 13").minY, originalAgentRow.minY, accuracy: 1)
            XCTAssertEqual(try sidebar.spaceRowFrame("Space 14").minY, originalTerminalRow.minY, accuracy: 1)
        }

        // The sidebar-click suppression must not survive leaving the terminal
        // and returning to the same selected pane.
        sidebar.model.detailMode = .files
        sidebar.settleSidebar()
        sidebar.scroll(.top)
        XCTAssertFalse(sidebar.visibleSpaceRow("Space 14"))
        sidebar.model.detailMode = .terminal
        sidebar.settleSidebar()
        XCTAssertTrue(sidebar.visibleSpaceRow("Space 14"), "Returning from Files must reveal the displayed terminal again")
        XCTAssertEqual(sidebar.model.selectedPane, terminalRef)

        // Search uses selectSpace's default navigation behavior. Its early
        // return for the already selected space must still reveal that space.
        try sidebar.clickSpaceTitle("Space 14")
        sidebar.scroll(.top)
        XCTAssertFalse(sidebar.visibleSpaceRow("Space 14"))
        sidebar.model.selectSpace(SpaceRef(deviceID: remote.id, workspaceID: "ws-13"))
        sidebar.settleSidebar()
        XCTAssertTrue(sidebar.visibleSpaceRow("Space 14"), "Navigating to the same space must not inherit the sidebar-click suppression")
        XCTAssertTrue(try sidebar.spaceRowIsSelected("Space 14"))
        XCTAssertEqual(sidebar.model.selectedPane, terminalRef)

        try sidebar.clickSpaceTitle("Space 14")
        sidebar.scroll(.top)
        XCTAssertFalse(sidebar.visibleSpaceRow("Space 14"))
        let manuallyChosenOffset = sidebar.scrollOffset
        try sidebar.clickInputTerminal(terminalRef)
        XCTAssertEqual(sidebar.scrollOffset, manuallyChosenOffset, accuracy: 1)
        XCTAssertFalse(sidebar.visibleSpaceRow("Space 14"), "Input focus must not repeat the navigation reveal")
        XCTAssertTrue(try sidebar.spaceRowIsSelected("Space 14"))
        XCTAssertEqual(sidebar.model.selectedPane, terminalRef)
    }

    func testRestoredPaneAndInputFocusKeepHighlightAlignedWithSpaceFilter() throws {
        let firstAgent = PaneRef(deviceID: remote.id, paneID: "pane-0")
        let secondAgent = PaneRef(deviceID: remote.id, paneID: "pane-1")
        let secondSpace = SpaceRef(deviceID: remote.id, workspaceID: "ws-1")
        let sidebar = try SidebarHarness(spaces: 2, agents: 2, terminals: 1, device: remote,
                                         pinnedHeaders: false, configureModel: { model in
            model.sessions[self.remote.id]?.agents = try (0..<2).map { index in
                try self.decode(AgentInfo.self, [
                    "agent": "claude", "name": "Agent \(index + 1)", "workspace_id": "ws-\(index)",
                    "tab_id": "tab-\(index)", "pane_id": "pane-\(index)",
                ])
            }
            model.sessions[self.remote.id]?.panes = [try self.terminal(in: "ws-0")]
            model.selectedPane = firstAgent
        })
        sidebar.mountInputTerminals(for: [firstAgent, secondAgent])
        sidebar.settleSidebar()

        XCTAssertEqual(sidebar.model.selectedPane, firstAgent, "Launch restores the right-hand pane")
        XCTAssertNil(sidebar.model.selectedSpace)
        XCTAssertEqual(sidebar.model.visibleAgents.count, 2)
        XCTAssertEqual(sidebar.model.visibleTerminals.count, 1)
        XCTAssertTrue(try sidebar.spaceRowIsSelected("All Spaces"))
        XCTAssertFalse(try sidebar.spaceRowIsSelected("Space 1"), "The restored pane's owner is not an active filter")
        XCTAssertFalse(try sidebar.spaceRowIsSelected("Space 2"))

        try sidebar.clickSpaceTitle("Space 2")
        XCTAssertEqual(sidebar.model.selectedSpace, secondSpace)
        XCTAssertEqual(sidebar.model.selectedPane, secondAgent)
        XCTAssertEqual(sidebar.model.visibleAgents.map(\.ref), [secondAgent])
        XCTAssertTrue(sidebar.model.visibleTerminals.isEmpty)
        XCTAssertTrue(try sidebar.spaceRowIsSelected("Space 2"))
        XCTAssertFalse(try sidebar.spaceRowIsSelected("All Spaces"))
        let filteredOffset = sidebar.scrollOffset
        for _ in 1...2 {
            try sidebar.clickInputTerminal(secondAgent)
            XCTAssertEqual(sidebar.model.selectedSpace, secondSpace)
            XCTAssertEqual(sidebar.model.visibleAgents.map(\.ref), [secondAgent])
            XCTAssertTrue(try sidebar.spaceRowIsSelected("Space 2"))
            XCTAssertFalse(try sidebar.spaceRowIsSelected("All Spaces"))
            XCTAssertEqual(sidebar.scrollOffset, filteredOffset, accuracy: 1)
        }

        try sidebar.clickSpaceTitle("All Spaces")
        XCTAssertNil(sidebar.model.selectedSpace)
        XCTAssertEqual(sidebar.model.selectedPane, secondAgent, "Clearing the filter keeps the displayed pane")
        XCTAssertEqual(sidebar.model.visibleAgents.count, 2)
        XCTAssertEqual(sidebar.model.visibleTerminals.count, 1)
        XCTAssertTrue(try sidebar.spaceRowIsSelected("All Spaces"))
        XCTAssertFalse(try sidebar.spaceRowIsSelected("Space 2"))
        let unfilteredOffset = sidebar.scrollOffset
        for _ in 1...2 {
            try sidebar.clickInputTerminal(secondAgent)
            XCTAssertNil(sidebar.model.selectedSpace)
            XCTAssertEqual(sidebar.model.selectedPane, secondAgent)
            XCTAssertEqual(sidebar.model.visibleAgents.count, 2)
            XCTAssertTrue(try sidebar.spaceRowIsSelected("All Spaces"))
            XCTAssertFalse(try sidebar.spaceRowIsSelected("Space 2"))
            XCTAssertEqual(sidebar.scrollOffset, unfilteredOffset, accuracy: 1)
        }
    }

    private func terminal(in workspaceID: String, tabID: String = "term-tab-0") throws -> PaneInfo {
        try decode(PaneInfo.self, ["pane_id": "term-pane-0", "terminal_id": "term-0",
                                  "workspace_id": workspaceID, "tab_id": tabID,
                                  "terminal_title": "Terminal test1"])
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: [String: Any]) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: json))
    }
}
