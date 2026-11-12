import AppKit
import GhosttyTerminal
import XCTest
@testable import herdrm

@MainActor
final class TerminalLinkTests: XCTestCase {
    private let oauthURL =
        "https://claude.com/cai/oauth/authorize?code=true&client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e"
        + "&response_type=code&scope=org%3Acreate_api_key+user%3Aprofile+user%3Ainference"
        + "&state=kFEEXox9ojVpHg4_Tsac7TrEySFD-rB8l9lGuuZDyMI"

    /// Lays `text` out the way herdr hands it over: hard rows of `columns`
    /// cells, the last one partial.
    private func rows(_ text: String, columns: Int) -> [String] {
        var rows: [String] = []
        var rest = Substring(text)
        while !rest.isEmpty {
            rows.append(String(rest.prefix(columns)))
            rest = rest.dropFirst(columns)
        }
        return rows
    }

    func testLinkSplitAcrossFullRowsIsJoinedWithoutBreaks() {
        let columns = 60
        let lines = ["Browser didn't open? Use the url below to sign in:"]
            + rows(oauthURL, columns: columns)
            + ["", "Paste code here if prompted >"]
        for row in 1...(lines.count - 3) {
            let link = LineBreakTerminalView.link(in: lines, row: row, column: 10, columns: columns)
            XCTAssertEqual(link?.text, oauthURL, "row \(row)")
        }
    }

    func testCopiedTextIsTheExactPrintedURL() {
        let columns = 40
        let lines = rows(oauthURL, columns: columns)
        let link = LineBreakTerminalView.link(in: lines, row: 0, column: 0, columns: columns)
        // Percent escapes and `+` stay as printed: the copy is what was shown.
        XCTAssertEqual(link?.text, oauthURL)
        XCTAssertFalse(link?.text.contains("\n") ?? true)
    }

    func testPointerOffTheLinkFindsNothing() {
        let lines = ["see https://example.com/a for details"]
        XCTAssertNil(LineBreakTerminalView.link(in: lines, row: 0, column: 0, columns: 80))
        XCTAssertNotNil(LineBreakTerminalView.link(in: lines, row: 0, column: 6, columns: 80))
    }

    func testShortRowEndsTheLink() {
        // A row that does not reach the right edge is a real line end.
        let lines = ["https://example.com/one", "two"]
        let link = LineBreakTerminalView.link(in: lines, row: 0, column: 3, columns: 80)
        XCTAssertEqual(link?.text, "https://example.com/one")
    }

    func testBareWordsAreNotLinks() {
        let lines = ["open README.md now"]
        XCTAssertNil(LineBreakTerminalView.link(in: lines, row: 0, column: 7, columns: 80))
    }

    func testURLWrapperStillReturnsTheOpenableURL() {
        let columns = 50
        let lines = rows(oauthURL, columns: columns)
        let url = LineBreakTerminalView.url(in: lines, row: 1, column: 5, columns: columns)
        XCTAssertNotNil(url)
        XCTAssertNotNil(URL(string: url ?? ""))
    }

    func testParenthesizedURLHardWrappedBeforeTheTerminalEdgeIsCompleteOnEveryRow() {
        // Codex wraps link text inside its content column, before the terminal
        // grid edge. Percent escapes may straddle those explicit row breaks.
        let fragments = [
            "https://example.com/files/%E6%9D%",
            "90%E6%96%99/%E7%AC%AC%E4%B8%80",
            "%E7%AB%A0.pdf?download=1",
        ]
        let expected = fragments.joined()
        for indent in ["", "  "] {
            let lines = ["Course material (" + fragments[0], indent + fragments[1], indent + fragments[2] + ")"]
            for row in lines.indices {
                let column = row == 0 ? "Course material (".count + 3 : indent.count + 3
                let link = LineBreakTerminalView.link(in: lines, row: row, column: column, columns: 100)
                XCTAssertEqual(link?.text, expected, "clicked row \(row)")
                XCTAssertEqual(link?.url, expected, "opened URL for row \(row)")
            }
        }
    }

    func testShortParenthesizedLinkDoesNotConsumeTheFollowingProse() {
        let lines = ["Course material (https://example.com/chapter.pdf)", "Next chapter follows."]
        let link = LineBreakTerminalView.link(in: lines, row: 0, column: 25, columns: 100)
        XCTAssertEqual(link?.text, "https://example.com/chapter.pdf")
        XCTAssertNil(LineBreakTerminalView.link(in: lines, row: 1, column: 3, columns: 100))
        let nested = "https://example.com/wiki/Function_(mathematics)"
        XCTAssertEqual(LineBreakTerminalView.link(in: ["Reference (\(nested))"], row: 0, column: 20,
                                                 columns: 100)?.text, nested)
    }

