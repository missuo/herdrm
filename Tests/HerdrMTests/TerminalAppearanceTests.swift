import AppKit
import Darwin
import GhosttyTerminal
import XCTest
@testable import herdrm

@MainActor
final class TerminalAppearanceTests: XCTestCase {
    /// The backend keeps its dark ANSI colors even when HerdrM displays a light
    /// theme. A theme change must repaint existing cells, not merely transform
    /// the next bytes: an idle input box otherwise keeps its old light fill.
    func testSwitchingAppearanceRepaintsExistingANSIBoxesWithoutReplacingTheSession() async throws {
        _ = NSApplication.shared
        let host = TerminalProcessHost(isHerdrAttach: true)
        let session = host.session
        let view = LineBreakTerminalView(frame: NSRect(x: 0, y: 0, width: 480, height: 180))
        let delegate = AppearanceDelegate(view: view)
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let previousConfiguration = GhosttyRuntime.controller.terminalConfiguration
        defer {
            host.terminate() // This test's fixture only; no herdr or SSH process exists.
            window.contentView = nil
            window.close()
            GhosttyRuntime.controller.setTerminalConfiguration(previousConfiguration)
            GhosttyRuntime.controller.setColorScheme(
                NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
            )
        }

        view.processHost = host
        view.delegate = delegate
        view.controller = GhosttyRuntime.controller
        view.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        setAppearance(dark: false, view: view, window: window)
        window.contentView = view
        view.setSurfaceVisible(true)
        view.layoutSubtreeIfNeeded()
        try await waitUntil {
            guard view.attachedSurface != nil, let grid = view.gridMetrics, let viewport = host.viewport
            else { return false }
            return grid.columns == viewport.columns && grid.rows == viewport.rows
                && grid.widthPixels == UInt32(view.bounds.width * window.backingScaleFactor)
                && grid.heightPixels == UInt32(view.bounds.height * window.backingScaleFactor)
        }
        XCTAssertNotNil(view.attachedSurface)

        // A small, test-owned PTY models herdr attach's full repaint on WINCH.
        // It has no timer or additional output that could accidentally repaint
        // the stale cells and conceal a missing appearance-change notification.
        let fixture = #"""
        import signal
        import sys

        redraw_count = 0
        def redraw(*_):
            global redraw_count
            redraw_count += 1
            frame = "\x1b]2;appearance-fixture-%d\x07" % redraw_count
            frame += "\x1b[?25l\x1b[2J\x1b[H"
            frame += "\x1b[38;2;220;220;220m\x1b[48;2;65;69;76m"
            frame += " INPUT test1 ".ljust(36)
            frame += "\x1b[0m\r\n"
            frame += "\x1b[38;2;220;220;220m\x1b[48;2;74;77;84m"
            frame += " MESSAGE test2 ".ljust(36)
            frame += "\x1b[0m"
            sys.stdout.buffer.write(frame.encode())
            sys.stdout.buffer.flush()

        signal.signal(signal.SIGWINCH, redraw)
        redraw()
        while True:
            signal.pause()
        """#
        let viewport = try XCTUnwrap(host.viewport)
        XCTAssertGreaterThanOrEqual(viewport.columns, 36)
        XCTAssertTrue(host.process.start(executable: "/usr/bin/python3", args: ["-u", "-c", fixture],
                                         environment: ["TERM=xterm-256color", "LANG=en_US.UTF-8"],
                                         columns: viewport.columns, rows: viewport.rows))
        let pid = host.process.shellPid
        XCTAssertGreaterThan(pid, 0)
        try await waitUntil {
            delegate.redrawCount > 0
                && session.readViewportText()?.contains("INPUT test1") == true
                && session.readViewportText()?.contains("MESSAGE test2") == true
        }
        let originalText = try XCTUnwrap(session.readViewportText())
        XCTAssertTrue(originalText.contains("INPUT test1"))
        XCTAssertTrue(originalText.contains("MESSAGE test2"))
        // Verify the repaint protocol here. Metal-backed view snapshots can
        // omit the presented frame, so actual colors are checked in the app.

        let initialRedrawCount = delegate.redrawCount
        setAppearance(dark: true, view: view, window: window)
        try await waitUntil { delegate.redrawCount > initialRedrawCount }
        XCTAssertGreaterThan(delegate.redrawCount, initialRedrawCount,
                             "Changing appearance must request a full repaint from the same PTY")
        XCTAssertEqual(session.readViewportText(), originalText)
        XCTAssertTrue(view.processHost === host)
        XCTAssertTrue(host.session === session)
        XCTAssertEqual(host.process.shellPid, pid, "A theme change must not restart the attached process")

        let darkRedrawCount = delegate.redrawCount
        setAppearance(dark: false, view: view, window: window)
        try await waitUntil { delegate.redrawCount > darkRedrawCount }
        XCTAssertGreaterThan(delegate.redrawCount, darkRedrawCount,
                             "Switching back to light must request another repaint from the same PTY")
        XCTAssertEqual(session.readViewportText(), originalText)
        XCTAssertTrue(view.processHost === host)
        XCTAssertTrue(host.session === session)
        XCTAssertEqual(host.process.shellPid, pid, "Switching back must keep the original attached process")
    }

    func testRedrawSizeChangesPixelsWithoutChangingTheGridOrCellSize() throws {
        let cases: [(String, winsize)] = [
            ("exact cell width", winsize(ws_row: 24, ws_col: 115, ws_xpixel: 1035, ws_ypixel: 480)),
            ("maximum pixel width", winsize(ws_row: 24, ws_col: 115, ws_xpixel: 65535, ws_ypixel: 480)),
            ("unknown pixel size", winsize(ws_row: 24, ws_col: 115, ws_xpixel: 0, ws_ypixel: 0)),
            ("single column", winsize(ws_row: 24, ws_col: 1, ws_xpixel: 9, ws_ypixel: 480)),
        ]
        for (name, current) in cases {
            let redraw = try XCTUnwrap(TerminalProcess.redrawSize(current), name)
            XCTAssertEqual(redraw.ws_row, current.ws_row, name)
            XCTAssertEqual(redraw.ws_col, current.ws_col, name)
            XCTAssertTrue(redraw.ws_xpixel != current.ws_xpixel || redraw.ws_ypixel != current.ws_ypixel,
                          "\(name): a changed winsize must travel through SSH")
            XCTAssertEqual(redraw.ws_xpixel / redraw.ws_col, current.ws_xpixel / current.ws_col,
                           "\(name): width must retain the backend's integer cell width")
            XCTAssertEqual(redraw.ws_ypixel / redraw.ws_row, current.ws_ypixel / current.ws_row,
                           "\(name): height must retain the backend's integer cell height")
            if current.ws_col == 1 {
                XCTAssertEqual(redraw.ws_xpixel, current.ws_xpixel, "A single column cannot absorb a width change")
                XCTAssertNotEqual(redraw.ws_ypixel, current.ws_ypixel, "Use height when width cannot preserve its quotient")
            }
        }
    }

    private func setAppearance(dark: Bool, view: LineBreakTerminalView, window: NSWindow) {
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        applyTerminalAppearance(view, fontName: "", fontSize: 14, thinStrokes: false,
                                fontWeight: 0, lineSpacing: 1, dark: dark,
                                mouseReporting: true, copyOnSelect: false)
        GhosttyRuntime.controller.setColorScheme(dark ? .dark : .light)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        // A fresh CI host may need longer to start Python and the first surface.
        // Never compare later repaint frames against an unready blank baseline.
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw NSError(domain: "TerminalAppearanceTests", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Timed out waiting for the terminal fixture to become ready",
        ])
    }


}

@MainActor
private final class AppearanceDelegate: TerminalSurfaceLifecycleDelegate, TerminalSurfaceTitleDelegate,
    TerminalSurfaceGridResizeDelegate {
    private weak var view: LineBreakTerminalView?
    private(set) var redrawCount = 0

    init(view: LineBreakTerminalView) { self.view = view }

    func terminalDidAttachSurface(_ surface: TerminalSurface) { view?.attachedSurface = surface }
    func terminalDidDetachSurface() { view?.attachedSurface = nil }
    func terminalDidResize(_ size: TerminalGridMetrics) { view?.gridMetrics = size }
    func terminalDidChangeTitle(_ title: String) {
        redrawCount = Int(title.split(separator: "-").last ?? "") ?? 0
    }
}
