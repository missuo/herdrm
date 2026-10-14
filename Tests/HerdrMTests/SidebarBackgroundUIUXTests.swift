import AppKit
import XCTest
@testable import herdrm

/// The sidebar keeps one color whatever sits behind the window, so its text and
/// header buttons stay readable over a bright desktop or a white window.
///
/// Measured 2026-10-15 on macOS 27 (a `.sidebar` material over a white and a
/// black window, one screen pixel each, gray value): `.active` dark 81 / 36,
/// light 223 / 201; `.inactive` dark 42 / 45, light 231 / 232.
@MainActor
final class SidebarBackgroundUIUXTests: XCTestCase {
    func testNoSidebarSurfaceShowsWhatIsBehindTheWindow() throws {
        let sidebar = try SidebarHarness(spaces: 14, agents: 20, terminals: 20)
        let surfaces = sidebar.materialSurfaces

        XCTAssertGreaterThanOrEqual(surfaces.count, 1 + SidebarHarness.Header.allCases.count, "the body and each section header")
        let blending = surfaces.filter { $0.blending == .behindWindow && $0.state != .inactive }
        XCTAssertTrue(blending.isEmpty, "\(blending.count) of \(surfaces.count) surfaces blend what is behind the window")
    }
}