    func testAWordAfterTheLinkIsNotJoinedIntoIt() {
        let prose = ["See the guide (https://example.com/guide", "here)."]
        XCTAssertEqual(LineBreakTerminalView.link(in: prose, row: 0, column: 20, columns: 100)?.url,
                       "https://example.com/guide")
        let two = ["(https://a.com/x", "https://b.com/y)"]
        XCTAssertEqual(LineBreakTerminalView.link(in: two, row: 0, column: 5, columns: 100)?.url,
                       "https://a.com/x")
    }

    func testEveryParenthesizedLinkOnARowCanBeClicked() {
        let lines = ["A (https://a.com/x) B (https://b.com/long", "/tail)"]
        XCTAssertEqual(LineBreakTerminalView.link(in: lines, row: 0, column: 8, columns: 100)?.url,
                       "https://a.com/x")
        XCTAssertEqual(LineBreakTerminalView.link(in: lines, row: 0, column: 30, columns: 100)?.url,
                       "https://b.com/long/tail")
        XCTAssertEqual(LineBreakTerminalView.link(in: lines, row: 1, column: 1, columns: 100)?.url,
                       "https://b.com/long/tail")
    }

    func testOnlyGhosttysOwnRowMatchIsReplacedByThePrintedURL() {
        let printed = "https://example.com/files/report.pdf"
        let row = "Document (https://example.com/files/"
        XCTAssertTrue(LineBreakTerminalView.isRowMatch("https://example.com/files/", of: printed, clickedRow: row))
        XCTAssertTrue(LineBreakTerminalView.isRowMatch(printed, of: printed, clickedRow: nil))
        XCTAssertTrue(LineBreakTerminalView.isRowMatch("https://example.com/report", of: "https://example.com/report.pdf",
                                                       clickedRow: "(https://example.com/report."),
                      "Ghostty drops a trailing dot from its row match")
        XCTAssertFalse(LineBreakTerminalView.isRowMatch("https://example.com/", of: printed, clickedRow: row),
                       "a target that stops inside the printed URL is an OSC 8 target")
        XCTAssertFalse(LineBreakTerminalView.isRowMatch("https://example.org/download", of: printed, clickedRow: row))
    }

    func testCommandClickOpensTheWholeWrappedURLThroughBothTerminalCoordinators() throws {
        for shell in [false, true] {
            for reporting in [false, true] {
                try withTerminal(shell: shell, mouseReporting: reporting) { view, host, window in
                    let columns = Int(try XCTUnwrap(host.viewport).columns)
                    let expected = "https://example.com/files/"
                        + String(repeating: "%E6%96%87", count: columns * 2 / 9)
                        + "/report.pdf"
                    let lines = rows(expected, columns: columns)
                    XCTAssertEqual(lines.count, 3)
                    show(lines, in: host)
                    var opened: [String] = []
                    view.linkOpener = { url, _ in opened.append(url) }
                    for row in lines.indices {
                        opened.removeAll()
                        try commandClick(view, window: window, row: row, column: 5)
                        XCTAssertEqual(opened, [expected],
                                       "shell=\(shell), reporting=\(reporting), row=\(row)")
                    }
                    let fragments = ["https://example.com/%E6%9D%", "90%E6%96%99/%E7%AC%AC", "%E4%B8%80%E7%AB%A0.pdf"]
                    let hardRows = ["Document (" + fragments[0], "  " + fragments[1], "  " + fragments[2] + ")"]
                    show(hardRows, in: host)
                    for row in hardRows.indices {
                        opened.removeAll()
                        try commandClick(view, window: window, row: row, column: row == 0 ? 15 : 5)
                        XCTAssertEqual(opened, [fragments.joined()],
                                       "short rows: shell=\(shell), reporting=\(reporting), row=\(row)")
                    }
                }
            }
        }
    }

    func testCommandClickPreservesAnOSC8TargetDifferentFromThePrintedURL() throws {
        for reporting in [false, true] {
            try withTerminal(shell: false, mouseReporting: reporting) { view, host, window in
                let columns = Int(try XCTUnwrap(host.viewport).columns)
                let printed = "https://example.com/display-name.pdf"
                let wrapped = "https://example.com/" + String(repeating: "segment/", count: columns / 4)
                // A target exactly equal to one printed row can't be told from
                // Ghostty's own row match without an OSC 8 kind, so it isn't a case.
                let cases = [
                    (printed, "https://example.org/actual-download"),
                    (printed, "https://example.com/"),
                    (wrapped, "https://example.com/segment/"),
                ]
                for (display, target) in cases {
                    show(rows(display, columns: columns).map {
                        "\u{1b}]8;;\(target)\u{7}\($0)\u{1b}]8;;\u{7}"
                    }, in: host)
                    var opened: [String] = []
                    view.linkOpener = { url, _ in opened.append(url) }
                    try commandClick(view, window: window, row: 0, column: 5)
                    XCTAssertEqual(opened, [target], "reporting=\(reporting), target=\(target)")
                }
                var opened: [String] = []
                view.linkOpener = { url, _ in opened.append(url) }
                let requested = "https://example.net/programmatic"
                for kind in [TerminalOpenURLKind.unknown, .text, .html] {
                    view.openLink(requested, kind: kind)
                }
                XCTAssertEqual(opened, [requested, requested, requested],
                               "Without a pending click, programmatic URLs stay unchanged")
            }
        }
    }

