import Foundation
import XCTest
@testable import HerdrKit

final class ProjectRootResolverTests: XCTestCase {
    private let home = "/home/dev"

    func testWorktreeResolvesToMainRoot() {
        let roots = [
            ProbeRoot(
                cwd: "/home/dev/acme-app/frontend",
                toplevel: "/home/dev/acme-app",
                commonDir: "/home/dev/acme-app/.git"
            ),
            ProbeRoot(
                cwd: "/home/dev/acme-app/.claude/worktrees/conntest",
                toplevel: "/home/dev/acme-app/.claude/worktrees/conntest",
                commonDir: "/home/dev/acme-app/.git"
            ),
        ]
        let resolved = ProjectRootResolver.resolve(roots: roots, focusedCwd: nil, home: home, override: nil)
        XCTAssertEqual(resolved?.root, "/home/dev/acme-app")
        XCTAssertEqual(resolved?.worktreeRoots.contains("/home/dev/acme-app"), true)
        XCTAssertEqual(resolved?.worktreeRoots.contains("/home/dev/acme-app/.claude/worktrees/conntest"), true)
    }

    func testMostFrequentMainRootWinsTieToFocused() {
        let roots = [
            ProbeRoot(cwd: "/home/dev/alpha/src", toplevel: "/home/dev/alpha", commonDir: "/home/dev/alpha/.git"),
            ProbeRoot(cwd: "/home/dev/beta/src", toplevel: "/home/dev/beta", commonDir: "/home/dev/beta/.git"),
        ]
        let resolved = ProjectRootResolver.resolve(
            roots: roots, focusedCwd: "/home/dev/beta/src", home: home, override: nil
        )
        XCTAssertEqual(resolved?.root, "/home/dev/beta")
    }

    func testNonGitUsesCommonAncestorUnlessHomeOrSlash() {
        let sibling = [
            ProbeRoot(cwd: "/srv/x/a"),
            ProbeRoot(cwd: "/srv/x/b"),
        ]
        XCTAssertEqual(
            ProjectRootResolver.resolve(roots: sibling, focusedCwd: nil, home: home, override: nil)?.root,
            "/srv/x"
        )

        let underHome = [
            ProbeRoot(cwd: "/home/dev/a"),
            ProbeRoot(cwd: "/home/dev/b"),
        ]
        XCTAssertEqual(
            ProjectRootResolver.resolve(roots: underHome, focusedCwd: "/home/dev/b", home: home, override: nil)?.root,
            "/home/dev/b"
        )

        let slashOnly = [
            ProbeRoot(cwd: "/a"),
            ProbeRoot(cwd: "/b"),
        ]
        XCTAssertEqual(
            ProjectRootResolver.resolve(roots: slashOnly, focusedCwd: "/b", home: home, override: nil)?.root,
            "/b"
        )
    }

    func testMostFrequentMainRootWinsOverFocused() {
        let roots = [
            ProbeRoot(cwd: "/home/dev/beta/src", toplevel: "/home/dev/beta", commonDir: "/home/dev/beta/.git"),
            ProbeRoot(cwd: "/home/dev/alpha/src", toplevel: "/home/dev/alpha", commonDir: "/home/dev/alpha/.git"),
            ProbeRoot(cwd: "/home/dev/alpha/lib", toplevel: "/home/dev/alpha", commonDir: "/home/dev/alpha/.git"),
        ]
        let resolved = ProjectRootResolver.resolve(
            roots: roots, focusedCwd: "/home/dev/beta/src", home: home, override: nil
        )
        XCTAssertEqual(resolved?.root, "/home/dev/alpha")
    }

    func testRootPrefixIsComponentWise() {
        let roots = [
            ProbeRoot(cwd: "/home/dev/acme-app/src"),
            ProbeRoot(cwd: "/home/dev/acme-app2/x"),
        ]
        let resolved = ProjectRootResolver.resolve(
            roots: roots, focusedCwd: "/home/dev/acme-app2/x", home: home, override: nil
        )
        XCTAssertEqual(resolved?.root, "/home/dev/acme-app2/x")
        XCTAssertEqual(resolved?.worktreeRoots, ["/home/dev/acme-app2/x"])
    }

