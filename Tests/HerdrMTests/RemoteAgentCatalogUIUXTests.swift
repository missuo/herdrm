import XCTest
import HerdrKit
@testable import herdrm

@MainActor
final class RemoteAgentCatalogUIUXTests: XCTestCase {
    private let remote = Device(name: "test-server", kind: .ssh(target: "test.invalid"))

    func testLocalChoicesRemainClickableWithAFullRecentHistory() throws {
        try checkChoicesWithRecentHistory(on: .local)
    }

    func testRemoteChoicesRemainClickableWithAFullRecentHistory() throws {
        try checkChoicesWithRecentHistory(on: remote)
    }

    private func checkChoicesWithRecentHistory(on device: Device) throws {
        let defaults = UserDefaults.standard
        let oldHistory = defaults.object(forKey: RecentAgentLaunches.defaultsKey)
        defer { defaults.set(oldHistory, forKey: RecentAgentLaunches.defaultsKey) }
        RecentAgentLaunches.save((1...RecentAgentLaunches.limit).map { index in
            RecentAgentLaunch(deviceID: device.id, kind: "claude", spaceLabel: "Recent project \(index)",
                              directory: nil, arguments: [], grazrAccountID: nil, date: Date())
        })
        let sidebar = try SidebarHarness(spaces: 1, agents: 0, device: device, sheets: true, pinnedHeaders: false)
        sidebar.model.sessions[device.id]?.agentCatalog = .loaded(kinds: ["claude", "codex"])

        try sidebar.chooseFromSpaceMenu("Space 1", String(localized: "New Agent…"))

        XCTAssertTrue(sidebar.sheetButtonNames.contains { $0.contains("Recent project") },
                      "known-yes: the full Recent list is shown: \(sidebar.sheetButtonNames)")
        XCTAssertTrue(sidebar.sheetButtonNames.contains("claude"), "\(sidebar.sheetButtonNames)")
        XCTAssertTrue(sidebar.sheetButtonNames.contains("codex"), "\(sidebar.sheetButtonNames)")
        try sidebar.clickSheetButton(named: "codex")
        let binary = HerdrService.binaryName(for: "codex")
        XCTAssertTrue(sidebar.sheetTexts.contains(String(localized: "Appended to \(binary). Defaults live in Settings → Agents.")),
                      "\(sidebar.sheetTexts)")
    }

    func testOpeningNewAgentShowsOnlyTheDetectedRemoteKinds() throws {
        let sidebar = try SidebarHarness(spaces: 1, agents: 0, device: remote, sheets: true, pinnedHeaders: false)
        sidebar.model.sessions[remote.id]?.agentCatalog = .loaded(kinds: ["codex"])

        try sidebar.chooseFromSpaceMenu("Space 1", String(localized: "New Agent…"))

        XCTAssertTrue(sidebar.sheetButtonNames.contains("codex"), "\(sidebar.sheetButtonNames)")
        XCTAssertFalse(sidebar.sheetButtonNames.contains("claude"), "\(sidebar.sheetButtonNames)")
        XCTAssertFalse(sidebar.sheetButtonNames.contains("gemini"), "\(sidebar.sheetButtonNames)")
    }

    func testEmptyRemoteCatalogExplainsThatNoCLIWasFound() throws {
        let sidebar = try SidebarHarness(spaces: 1, agents: 0, device: remote, sheets: true, pinnedHeaders: false)
        sidebar.model.sessions[remote.id]?.agentCatalog = .loaded(kinds: [])

        try sidebar.chooseFromSpaceMenu("Space 1", String(localized: "New Agent…"))

        XCTAssertTrue(sidebar.sheetTexts.contains(String(localized: "No supported agent CLI was found on this server.")), "\(sidebar.sheetTexts)")
    }
}
