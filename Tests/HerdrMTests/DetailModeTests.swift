import HerdrKit
import XCTest
@testable import herdrm

@MainActor
final class DetailModeTests: XCTestCase {
    /// A model with a selected local Claude agent, so the covered-terminal gates have something to hide.
    private func modelWithSelectedClaudeAgent() throws -> AppModel {
        let model = AppModel()
        model.devices = [Device.local]
        var state = DeviceSessionState()
        let json: [String: Any] = ["agent": "claude", "name": "Agent 1", "workspace_id": "ws-0", "tab_id": "tab-0", "pane_id": "pane-0"]
        let data = try JSONSerialization.data(withJSONObject: json)
        state.agents = [try JSONDecoder().decode(AgentInfo.self, from: data)]
        model.sessions[Device.local.id] = state
        model.selectedPane = PaneRef(deviceID: Device.local.id, paneID: "pane-0")
        return model
    }

    func testFileManagerShimMapsToDetailMode() {
        let model = AppModel()
        model.isFileManagerActive = true
        XCTAssertEqual(model.detailMode, .files)
        XCTAssertTrue(model.isDetailCovered)
        model.isFileManagerActive = false
        XCTAssertEqual(model.detailMode, .terminal)
        XCTAssertFalse(model.isDetailCovered)
    }

    func testOpenProjectCoversTheTerminalAndSelectingAnAgentUncoversIt() throws {
        let model = try modelWithSelectedClaudeAgent()
        XCTAssertNotNil(model.statsDevice, "precondition: the selected local agent has stats")
        model.openProject(nil)
        XCTAssertEqual(model.detailMode, .project)
        XCTAssertFalse(model.isFileManagerActive)
        XCTAssertNil(model.statsDevice)
        model.selectAgent(PaneRef(deviceID: Device.local.id, paneID: "w1:p1"))
        XCTAssertEqual(model.detailMode, .terminal)
    }

    func testOpenProjectShowsTheGivenSpaceWithoutFilteringTheSidebar() {
        let model = AppModel()
        let space = SpaceRef(deviceID: Device.local.id, workspaceID: "ws-1")
        model.selectedShellID = UUID()
        model.openProject(space)
        XCTAssertEqual(model.projectSpace, space)
        XCTAssertNil(model.selectedSpace, "opening Project leaves the sidebar's Space filter alone")
        XCTAssertNil(model.selectedShellID)
        XCTAssertEqual(model.detailMode, .project)
    }

    func testOpenProjectForAPaneUsesItsSpaceAndCloseProjectReturnsToIt() throws {
        let model = try modelWithSelectedClaudeAgent()
        let entry = try XCTUnwrap(model.selectedAttachedEntry)
        model.openProject(for: entry)
        XCTAssertEqual(model.detailMode, .project)
        XCTAssertEqual(model.projectSpace, SpaceRef(deviceID: Device.local.id, workspaceID: "ws-0"))
        XCTAssertNil(model.selectedSpace)
        model.closeProject()
        XCTAssertEqual(model.detailMode, .terminal)
        XCTAssertNil(model.projectSpaceOverride, "leaving Project forgets the Space it was opened on")
        XCTAssertEqual(model.selectedPane, PaneRef(deviceID: Device.local.id, paneID: "pane-0"))
        XCTAssertNotNil(model.selectedAttachedEntry)
        model.closeProject()
        XCTAssertEqual(model.detailMode, .terminal, "a no-op outside project mode")
    }

    func testProjectModeHidesTheClaudeHistory() throws {
        let model = try modelWithSelectedClaudeAgent()
        XCTAssertTrue(model.isClaudeHistorySelected, "precondition: a Claude agent is selected")
        model.openProject(nil)
        XCTAssertFalse(model.isClaudeHistorySelected)
    }

    func testProjectSpaceFallsBackToTheSelectedPanesWorkspace() throws {
        let model = try modelWithSelectedClaudeAgent()
        XCTAssertNil(model.selectedSpace)
        XCTAssertEqual(model.projectSpace, SpaceRef(deviceID: Device.local.id, workspaceID: "ws-0"))
        let filter = SpaceRef(deviceID: Device.local.id, workspaceID: "ws-9")
        model.selectedSpace = filter
        XCTAssertEqual(model.projectSpace, filter)
        model.selectedSpace = nil
        model.selectedPane = nil
        XCTAssertNil(model.projectSpace)
    }
}
