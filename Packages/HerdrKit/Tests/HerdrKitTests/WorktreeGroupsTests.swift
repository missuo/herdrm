import XCTest
@testable import HerdrKit

final class WorktreeGroupsTests: XCTestCase {
    private func ws(_ id: String, repo: String? = nil, linked: Bool = false) -> WorkspaceInfo {
        WorkspaceInfo(
            workspaceID: id, number: 0, label: id, focused: false, paneCount: nil, tabCount: nil,
            activeTabID: nil, agentStatusRaw: nil,
            worktree: repo.map {
                WorkspaceWorktree(repoKey: "/r/\($0)/.git", repoName: $0, repoRoot: "/r/\($0)",
                                  checkoutPath: "/r/\($0)-\(id)", isLinkedWorktree: linked)
            }
        )
    }

    private func layout(_ workspaces: [WorkspaceInfo]) -> [String] {
        WorktreeGroups.entries(workspaces).map { entry in
            let id = workspaces[entry.index].workspaceID
            return entry.indented ? (entry.lastChild ? "└" : "├") + id : id
        }
    }

    func testDecodesHerdrsWorktreeField() throws {
        let json = #"""
        {"workspace_id":"w2","number":1,"label":"feat-x","worktree":{"repo_key":"/p/gost/.git","repo_name":"gost",
         "repo_root":"/p/gost","checkout_path":"/p/gost-feat-x","is_linked_worktree":true}}
        """#
        let workspace = try JSONDecoder().decode(WorkspaceInfo.self, from: Data(json.utf8))
        XCTAssertEqual(workspace.worktree?.repoKey, "/p/gost/.git")
        XCTAssertEqual(workspace.worktree?.isLinkedWorktree, true)
        let plain = try JSONDecoder().decode(WorkspaceInfo.self, from: Data(#"{"workspace_id":"w1","number":1,"label":"a"}"#.utf8))
        XCTAssertNil(plain.worktree)
    }

    /// herdr's sidebar: worktrees under their main checkout, the group where
    /// its first member is, other workspaces untouched.
    func testWorktreesListUnderTheirMainCheckout() {
        let workspaces = [
            ws("a"), ws("wt1", repo: "gost", linked: true), ws("main", repo: "gost"),
            ws("b"), ws("wt2", repo: "gost", linked: true),
        ]
        XCTAssertEqual(layout(workspaces), ["a", "main", "├wt1", "└wt2", "b"])
    }

    func testWithoutBothSidesOpenNothingGroups() {
        XCTAssertEqual(layout([ws("wt1", repo: "gost", linked: true), ws("a"), ws("wt2", repo: "gost", linked: true)]),
                       ["wt1", "a", "wt2"])
        XCTAssertEqual(layout([ws("main", repo: "gost"), ws("a")]), ["main", "a"])
    }

    func testTwoRepositoriesGroupSeparately() {
        let workspaces = [
            ws("g", repo: "gost"), ws("k", repo: "koe"), ws("kw", repo: "koe", linked: true),
            ws("gw", repo: "gost", linked: true),
        ]
        XCTAssertEqual(layout(workspaces), ["g", "└gw", "k", "└kw"])
    }

    func testDraggingAMainCheckoutMovesItsWorktreesToo() throws {
        let workspaces = [ws("a"), ws("main", repo: "gost"), ws("wt", repo: "gost", linked: true), ws("b")]
        XCTAssertEqual(WorktreeGroups.block(of: "main", in: workspaces), ["main", "wt"])
        XCTAssertEqual(WorktreeGroups.block(of: "wt", in: workspaces), ["wt"])

        let plan = try XCTUnwrap(WorktreeGroups.plan(moving: "main", onto: "a", placeAfter: false, workspaces: workspaces))
        XCTAssertEqual(plan, WorkspaceReorder.Plan(workspaceIDs: ["main", "wt"], beforeWorkspaceID: "a"))
    }

    func testADropOnAGroupLandsBeforeOrAfterTheWholeGroup() throws {
        let workspaces = [ws("b"), ws("main", repo: "gost"), ws("wt", repo: "gost", linked: true), ws("a")]
        // On the lower half of main (whose next row is its worktree): after
        // the whole group, never between main and wt.
        let after = try XCTUnwrap(WorktreeGroups.plan(moving: "b", onto: "main", placeAfter: true, workspaces: workspaces))
        XCTAssertEqual(after, WorkspaceReorder.Plan(workspaceIDs: ["b"], beforeWorkspaceID: "a"))
        // On the upper half of the worktree: before the group.
        let tail = [ws("main", repo: "gost"), ws("wt", repo: "gost", linked: true), ws("a"), ws("b")]
        let before = try XCTUnwrap(WorktreeGroups.plan(moving: "b", onto: "wt", placeAfter: false, workspaces: tail))
        XCTAssertEqual(before, WorkspaceReorder.Plan(workspaceIDs: ["b"], beforeWorkspaceID: "main"))
        // Already right after the group: nothing to do.
        XCTAssertNil(WorktreeGroups.plan(moving: "a", onto: "wt", placeAfter: true, workspaces: tail))
    }

    func testAWorktreeReordersWithinItsGroup() throws {
        let workspaces = [ws("main", repo: "gost"), ws("w1", repo: "gost", linked: true), ws("w2", repo: "gost", linked: true)]
        let plan = try XCTUnwrap(WorktreeGroups.plan(moving: "w2", onto: "w1", placeAfter: false, workspaces: workspaces))
        XCTAssertEqual(plan, WorkspaceReorder.Plan(workspaceIDs: ["w2"], beforeWorkspaceID: "w1"))
        let moved = WorkspaceReorder.applying(workspaces, id: \.workspaceID, plan: plan)
        XCTAssertEqual(layout(moved), ["main", "├w2", "└w1"])
    }

    func testDroppingAGroupOnItselfDoesNothing() {
        let workspaces = [ws("main", repo: "gost"), ws("wt", repo: "gost", linked: true)]
        XCTAssertNil(WorktreeGroups.plan(moving: "main", onto: "wt", placeAfter: true, workspaces: workspaces))
    }
}
