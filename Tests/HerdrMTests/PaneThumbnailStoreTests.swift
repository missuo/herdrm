import XCTest
@testable import herdrm

final class PaneThumbnailStoreTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000)
    /// One instance per tag, so NSImage's identity-based equality compares what the store was given.
    private var images: [Int: NSImage] = [:]
    private func image(_ tag: Int) -> NSImage {
        if let existing = images[tag] { return existing }
        let made = NSImage(size: NSSize(width: tag, height: 1))
        images[tag] = made
        return made
    }
    private func pending(_ tag: Int, at: Date, expiry: TimeInterval = 60) -> PendingThumbnail {
        PendingThumbnail(image: image(tag), name: "img\(tag).png", recordedAt: at, expiry: expiry)
    }
    private func box(_ n: Int, column: Int = 0) -> ClaudeImageBox {
        ClaudeImageBox(number: n, interior: CellRect(row: 2, column: column + 1, rows: 6, columns: 20))
    }

    func testOnePendingBindsToOneNewBox() {
        var store = PaneThumbnailStore()
        store.record(pending(1, at: t0))
        let placed = store.scan([box(1)], now: t0 + 1)
        XCTAssertEqual(placed, [PlacedThumbnail(box: box(1), image: image(1))])
    }

    func testTwoPendingBindInDeliveryOrderToAscendingNumbers() {
        var store = PaneThumbnailStore()
        store.record(pending(1, at: t0)); store.record(pending(2, at: t0 + 1))
        let placed = store.scan([box(2, column: 23), box(1)], now: t0 + 2)
        XCTAssertEqual(placed.map(\.box.number), [1, 2])
        XCTAssertEqual(placed.map(\.image.size.width), [1, 2])
    }

    func testMoreNewBoxesThanPendingBindsNothingAndClearsPending() {
        var store = PaneThumbnailStore()
        store.record(pending(1, at: t0))
        XCTAssertEqual(store.scan([box(1), box(2, column: 23)], now: t0 + 1), [])
        XCTAssertEqual(store.scan([box(3)], now: t0 + 4), [])                        // pending was cleared
        store.record(pending(2, at: t0 + 5))
        XCTAssertEqual(store.scan([box(4), box(5, column: 23)], now: t0 + 6), [])   // 2 new vs 1 pending
    }

    func testFewerNewBoxesThanPendingBindsNothing() {
        // A paste Claude silently dropped must not shift later images.
        var store = PaneThumbnailStore()
        store.record(pending(1, at: t0)); store.record(pending(2, at: t0 + 1))
        XCTAssertEqual(store.scan([box(1)], now: t0 + 2), [])
        XCTAssertFalse(store.needsScanning(now: t0 + 3))
    }

    func testNewNumberWithNoPendingDrawsNothing() {
        var store = PaneThumbnailStore()
        XCTAssertEqual(store.scan([box(7)], now: t0), [])
    }

    func testExpiredPendingNeverBinds() {
        var store = PaneThumbnailStore()
        store.record(pending(1, at: t0, expiry: 10))
        XCTAssertEqual(store.scan([box(1)], now: t0 + 11), [])
        XCTAssertFalse(store.needsScanning(now: t0 + 11))
    }

    func testBoundBoxKeepsItsImageAcrossScansAndAShortAbsence() {
        var store = PaneThumbnailStore()
        store.record(pending(1, at: t0))
        _ = store.scan([box(1)], now: t0 + 1)
        XCTAssertEqual(store.scan([], now: t0 + 2), [])                 // scrolled away
        XCTAssertEqual(store.scan([box(1)], now: t0 + 20).map(\.image.size.width), [1])  // back within grace
    }

    func testBindingDropsAfterGraceAndTheNumberIsNewAgain() {
        var store = PaneThumbnailStore()
        store.record(pending(1, at: t0))
        _ = store.scan([box(1)], now: t0 + 1)
        _ = store.scan([], now: t0 + 2)
        XCTAssertEqual(store.scan([], now: t0 + 2 + 31), [])            // old #1 binding gone
        store.record(pending(5, at: t0 + 40))
        XCTAssertEqual(store.scan([box(1)], now: t0 + 41).map(\.image.size.width), [5])  // counter reset: fresh bind
        XCTAssertFalse(store.needsScanning(now: t0 + 41 + 31 + 1))
    }

    func testCounterContinuesAcrossPrompts() {
        var store = PaneThumbnailStore()
        store.record(pending(1, at: t0))
        _ = store.scan([box(1)], now: t0 + 1)
        _ = store.scan([], now: t0 + 2)                                  // prompt sent
        store.record(pending(3, at: t0 + 3))
        XCTAssertEqual(store.scan([box(3)], now: t0 + 4).map(\.image.size.width), [3])
    }

    func testRemoveAllForgetsEverything() {
        var store = PaneThumbnailStore()
        store.record(pending(1, at: t0))
        _ = store.scan([box(1)], now: t0 + 1)
        store.removeAll()
        XCTAssertEqual(store.scan([box(1)], now: t0 + 2), [])
        XCTAssertFalse(store.needsScanning(now: t0 + 2))
    }

    func testVisibleUnboundNumberIsNotNewOnLaterScans() {
        var store = PaneThumbnailStore()
        XCTAssertEqual(store.scan([box(1)], now: t0), [])              // #1 seen, unbound, nothing pending
        store.record(pending(2, at: t0 + 1))
        XCTAssertEqual(store.scan([box(1)], now: t0 + 2), [])          // #1 is not new; pending stays
        XCTAssertTrue(store.needsScanning(now: t0 + 2))
        XCTAssertEqual(store.scan([box(1), box(2, column: 23)], now: t0 + 3).map(\.image.size.width), [2])
    }

    func testSeenUnboundNumberIsForgottenAfterGrace() {
        var store = PaneThumbnailStore()
        _ = store.scan([box(1)], now: t0)
        store.record(pending(9, at: t0 + 40))
        XCTAssertEqual(store.scan([box(1)], now: t0 + 41).map(\.image.size.width), [9])
    }

    func testCounterResetInsideGraceBindsTheNewPasteNotTheOldImage() {
        // A binds to #1, the prompt is sent, `/clear` resets Claude's counter, and B is pasted
        // within the grace: Claude's new #1 is B's box and must never show A.
        var store = PaneThumbnailStore()
        store.record(pending(1, at: t0))
        XCTAssertEqual(store.scan([box(1)], now: t0 + 1).map(\.image.size.width), [1])
        XCTAssertEqual(store.scan([], now: t0 + 2), [])                       // prompt sent, box gone
        store.forgetAbsentBindings(present: [])                               // baseline before B's delivery
        store.record(pending(2, at: t0 + 5))
        XCTAssertEqual(store.scan([box(1)], now: t0 + 6).map(\.image.size.width), [2])
    }

    func testBaselineKeepsTheBindingOfABoxStillOnScreen() {
        var store = PaneThumbnailStore()
        store.record(pending(1, at: t0))
        _ = store.scan([box(1)], now: t0 + 1)
        store.forgetAbsentBindings(present: [box(1)])                         // second paste, #1 still there
        store.record(pending(2, at: t0 + 2))
        let placed = store.scan([box(1), box(2, column: 23)], now: t0 + 3)
        XCTAssertEqual(placed.map(\.box.number), [1, 2])
        XCTAssertEqual(placed.map(\.image.size.width), [1, 2])
    }

    func testBaselineForgetsASeenUnboundNumberThatIsGone() {
        var store = PaneThumbnailStore()
        _ = store.scan([box(1)], now: t0)                                     // #1 seen, unbound
        _ = store.scan([], now: t0 + 1)
        store.forgetAbsentBindings(present: [])
        store.record(pending(4, at: t0 + 2))
        XCTAssertEqual(store.scan([box(1)], now: t0 + 3).map(\.image.size.width), [4])
    }

    func testPlacementsAreReadOnly() {
        var store = PaneThumbnailStore()
        store.record(pending(1, at: t0))
        _ = store.scan([box(1)], now: t0 + 1)
        store.record(pending(2, at: t0 + 2))
        // Moved #1 is re-placed; the unbound #2 neither binds nor is marked seen.
        let moved = ClaudeImageBox(number: 1, interior: CellRect(row: 5, column: 1, rows: 6, columns: 20))
        XCTAssertEqual(store.placements(for: [moved, box(2, column: 23)], now: t0 + 3),
                       [PlacedThumbnail(box: moved, image: image(1))])
        XCTAssertEqual(store.placements(for: [], now: t0 + 3), [])
        // The later full scan still binds #2 to the pending image.
        XCTAssertEqual(store.scan([box(1), box(2, column: 23)], now: t0 + 4).map(\.image.size.width), [1, 2])
    }

    func testPlacementsSkipABindingPastItsGrace() {
        var store = PaneThumbnailStore()
        store.record(pending(1, at: t0))
        _ = store.scan([box(1)], now: t0 + 1)
        XCTAssertEqual(store.placements(for: [box(1)], now: t0 + 1 + 31), [])
    }
}