    // These fixtures have no PTY process or server. They exercise the real
    // Ghostty mouse/delegate paths with only synthetic terminal output.
    private func withTerminal(
        shell: Bool,
        mouseReporting: Bool,
        _ body: (LineBreakTerminalView, TerminalProcessHost, NSWindow) throws -> Void
    ) throws {
        _ = NSApplication.shared
        let previousConfiguration = GhosttyRuntime.controller.terminalConfiguration
        let host = TerminalProcessHost()
        let view = LineBreakTerminalView(frame: NSRect(x: 0, y: 0, width: 500, height: 180))
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let coordinator: any TerminalSurfaceViewDelegate
        if shell {
            let delegate = ShellTerminalView.Coordinator()
            delegate.view = view
            coordinator = delegate
        } else {
            let delegate = AttachTerminalView.Coordinator()
            delegate.view = view
            coordinator = delegate
        }
        defer {
            view.setSurfaceVisible(false)
            window.contentView = nil
            window.close()
            host.terminate()
            GhosttyRuntime.controller.setTerminalConfiguration(previousConfiguration)
            withExtendedLifetime(coordinator) {}
        }
        view.linkOpener = { _, _ in XCTFail("Set a collecting opener before clicking") }
        view.processHost = host
        view.delegate = coordinator
        applyTerminalAppearance(view, fontName: "", fontSize: 14, thinStrokes: false,
                                fontWeight: 0, lineSpacing: 1, dark: true,
                                mouseReporting: mouseReporting, copyOnSelect: false)
        view.controller = GhosttyRuntime.controller
        view.configuration = TerminalSurfaceOptions(backend: .inMemory(host.session))
        window.contentView = view
        view.setSurfaceVisible(true)
        view.layoutSubtreeIfNeeded()
        settle(until: {
            guard view.attachedSurface != nil, let grid = view.gridMetrics, let viewport = host.viewport
            else { return false }
            return grid.columns == viewport.columns && grid.rows == viewport.rows
                && grid.widthPixels == UInt32(view.bounds.width * window.backingScaleFactor)
                && grid.heightPixels == UInt32(view.bounds.height * window.backingScaleFactor)
        })
        XCTAssertNotNil(view.attachedSurface)
        _ = try XCTUnwrap(view.gridMetrics)
        // The application requests capture even when the user's reporting
        // preference is off, so both the local and captured routes are tested.
        host.session.receive("\u{1b}[?1000h\u{1b}[?1006h")
        settle(until: { view.isMouseCaptured })
        XCTAssertTrue(view.isMouseCaptured)
        try body(view, host, window)
    }

    private func show(_ lines: [String], in host: TerminalProcessHost) {
        host.session.receive("\u{1b}[2J\u{1b}[H")
        host.session.waitForPendingOutput()
        var text = ""
        for (row, line) in lines.enumerated() {
            // Herdr repaints rows at explicit cursor positions; this is not a
            // native terminal soft wrap that Ghostty can already reconstruct.
            text += "\u{1b}[\(row + 1);1H" + line
        }
        host.session.receive(text)
        host.session.waitForPendingOutput()
    }

    private func commandClick(
        _ view: LineBreakTerminalView, window: NSWindow,
        row: Int, column: Int
    ) throws {
        let metrics = try XCTUnwrap(view.gridMetrics)
        let scale = window.backingScaleFactor
        let x = 2 + (CGFloat(column) + 0.5) * CGFloat(metrics.cellWidthPixels) / scale
        let fromTop = 2 + (CGFloat(row) + 0.5) * CGFloat(metrics.cellHeightPixels) / scale
        let point = view.convert(NSPoint(x: x, y: view.isFlipped ? fromTop : view.bounds.height - fromTop),
                                 to: nil)
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: .command,
                                            timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil,
                                            eventNumber: 0, clickCount: 1, pressure: 1))
        }
        view.mouseMoved(with: try event(.mouseMoved))
        view.mouseDown(with: try event(.leftMouseDown))
        view.mouseUp(with: try event(.leftMouseUp))
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
    }

    private func settle(until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition(), "The in-memory terminal fixture must be ready")
    }
}
