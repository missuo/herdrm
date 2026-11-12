import AppKit
import ImageIO

/// Decodes images into small, bounded thumbnails for the image boxes drawn over the terminal.
///
/// Every path goes through one ImageIO call, so the size rules live in one place: the longest side
/// is at most `maxPixelSize` pixels, smaller images are never upscaled, and EXIF orientation is applied.
enum ImageThumbnailer {
    /// Longest-side budget, in pixels, for a decoded thumbnail.
    static let maxPixelSize = 512

    /// Decodes the image file at `url`; nil when the file is not a decodable image.
    static func thumbnail(contentsOf url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return thumbnail(from: source)
    }

    /// The raw image bytes a clipboard image carries, PNG first, else TIFF; nil
    /// when it holds neither. Read on the main thread; decode the bytes with
    /// `thumbnail(fromImageData:)` off it. Never the pasteboard's `NSImage`: for
    /// a copied file that is the file's document icon, not its picture.
    static func imageData(from pasteboard: NSPasteboard) -> Data? {
        pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff)
    }

    /// Decodes encoded image bytes (PNG, TIFF, JPEG, …); nil when they are not a decodable image.
    static func thumbnail(fromImageData data: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return thumbnail(from: source)
    }

    private static func thumbnail(from source: CGImageSource) -> NSImage? {
        guard CGImageSourceGetCount(source) > 0 else { return nil }
        // ThumbnailMaxPixelSize alone can upscale small images, so cap it at the source's own size.
        var longestSide = maxPixelSize
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? Int,
           let height = properties[kCGImagePropertyPixelHeight] as? Int {
            longestSide = min(maxPixelSize, max(width, height))
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: longestSide,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        // A bitmap rep (1 pixel per point) rather than `NSImage(cgImage:)`, whose snapshot rep reports
        // pixel counts scaled by the screen's backing factor.
        let size = NSSize(width: cgImage.width, height: cgImage.height)
        let rep = NSBitmapImageRep(cgImage: cgImage)
        rep.size = size
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }
}
