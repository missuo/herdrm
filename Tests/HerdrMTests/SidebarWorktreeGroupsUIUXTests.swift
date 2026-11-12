import AppKit
import HerdrKit
import XCTest
@testable import herdrm

/// #74: a repository's linked worktrees list under its main checkout, the way
/// herdr's sidebar groups them. Fake names only (test1, test2, …).
@MainActor
final class SidebarWorktreeGroupsUIUXTests: XCTestCase {
    private static func workspace(_ id: String, _ label: String, repo: String? = nil, linked: Bool = false) throws -> WorkspaceInfo {
        var json: [String: Any] = ["workspace_id": id, "number": 1, "label": label]
        if let repo {
            json["worktree"] = [
                "repo_key": "/Users/test/\(repo)/.git", "repo_name": repo, "repo_root": "/Users/test/\(repo)",
                "checkout_path": "/Users/test/\(repo)-\(label)", "is_linked_worktree": linked,
            ]
        }
        return try JSONDecoder().decode(WorkspaceInfo.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func harness() throws -> SidebarHarness {
        try SidebarHarness(spaces: 4, agents: 1, pinnedHeaders: false, height: 700) { model in
            let id = try XCTUnwrap(model.devices.first).id
            model.sessions[id]?.workspaces = [
                try Self.workspace("ws-0", "test1"),
                try Self.workspace("ws-1", "test2-fix", repo: "test2", linked: true),
                try Self.workspace("ws-2", "test2", repo: "test2"),
                try Self.workspace("ws-3", "test3"),
                try Self.workspace("ws-4", "test2-feature", repo: "test2", linked: true),
            ]
        }
    }

    func testWorktreesSitIndentedUnderTheirMainCheckout() throws {
        let sidebar = try harness()
        sidebar.settleSidebar()
        XCTAssertEqual(sidebar.model.visibleSpaces.map(\.workspace.label),
                       ["test1", "test2", "test2-fix", "test2-feature", "test3"])

        let main = try sidebar.spaceRowFrame("test2")
        let fix = try sidebar.spaceRowFrame("test2-fix")
        let feature = try sidebar.spaceRowFrame("test2-feature")
        let next = try sidebar.spaceRowFrame("test3")
        // Rows run main → worktrees → the next space, top to bottom.
        let ys = [main, fix, feature, next].map(\.midY)
        XCTAssertEqual(ys, ys.sorted(), "\(ys)")
        // The worktrees' titles start further in than their main checkout's.
        XCTAssertGreaterThan(fix.minX, main.minX)
        XCTAssertEqual(fix.minX, feature.minX, accuracy: 0.5)
        XCTAssertEqual(main.minX, next.minX, accuracy: 0.5)

        // VoiceOver hears which repository a worktree belongs to.
        XCTAssertTrue(sidebar.actionRowNames().contains("test2-fix, worktree of test2"), "\(sidebar.actionRowNames())")

        let screenshot = FileManager.default.temporaryDirectory.appendingPathComponent("worktree-groups-demo.png")
        try sidebar.writeSnapshot(to: screenshot)
        let attachment = XCTAttachment(contentsOfFile: screenshot)
        attachment.name = "Worktree groups (fake test1–test3)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testClickingAWorktreeSelectsThatSpace() throws {
        let sidebar = try harness()
        sidebar.settleSidebar()
        try sidebar.clickSpaceTitle("test2-feature")
        XCTAssertEqual(sidebar.model.selectedSpace?.workspaceID, "ws-4")
        XCTAssertTrue(try sidebar.spaceRowIsSelected("test2-feature"))
    }
}
