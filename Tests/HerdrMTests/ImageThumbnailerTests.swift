import XCTest
@testable import herdrm

final class ImageThumbnailerTests: XCTestCase {
    private func writePNG(width: Int, height: Int) throws -> URL {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("thumb-\(UUID().uuidString).png")
        try rep.representation(using: .png, properties: [:])!.write(to: url)
        return url
    }

    func testLargeImageIsDownscaledToTheBudget() throws {
        let url = try writePNG(width: 2000, height: 1000)
        defer { try? FileManager.default.removeItem(at: url) }
        let image = try XCTUnwrap(ImageThumbnailer.thumbnail(contentsOf: url))
        let rep = try XCTUnwrap(image.representations.first)
        XCTAssertEqual(max(rep.pixelsWide, rep.pixelsHigh), 512)
        XCTAssertEqual(min(rep.pixelsWide, rep.pixelsHigh), 256)
    }

    func testSmallImageIsNotUpscaled() throws {
        let url = try writePNG(width: 40, height: 30)
        defer { try? FileManager.default.removeItem(at: url) }
        let rep = try XCTUnwrap(ImageThumbnailer.thumbnail(contentsOf: url)?.representations.first)
        XCTAssertEqual(rep.pixelsWide, 40); XCTAssertEqual(rep.pixelsHigh, 30)
    }

    func testNonImageFileYieldsNil() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("thumb-\(UUID().uuidString).txt")
        try "not an image".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNil(ImageThumbnailer.thumbnail(contentsOf: url))
    }

    private func bitmap(width: Int, height: Int) -> NSBitmapImageRep {
        NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                         bytesPerRow: 0, bitsPerPixel: 0)!
    }

    func testImageDataIsDownscaledToTheBudget() throws {
        let png = try XCTUnwrap(bitmap(width: 1000, height: 2000).representation(using: .png, properties: [:]))
        let rep = try XCTUnwrap(ImageThumbnailer.thumbnail(fromImageData: png)?.representations.first)
        XCTAssertEqual(rep.pixelsHigh, 512); XCTAssertEqual(rep.pixelsWide, 256)
    }

    func testSmallImageDataIsNotUpscaled() throws {
        let tiff = try XCTUnwrap(bitmap(width: 24, height: 12).tiffRepresentation)
        let rep = try XCTUnwrap(ImageThumbnailer.thumbnail(fromImageData: tiff)?.representations.first)
        XCTAssertEqual(rep.pixelsWide, 24); XCTAssertEqual(rep.pixelsHigh, 12)
    }

    func testNonImageDataYieldsNil() {
        XCTAssertNil(ImageThumbnailer.thumbnail(fromImageData: Data("not an image".utf8)))
        XCTAssertNil(ImageThumbnailer.thumbnail(fromImageData: Data()))
    }

    func testPasteboardImageDataIsReadAndDecodes() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        // A bitmap-backed image: a rep-less NSImage declares TIFF on the pasteboard but encodes no data.
        let source = NSImage(size: NSSize(width: 8, height: 8))
        source.addRepresentation(bitmap(width: 8, height: 8))
        pasteboard.writeObjects([source])
        let data = try XCTUnwrap(ImageThumbnailer.imageData(from: pasteboard))
        let rep = try XCTUnwrap(ImageThumbnailer.thumbnail(fromImageData: data)?.representations.first)
        XCTAssertEqual(rep.pixelsWide, 8); XCTAssertEqual(rep.pixelsHigh, 8)

        let text = NSPasteboard.withUniqueName()
        text.clearContents()
        text.setString("x", forType: .string)
        XCTAssertNil(ImageThumbnailer.imageData(from: text))
    }

    func testPasteboardPNGIsPreferredOverTIFF() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        let png = try XCTUnwrap(bitmap(width: 3, height: 3).representation(using: .png, properties: [:]))
        let tiff = try XCTUnwrap(bitmap(width: 5, height: 5).tiffRepresentation)
        pasteboard.declareTypes([.tiff, .png], owner: nil)
        pasteboard.setData(tiff, forType: .tiff)
        pasteboard.setData(png, forType: .png)
        XCTAssertEqual(ImageThumbnailer.imageData(from: pasteboard), png)
    }
}
