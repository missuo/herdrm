import Foundation
import XCTest
@testable import HerdrKit

final class RecentPanesTests: XCTestCase {
    private let local = UUID()
    private let mini = UUID()

    private func pane(_ id: String, on device: UUID? = nil) -> RecentPane {
        RecentPane(deviceID: device ?? local, paneID: id)
    }

    // MARK: - Recording

    func testSelectingAPaneMovesItToTheFront() {
        var list: [RecentPane] = []
        list = RecentPanes.recording(pane("a"), into: list)
        list = RecentPanes.recording(pane("b"), into: list)
        list = RecentPanes.recording(pane("c"), into: list)
        list = RecentPanes.recording(pane("a"), into: list)
        XCTAssertEqual(list, [pane("a"), pane("c"), pane("b")])
    }

    func testSamePaneIDOnTwoDevicesAreDifferentEntries() {
        var list: [RecentPane] = []
        list = RecentPanes.recording(pane("w1:p1", on: local), into: list)
        list = RecentPanes.recording(pane("w1:p1", on: mini), into: list)
        XCTAssertEqual(list, [pane("w1:p1", on: mini), pane("w1:p1", on: local)])
    }

    func testTheListIsCapped() {
        var list: [RecentPane] = []
        for i in 0..<(RecentPanes.limit + 5) {
            list = RecentPanes.recording(pane("p\(i)"), into: list)
        }
        XCTAssertEqual(list.count, RecentPanes.limit)
        XCTAssertEqual(list.first, pane("p\(RecentPanes.limit + 4)"))
    }

    // MARK: - Pruning

    func testClosedPanesDropOutOnlyForTheDeviceThatReportedThem() {
        let list = [pane("a"), pane("x", on: mini), pane("b"), pane("c")]
        let pruned = RecentPanes.pruning(list, deviceID: local, keeping: ["a", "c"])
        XCTAssertEqual(pruned, [pane("a"), pane("x", on: mini), pane("c")])
    }

    func testRemovingADeviceDropsAllOfItsPanes() {
        let list = [pane("a"), pane("x", on: mini), pane("y", on: mini)]
        XCTAssertEqual(RecentPanes.removingDevice(mini, from: list), [pane("a")])
    }

    // MARK: - Persistence

    func testTheOrderSurvivesARelaunch() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "RecentPanesTests-\(UUID())"))
        XCTAssertEqual(RecentPanes.load(from: defaults), [])
        let list = [pane("b"), pane("x", on: mini), pane("a")]
        RecentPanes.save(list, to: defaults)
        XCTAssertEqual(RecentPanes.load(from: defaults), list)
    }

    // MARK: - Ordering what the switcher lists

    func testRecentPanesComeFirstThenTheRestInSidebarOrder() {
        let all = ["a", "b", "c", "d", "e"]
        let ordered = RecentPanes.ordered(all, recent: ["d", "gone", "b"])
        XCTAssertEqual(ordered, ["d", "b", "a", "c", "e"])
    }
}

final class RecentSwitcherTests: XCTestCase {
    func testOneTapTargetsThePreviousPane() throws {
        let switcher = try XCTUnwrap(RecentSwitcher(items: ["a", "b", "c"], current: "a"))
        XCTAssertEqual(switcher.selection, "b")
    }

    func testEachTabStepsFurtherBackAndWraps() throws {
        var switcher = try XCTUnwrap(RecentSwitcher(items: ["a", "b", "c"], current: "a"))
        switcher.step()
        XCTAssertEqual(switcher.selection, "c")
        switcher.step()
        XCTAssertEqual(switcher.selection, "a")
        switcher.step()
        XCTAssertEqual(switcher.selection, "b")
    }

    func testShiftTabStepsForwardAndWraps() throws {
        var switcher = try XCTUnwrap(RecentSwitcher(items: ["a", "b", "c"], current: "a"))
        switcher.step(backward: true)
        XCTAssertEqual(switcher.selection, "a")
        switcher.step(backward: true)
        XCTAssertEqual(switcher.selection, "c")
    }

    func testOpeningWithShiftTabStartsAtTheOldestPane() throws {
        let switcher = try XCTUnwrap(RecentSwitcher(items: ["a", "b", "c"], current: "a", backward: true))
        XCTAssertEqual(switcher.selection, "c")
    }

    /// With a local shell or the file manager showing, no pane in the list is
    /// on screen, so the most recent pane is already "back".
    func testWithNothingCurrentTheFirstTapTargetsTheMostRecentPane() throws {
        let switcher = try XCTUnwrap(RecentSwitcher(items: ["a", "b"], current: nil))
        XCTAssertEqual(switcher.selection, "a")
    }

    func testNothingToSwitchToOpensNoSwitcher() {
        XCTAssertNil(RecentSwitcher<String>(items: [], current: nil))
        XCTAssertNil(RecentSwitcher(items: ["a"], current: "a"))
    }

    func testHighlightCanBeMovedToAnEntryDirectly() throws {
        var switcher = try XCTUnwrap(RecentSwitcher(items: ["a", "b", "c"], current: "a"))
        switcher.highlight("c")
        XCTAssertEqual(switcher.selection, "c")
        switcher.highlight("missing")
        XCTAssertEqual(switcher.selection, "c")
    }
}
