import AppKit

/// Pure geometry for placing a thumbnail over the terminal grid.
enum ThumbnailOverlayGeometry {
    /// The view-space rect (points) of `cells`, in a flipped view, given the cell size in points and the grid padding.
    static func rect(for cells: CellRect, cellSize: CGSize, padding: CGFloat) -> NSRect {
        NSRect(x: padding + CGFloat(cells.column) * cellSize.width,
               y: padding + CGFloat(cells.row) * cellSize.height,
               width: CGFloat(cells.columns) * cellSize.width,
               height: CGFloat(cells.rows) * cellSize.height)
    }

    /// Where an image of `imageSize` lands inside `bounds`: scaled to fit, aspect preserved, centred.
    static func fittedRect(imageSize: CGSize, in bounds: NSRect) -> NSRect {
        guard imageSize.width > 0, imageSize.height > 0, bounds.width > 0, bounds.height > 0 else {
            return .zero
        }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return NSRect(x: bounds.minX + (bounds.width - size.width) / 2,
                      y: bounds.minY + (bounds.height - size.height) / 2,
                      width: size.width, height: size.height)
    }
}

/// Paints one thumbnail over a Claude Code image box. Purely decorative: it never takes mouse input,
/// so clicks and selection fall through to the terminal beneath.
final class ThumbnailOverlayView: NSView {
    var image: NSImage { didSet { needsDisplay = true } }
    var background: NSColor { didSet { needsDisplay = true } }

    init(image: NSImage, background: NSColor) {
        self.image = image
        self.background = background
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    /// The fill is forced opaque in `draw`, so the layer can skip blending with the terminal beneath.
    override var isOpaque: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        background.withAlphaComponent(1).setFill()
        bounds.fill()
        image.draw(in: ThumbnailOverlayGeometry.fittedRect(imageSize: image.size, in: bounds),
                   from: .zero, operation: .sourceOver, fraction: 1,
                   respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
    }
}
