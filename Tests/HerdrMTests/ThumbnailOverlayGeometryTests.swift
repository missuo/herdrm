import XCTest
@testable import herdrm

final class ThumbnailOverlayGeometryTests: XCTestCase {
    func testCellRectMapsThroughPaddingAndCellSize() {
        let rect = ThumbnailOverlayGeometry.rect(
            for: CellRect(row: 2, column: 1, rows: 6, columns: 20),
            cellSize: CGSize(width: 7, height: 15), padding: 2)
        XCTAssertEqual(rect, NSRect(x: 9, y: 32, width: 140, height: 90))
    }

    func testLandscapeImageFitsWidthAndCentresVertically() {
        let fitted = ThumbnailOverlayGeometry.fittedRect(imageSize: CGSize(width: 200, height: 100),
                                                         in: NSRect(x: 10, y: 10, width: 140, height: 90))
        XCTAssertEqual(fitted, NSRect(x: 10, y: 20, width: 140, height: 70))
    }

    func testPortraitImageFitsHeightAndCentresHorizontally() {
        let fitted = ThumbnailOverlayGeometry.fittedRect(imageSize: CGSize(width: 100, height: 200),
                                                         in: NSRect(x: 10, y: 10, width: 140, height: 90))
        XCTAssertEqual(fitted, NSRect(x: 57.5, y: 10, width: 45, height: 90))
    }

    func testOverlayIsNeverHitTestable() {
        let view = ThumbnailOverlayView(image: NSImage(size: NSSize(width: 4, height: 4)), background: .black)
        view.frame = NSRect(x: 0, y: 0, width: 50, height: 50)
        XCTAssertNil(view.hitTest(NSPoint(x: 10, y: 10)))
    }

    func testOverlayIsOpaqueEvenWithATranslucentBackground() {
        let view = ThumbnailOverlayView(image: NSImage(size: NSSize(width: 4, height: 4)),
                                        background: NSColor.black.withAlphaComponent(0.5))
        XCTAssertTrue(view.isOpaque)
    }
}
