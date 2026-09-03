import XCTest
@testable import HerdrKit

final class TabReorderTests: XCTestCase {
    private let order = ["t1", "t2", "t3"]

    func testDropOnEarlierRowInsertsBeforeIt() {
        XCTAssertEqual(
            TabReorder.insertIndex(moving: "t2", onto: "t1", placeAfter: false, orderedIDs: order),
            0
        )
    }

    func testDropOnLowerHalfOfLastRowAppends() {
        // Original-list coordinates: herdr subtracts one itself for a forward
        // move, so append sends the full count, not count - 1.
        XCTAssertEqual(
            TabReorder.insertIndex(moving: "t1", onto: "t3", placeAfter: true, orderedIDs: order),
            3
        )
    }

    func testForwardDropBeforeALaterRowUsesItsOriginalIndex() {
        // [t1, t2, t3, t4], t1 dropped on the upper half of t4 → [t2, t3, t1, t4].
        // herdr: remove t1, insert at 3 - 1 = 2.
        XCTAssertEqual(
            TabReorder.insertIndex(
                moving: "t1", onto: "t4", placeAfter: false,
                orderedIDs: ["t1", "t2", "t3", "t4"]
            ),
            3
        )
    }

    func testDropOnLowerHalfWhenNextIsTheDraggedRowIsNoOp() {
        XCTAssertNil(
            TabReorder.insertIndex(moving: "t2", onto: "t1", placeAfter: true, orderedIDs: order)
        )
    }

    func testAlreadyImmediatelyBeforeTheTargetIsNoOp() {
        XCTAssertNil(
            TabReorder.insertIndex(moving: "t1", onto: "t2", placeAfter: false, orderedIDs: order)
        )
    }

    func testMoveLastToFront() {
        XCTAssertEqual(
            TabReorder.insertIndex(moving: "t3", onto: "t1", placeAfter: false, orderedIDs: order),
            0
        )
    }

    func testSnapshotArrayOrderBeatsTabNumber() {
        let workspaces = [
            WorkspaceInfo(
                workspaceID: "wD", number: 1, label: "herdrm",
                focused: true, paneCount: 2, tabCount: 2,
                activeTabID: "wD:t5", agentStatusRaw: nil
            ),
        ]
        let tabs = [
            TabInfo(
                tabID: "wD:t5", workspaceID: "wD", number: 5, label: "5",
                focused: true, paneCount: 1, agentStatusRaw: nil
            ),
            TabInfo(
                tabID: "wD:t1", workspaceID: "wD", number: 1, label: "2",
                focused: false, paneCount: 1, agentStatusRaw: nil
            ),
        ]
        XCTAssertEqual(
            TabReorder.ordered(tabs, workspaces: workspaces).map(\.tabID),
            ["wD:t5", "wD:t1"]
        )
    }
}
