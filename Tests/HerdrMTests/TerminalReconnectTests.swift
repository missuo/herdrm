import AppKit
import SwiftUI
import HerdrKit
import XCTest
@testable import herdrm

@MainActor
final class TerminalReconnectTests: XCTestCase {
    func testOneClickReconnectsAllDroppedTerminalsOnTheSameDevice() throws {
        try checkRecovery(exitCode: 255)
    }

    func testNormalExitReconnectsOnlyTheChosenTerminal() throws {
        try checkRecovery(exitCode: 0)
    }

    private func checkRecovery(exitCode: Int32) throws {
        let device = Device(name: "test-server", kind: .ssh(target: "test.invalid"))
        let sidebar = try SidebarHarness(spaces: 1, agents: 4, terminals: 1, device: device,
                                         pinnedHeaders: false, width: 600)
        let agents = sidebar.model.visibleAgents.map { AppModel.AttachedEntry.agent($0) }
        let shell = AppModel.AttachedEntry.terminal(try XCTUnwrap(sidebar.model.visibleTerminals.first))
        let otherDevice = Device(name: "other-server", kind: .ssh(target: "other.invalid"))
        let otherSidebar = try SidebarHarness(spaces: 1, agents: 1, device: otherDevice, pinnedHeaders: false)
        let other = AppModel.AttachedEntry.agent(try XCTUnwrap(otherSidebar.model.visibleAgents.first))
        var ended: [String: Int32?] = [agents[0].id: exitCode, agents[1].id: 255, agents[2].id: 0, shell.id: 255, other.id: 255]
        var retries: [String: Int] = [agents[1].id: 2]
        sidebar.showReconnectOverlay(TerminalReconnectOverlay(
            entry: agents[0], sessions: agents + [shell, other],
            endedAttach: Binding(get: { ended }, set: { ended = $0 }),
            attachRetry: Binding(get: { retries }, set: { retries = $0 })))
        try sidebar.clickAction(named: String(localized: exitCode == 255 ? "Reconnect device terminals" : "Reconnect"))
        XCTAssertEqual(retries[agents[0].id], 1)
        XCTAssertTrue(ended[agents[0].id] == nil)
        XCTAssertEqual(retries[agents[1].id], exitCode == 255 ? 3 : 2)
        XCTAssertEqual(retries[shell.id], exitCode == 255 ? 1 : nil)
        XCTAssertEqual(ended[agents[1].id] == nil, exitCode == 255)
        XCTAssertEqual(ended[shell.id] == nil, exitCode == 255)
        XCTAssertTrue(retries[agents[2].id] == nil, "A normally closed terminal must stay closed")
        XCTAssertEqual(ended[agents[2].id] ?? nil, 0)
        XCTAssertTrue(retries[agents[3].id] == nil, "A healthy terminal must not be reattached")
        XCTAssertTrue(retries[other.id] == nil, "Other devices must stay untouched")
        XCTAssertEqual(ended[other.id] ?? nil, 255)
    }
}