    func testTrailingSlashInputsResolveLikeCleanPaths() {
        let roots = [
            ProbeRoot(
                cwd: "/home/dev/acme-app/",
                toplevel: "/home/dev/acme-app/",
                commonDir: "/home/dev/acme-app/.git/"
            ),
        ]
        let resolved = ProjectRootResolver.resolve(roots: roots, focusedCwd: nil, home: "/home/dev/", override: nil)
        XCTAssertEqual(resolved?.root, "/home/dev/acme-app")
        XCTAssertEqual(resolved?.worktreeRoots, ["/home/dev/acme-app"])
    }

    func testNoRootsAndNoOverrideIsNil() {
        XCTAssertNil(ProjectRootResolver.resolve(roots: [], focusedCwd: nil, home: home, override: nil))
    }

    func testWorktreeRootsAreSortedRegardlessOfPaneOrder() {
        let main = ProbeRoot(cwd: "/home/dev/acme-app", toplevel: "/home/dev/acme-app", commonDir: "/home/dev/acme-app/.git")
        let worktree = ProbeRoot(
            cwd: "/home/dev/acme-app/.claude/worktrees/conntest",
            toplevel: "/home/dev/acme-app/.claude/worktrees/conntest",
            commonDir: "/home/dev/acme-app/.git"
        )
        let forward = ProjectRootResolver.resolve(roots: [main, worktree], focusedCwd: nil, home: home, override: nil)
        let reverse = ProjectRootResolver.resolve(roots: [worktree, main], focusedCwd: nil, home: home, override: nil)
        XCTAssertEqual(forward?.worktreeRoots, reverse?.worktreeRoots)
        XCTAssertEqual(forward?.worktreeRoots, forward?.worktreeRoots.sorted())
    }

    func testOverrideWins() {
        let roots = [ProbeRoot(cwd: "/home/dev/acme-app/frontend", toplevel: "/home/dev/acme-app")]
        let resolved = ProjectRootResolver.resolve(roots: roots, focusedCwd: nil, home: home, override: "/opt/other")
        XCTAssertEqual(resolved?.root, "/opt/other")
        XCTAssertEqual(resolved?.worktreeRoots, ["/opt/other"])
    }

    func testIdentityTokensStripVersions() {
        func tokens(_ root: String) -> [String] {
            ProjectIdentity(deviceID: UUID(), root: root, worktreeRoots: [root]).tokens
        }
        XCTAssertEqual(tokens("/home/dev/acme-app"), ["acme", "app"])
        XCTAssertEqual(tokens("/home/dev/foo-v2"), ["foo"])
        XCTAssertEqual(tokens("/home/dev/bar_2024"), ["bar"])
    }

    func testNonGitCwdEqualToHomeIsNotAProject() {
        XCTAssertNil(ProjectRootResolver.resolve(
            roots: [ProbeRoot(cwd: "/home/dev")], focusedCwd: "/home/dev", home: home, override: nil))
        XCTAssertNil(ProjectRootResolver.resolve(
            roots: [ProbeRoot(cwd: "/home/dev/"), ProbeRoot(cwd: "/")], focusedCwd: "/", home: home, override: nil))
        // A real directory next to a home pane wins, whichever pane is focused.
        let resolved = ProjectRootResolver.resolve(
            roots: [ProbeRoot(cwd: "/home/dev"), ProbeRoot(cwd: "/home/dev/scratch")],
            focusedCwd: "/home/dev", home: home, override: nil)
        XCTAssertEqual(resolved?.root, "/home/dev/scratch")
        // An explicit override still wins.
        XCTAssertEqual(
            ProjectRootResolver.resolve(roots: [ProbeRoot(cwd: "/home/dev")], focusedCwd: nil, home: home, override: "/home/dev")?.root,
            "/home/dev")
    }
}
