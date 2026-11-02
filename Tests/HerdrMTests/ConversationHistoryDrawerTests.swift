import AppKit
import ApplicationServices
import HerdrKit
import SwiftUI
import XCTest
@testable import herdrm

@MainActor
final class ConversationHistoryDrawerTests: XCTestCase {
    private var window: NSWindow?
    override func tearDown() async throws { window?.close(); window = nil }

    func testFencedCodeAndUnicodeArePreservedAsInertText() {
        XCTAssertEqual(ConversationMarkdown.segments("Hello **世界**\n\n```swift\nlet x = \"<script>\"\n```\nDone"), [
            .text("Hello **世界**\n"), .code("let x = \"<script>\""), .text("Done")
        ])
        XCTAssertEqual(ConversationMarkdown.segments("~~~\na\nβ\n~~~"), [.code("a\nβ")])
        XCTAssertEqual(ConversationMessageView.speaker(for: "unknown"), String(localized: "Other message"))
        XCTAssertNotEqual(ConversationHistoryNotice.text(for: "unsupported_server"), "unsupported_server")
        XCTAssertNotEqual(ConversationHistoryNotice.text(for: "permission_denied"), ConversationHistoryNotice.text(for: "retention_expired"))
        XCTAssertEqual(ConversationHistoryNotice.text(for: "access_denied"), String(localized: "Herdrm does not have permission to read this saved conversation."))
        XCTAssertEqual(ConversationHistoryNotice.text(for: "not_recorded"), String(localized: "No saved transcript was recorded for this Claude session."))
        XCTAssertNil(ConversationHistoryNotice.quality(for: "source_available"))
        XCTAssertEqual(ConversationHistoryNotice.quality(for: "partial_unsupported_records"), String(localized: "Some saved records could not be displayed."))
        XCTAssertEqual(ConversationHistoryNotice.quality(for: "partial_trailing_record"), String(localized: "The latest message is still being saved."))
    }

    func testHostedMessageCopyIsExplicitAndToolContentsStartCollapsed() throws {
        var copies = 0
        let message = ConversationMessage(id: "message", role: "assistant", blocks: [
            .init(id: "text", kind: "text", text: "**Visible reply** 世界"),
            .init(id: "code", kind: "code", text: "print(\"hello\")"),
            .init(id: "file", kind: "attachment", label: "fixture.txt"),
            .init(id: "unknown", kind: "future_block", text: "<script>inert</script>"),
            .init(id: "tool", kind: "tool_result", text: "hidden tool details", name: "Fixture tool")
        ])
        let hosted = show(ConversationMessageView(message: message) { copies += 1 }, width: 420, height: 420)
        XCTAssertEqual(copies, 0)
        let elements = AccessibilityProbe.elements(in: hosted)
        let copy = try XCTUnwrap(elements.first { $0.identifier == "history.copy.message" })
        XCTAssertFalse(elements.contains { $0.name?.contains("hidden tool details") == true })
        AccessibilityProbe.press(copy)
        settle()
        XCTAssertEqual(copies, 1)
        let attachment = try XCTUnwrap(elements.first { $0.identifier == "history.attachment.file" })
        XCTAssertEqual(attachment.name, String(localized: "Attachment: \("fixture.txt")"))
    }

    func testHostedDrawerHasExactTurnNavigationSearchPagingAndClose() async throws {
        let provider = HistoryViewFixtureProvider()
        let controller = ConversationHistoryController()
        controller.select(deviceID: UUID(), paneID: "fixture-pane", session: .init(source: "herdr:claude", agent: "claude", kind: "id", value: "fixture-session"), provider: provider)
        controller.setVisible(true)
        await waitReady(controller)
        controller.open(turnID: "turn-1")
        let hosted = show(ConversationHistoryDrawer(controller: controller), width: 420, height: 700)
        let elements = AccessibilityProbe.elements(in: hosted)
        for id in ["history.search", "history.previousTurn", "history.nextTurn", "history.older", "history.newer", "history.close", "history.allTurns"] {
            XCTAssertTrue(elements.contains { $0.identifier == id }, "Missing \(id)")
        }
        XCTAssertEqual(controller.selectedMessageID, "user-1")
        AccessibilityProbe.press(try XCTUnwrap(elements.first { $0.identifier == "history.nextTurn" }))
        settle()
        XCTAssertEqual(controller.selectedMessageID, "user-2")
        AccessibilityProbe.press(try XCTUnwrap(elements.first { $0.identifier == "history.older" }))
        for _ in 0..<20 { await Task.yield() }
        let reads = await provider.readWindows()
        XCTAssertTrue(reads.contains(.before(cursor: "older")))
        AccessibilityProbe.press(try XCTUnwrap(AccessibilityProbe.elements(in: hosted).first { $0.identifier == "history.newer" }))
        for _ in 0..<100 where controller.isLoadingNewer { await Task.yield() }
        let forwardReads = await provider.readWindows()
        XCTAssertTrue(forwardReads.contains(.after(cursor: "newer")))
        XCTAssertTrue(controller.messages.contains { $0.id == "reply-next-page" && $0.turnID == "turn-2" })
        XCTAssertEqual(controller.selectedMessageID, "user-2", "Forward paging preserves the reader's selected turn")
        AccessibilityProbe.press(try XCTUnwrap(AccessibilityProbe.elements(in: hosted).first { $0.identifier == "history.close" }))
        settle()
        XCTAssertFalse(controller.isPresented)
        controller.stop()
    }

    func testHostedUserRoleLabelsRetainProvenance() throws {
        let origins = ["human", "automatic", "tool", "system", "unknown"]
        let hosted = show(VStack {
            ForEach(origins, id: \.self) { origin in
                ConversationMessageView(message: .init(id: origin, role: "user", origin: origin, blocks: [.init(id: origin, kind: "text", text: "Fixture")])) {}
            }
        }, width: 420, height: 700)
        let elements = AccessibilityProbe.elements(in: hosted)
        let textValues = accessibleText(in: hosted)
        for origin in origins {
            let speaker = try XCTUnwrap(elements.first { $0.identifier == "history.speaker.\(origin)" })
            let label = textValues.first { $0.id == speaker.identifier }?.text
            XCTAssertEqual(label, ConversationMessageView.speaker(for: "user", origin: origin))
            if origin != "human" { XCTAssertNotEqual(label, String(localized: "You")) }
        }
    }

    func testHostedReadFullMessageLoadsUnicodeCodeAndKeepsToolsCollapsed() async throws {
        let provider = ExpandedHistoryViewFixtureProvider()
        let controller = makeController(provider: provider)
        await waitReady(controller)
        controller.open()
        let hosted = show(ConversationHistoryDrawer(controller: controller), width: 420, height: 700)
        let beforeClipboard = NSPasteboard.general.changeCount
        let read = try XCTUnwrap(AccessibilityProbe.elements(in: hosted).first { $0.identifier == "history.readFull.reply-long" })
        AccessibilityProbe.press(read)
        for _ in 0..<100 {
            await Task.yield()
            if await provider.blockReads().count == 3, !controller.copyInProgress { break }
        }
        settle()
        let elements = AccessibilityProbe.elements(in: hosted)
        XCTAssertTrue(elements.contains { $0.identifier == "history.fullMessage.close" })
        let text = accessibleText(in: hosted).map(\.text)
        XCTAssertTrue(text.contains("Hello 世界 🌍"), "\(text)")
        XCTAssertTrue(text.contains("print(\"世界\")\n// done"), "\(text)")
        XCTAssertFalse(elements.contains { $0.name?.contains("hidden full tool") == true })
        let cursors = await provider.blockReads()
        XCTAssertEqual(cursors, ["text-1", "code-1", "code-2"])
        XCTAssertEqual(NSPasteboard.general.changeCount, beforeClipboard, "Reading full text does not copy it")
        XCTAssertTrue(controller.messages.first!.blocks.contains { $0.truncated }, "Expanded body is transient")
        controller.stop()
        settle()
        XCTAssertFalse(AccessibilityProbe.elements(in: hosted).contains { $0.identifier == "history.fullMessage.close" })
    }

    func testHostedFullMessageLoadingCanBeCancelled() async throws {
        let provider = ExpandedHistoryViewFixtureProvider(delayed: true)
        let controller = makeController(provider: provider)
        await waitReady(controller)
        controller.open()
        let hosted = show(ConversationHistoryDrawer(controller: controller), width: 420, height: 700)
        AccessibilityProbe.press(try XCTUnwrap(AccessibilityProbe.elements(in: hosted).first { $0.identifier == "history.readFull.reply-long" }))
        settle()
        AccessibilityProbe.press(try XCTUnwrap(AccessibilityProbe.elements(in: hosted).first { $0.identifier == "history.cancelLoading" }))
        for _ in 0..<100 where controller.copyInProgress { await Task.yield() }
        settle()
        XCTAssertFalse(controller.copyInProgress)
        XCTAssertFalse(AccessibilityProbe.elements(in: hosted).contains { $0.identifier == "history.fullMessage.close" })
        controller.stop()
    }

    func testOlderAroundTurnContinuesIntoAssistantAndToolPages() async throws {
        let provider = ForwardPagedHistoryFixtureProvider()
        let controller = makeController(provider: provider)
        await waitReady(controller)
        XCTAssertFalse(controller.messages.contains { $0.id == "old-user" })
        controller.open(turnID: "old-turn")
        for _ in 0..<100 {
            await Task.yield()
            if controller.canLoadNewer { break }
        }
        let hosted = show(ConversationHistoryDrawer(controller: controller), width: 420, height: 700)
        let newer = try XCTUnwrap(AccessibilityProbe.elements(in: hosted).first { $0.identifier == "history.newer" })
        AccessibilityProbe.press(newer)
        for _ in 0..<100 {
            await Task.yield()
            if controller.messages.contains(where: { $0.id == "old-reply-tail" }), !controller.isLoadingNewer { break }
        }
        let reads = await provider.readWindows()
        XCTAssertTrue(reads.contains(.around(messageID: "old-user")))
        XCTAssertTrue(reads.contains(.after(cursor: "same-turn-tail")))
        XCTAssertEqual(controller.selectedMessageID, "old-user")
        XCTAssertTrue(controller.messages.contains { $0.id == "old-tool" && $0.turnID == "old-turn" })
        XCTAssertTrue(controller.messages.contains { $0.id == "old-reply-tail" && $0.turnID == "old-turn" })
        XCTAssertFalse(controller.canLoadNewer)
        controller.stop()
    }

    func testPartialSourceNoticeDoesNotHideAvailableMessages() async throws {
        let provider = ExpandedHistoryViewFixtureProvider(completeness: "partial_unsupported_records")
        let controller = makeController(provider: provider)
        await waitReady(controller)
        controller.open()
        let hosted = show(ConversationHistoryDrawer(controller: controller), width: 420, height: 700)
        XCTAssertEqual(controller.state, .ready)
        XCTAssertTrue(accessibleText(in: hosted).contains { $0.text == String(localized: "Some saved records could not be displayed.") })
        XCTAssertTrue(AccessibilityProbe.elements(in: hosted).contains { $0.identifier == "history.readFull.reply-long" })
        controller.stop()
    }

    func testOpeningOverlayLeavesUnderlyingTerminalSizeAndIdentityStable() async throws {
        let provider = HistoryViewFixtureProvider()
        let controller = ConversationHistoryController()
        controller.select(deviceID: UUID(), paneID: "fixture-pane", session: .init(source: "herdr:claude", agent: "claude", kind: "id", value: "fixture-session"), provider: provider)
        controller.setVisible(true)
        await waitReady(controller)
        let terminal = NSView()
        let root = HistoryTerminalFixture(terminal: terminal, controller: controller)
        let hosted = show(root, width: 800, height: 500)
        let initial = terminal.bounds.size
        XCTAssertEqual(initial, NSSize(width: 800 - ConversationHistoryOverlay.gutterWidth, height: 500))
        controller.open(turnID: "turn-1")
        settle()
        if let content = hosted.contentView, let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: bitmap)
            if let png = bitmap.representation(using: .png, properties: [:]) {
                try png.write(to: URL(fileURLWithPath: "/tmp/herdrm-history-preview.png"))
            }
        }
        XCTAssertEqual(terminal.bounds.size, initial)
        XCTAssertNotNil(terminal.window)
        controller.close()
        settle()
        XCTAssertEqual(terminal.bounds.size, initial)
        XCTAssertEqual(hosted.contentView?.bounds.width, 800)
        controller.stop()
    }

    func testClosedOverlayPassesTerminalHitTestingAndRailHoverKeepsFocus() async throws {
        let provider = HistoryViewFixtureProvider()
        let controller = makeController(provider: provider)
        await waitReady(controller)
        let terminal = HistoryMouseTerminal()
        let hosted = show(HistoryTerminalFixture(terminal: terminal, controller: controller), width: 800, height: 500)
        hosted.acceptsMouseMovedEvents = true
        let center = terminal.convert(NSPoint(x: terminal.bounds.midX, y: terminal.bounds.midY), to: nil)
        let content = try XCTUnwrap(hosted.contentView)
        XCTAssertTrue(content.hitTest(center) === terminal, "The native hit-test target outside rail/History is the retained terminal")
        XCTAssertEqual(terminal.bounds.size, NSSize(width: 800 - ConversationHistoryOverlay.gutterWidth, height: 500))
        hosted.makeFirstResponder(terminal)
        XCTAssertTrue(hosted.firstResponder === terminal)
        let before = await provider.readWindows()
        let pointer = try railPointer(in: content)
        let resting = ConversationRailGeometry(count: controller.turns.count, height: pointer.bounds.height)
        let hoverPoint = pointer.convert(NSPoint(x: pointer.bounds.midX, y: resting.position(of: 0)), to: nil)
        hosted.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: hoverPoint, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: hosted.windowNumber, context: nil, eventNumber: 2, clickCount: 0, pressure: 0)))
        settle()
        XCTAssertTrue(hosted.firstResponder === terminal, "Rail pointer preview must preserve terminal focus")
        let after = await provider.readWindows()
        XCTAssertEqual(after, before, "Pointer preview performs no reads")
        XCTAssertFalse(controller.isPresented)
        controller.open(turnID: "turn-1")
        settle()
        XCTAssertFalse(content.hitTest(center) === terminal, "The visible drawer owns pointer events inside its bounds")
        controller.stop()
    }

    func testFirstTerminalColumnReceivesSelectionWithRestingAndHoveredRail() async throws {
        let provider = HistoryViewFixtureProvider()
        let controller = makeController(provider: provider)
        await waitReady(controller)
        let terminal = HistoryMouseTerminal()
        var jumps: [String] = []
        let hosted = show(HistoryTerminalFixture(terminal: terminal, controller: controller, onJump: { jumps.append($0) }), width: 800, height: 500)
        hosted.makeKeyAndOrderFront(nil)
        hosted.makeFirstResponder(terminal)
        settle()
        XCTAssertTrue(terminal.acceptsFirstMouse(for: nil), "The fixture accepts synthetic clicks even when the test runner app is inactive")

        let content = try XCTUnwrap(hosted.contentView)
        let pointer = try railPointer(in: content)
        let railFrame = pointer.convert(pointer.bounds, to: content)
        let terminalFrame = terminal.convert(terminal.bounds, to: content)
        XCTAssertLessThanOrEqual(railFrame.maxX, terminalFrame.minX,
                                 "Rail pointer bounds must end before the first terminal column")
        XCTAssertEqual(terminalFrame.minX, ConversationHistoryOverlay.gutterWidth)
        let resting = ConversationRailGeometry(count: controller.turns.count, height: pointer.bounds.height)
        let railPoint = pointer.convert(NSPoint(x: pointer.bounds.midX, y: resting.position(of: 0)), to: nil)
        let lineY = terminal.convert(railPoint, from: nil).y
        let firstColumn = terminal.convert(NSPoint(x: 0.5, y: lineY), to: nil)
        let selectionEnd = terminal.convert(NSPoint(x: HistoryMouseTerminal.cellWidth * 6 + 0.5, y: lineY), to: nil)
        let before = await provider.readWindows()

        func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint, number: Int) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: hosted.windowNumber, context: nil,
                                           eventNumber: number, clickCount: 1,
                                           pressure: type == .leftMouseUp ? 0 : 1))
        }
        let hover = try mouseEvent(.mouseMoved, at: railPoint, number: 10)
        for isHovered in [false, true] {
            if isHovered { pointer.mouseMoved(with: hover) }
            else { pointer.mouseExited(with: hover) }
            settle()
            XCTAssertFalse(controller.isPresented)
            XCTAssertTrue(content.hitTest(firstColumn) === terminal,
                          "The beginning of a terminal line remains selectable while rail hover is \(isHovered)")
            XCTAssertTrue(content.hitTest(selectionEnd) === terminal,
                          "Even a preview drawn above the line must allow terminal text selection")
            hosted.sendEvent(try mouseEvent(.leftMouseDown, at: firstColumn, number: 11))
            hosted.sendEvent(try mouseEvent(.leftMouseDragged, at: selectionEnd, number: 12))
            hosted.sendEvent(try mouseEvent(.leftMouseUp, at: selectionEnd, number: 13))
            settle()
            XCTAssertEqual(terminal.selectedText, "First ")
            XCTAssertEqual(try XCTUnwrap(terminal.selectionStart).x, 0.5, accuracy: 0.01)
            XCTAssertTrue(hosted.firstResponder === terminal,
                          "Selecting terminal text must preserve its native keyboard focus")
            XCTAssertTrue(jumps.isEmpty, "Text selection must not navigate the history")
        }
        XCTAssertEqual(terminal.clicks, 2)
        XCTAssertEqual(terminal.drags, 2, "Both selection gestures reach the native terminal")
        let after = await provider.readWindows()
        XCTAssertEqual(after, before, "Terminal selection performs no history reads")
        controller.stop()
    }

    func testNativeRailHoverAndCoordinateClickSelectTurnWithoutTerminalInput() async throws {
        let provider = HistoryViewFixtureProvider()
        let controller = makeController(provider: provider)
        await waitReady(controller)
        let terminal = HistoryMouseTerminal()
        var jumps: [String] = []
        let hosted = show(HistoryTerminalFixture(terminal: terminal, controller: controller, onJump: { jumps.append($0) }), width: 800, height: 500)
        XCTAssertTrue(hosted.acceptsMouseMovedEvents, "The production rail enables pointer-move delivery itself")
        hosted.makeKeyAndOrderFront(nil)
        hosted.makeFirstResponder(terminal)
        settle()

        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let content = try XCTUnwrap(hosted.contentView)
        let pointer = try XCTUnwrap(descendants(content).compactMap { $0 as? ConversationRailPointerView }.first)
        let railFrame = pointer.convert(pointer.bounds, to: terminal)
        XCTAssertLessThanOrEqual(railFrame.height, terminal.bounds.height * 0.75,
                                 "Long histories must not stretch the rail over the whole terminal")
        XCTAssertGreaterThanOrEqual(railFrame.minY, terminal.bounds.height * 0.2,
                                    "The rail leaves the lower terminal input and status area clear")
        XCTAssertFalse(pointer.acceptsFirstResponder)
        XCTAssertTrue(pointer.acceptsFirstMouse(for: nil))
        XCTAssertFalse(pointer.isAccessibilityElement())
        let resting = ConversationRailGeometry(count: controller.turns.count, height: pointer.bounds.height)
        let location = pointer.convert(NSPoint(x: pointer.bounds.midX, y: resting.position(of: 0)), to: nil)
        XCTAssertTrue(content.hitTest(location) === pointer, "The real native hit-test chain owns a coordinate click on a mark")
        let before = await provider.readWindows()
        let tickRect = pointer.convert(NSRect(x: 0, y: resting.position(of: 0) - 2, width: pointer.bounds.width, height: 4), to: content)
        func tickPixels() throws -> Data {
            let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: tickRect))
            content.cacheDisplay(in: tickRect, to: bitmap)
            return Data(bytes: try XCTUnwrap(bitmap.bitmapData), count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        }
        let restingPixels = try tickPixels()
        var hoverPoints: [NSPoint?] = []
        let nativeHover = pointer.onHover
        pointer.onHover = { hoverPoints.append($0); nativeHover($0) }
        let hover = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: hosted.windowNumber, context: nil, eventNumber: 3, clickCount: 0, pressure: 0))
        // AppKit synthesizes tracking callbacks from WindowServer motion;
        // sendEvent alone does not synthesize them for an injected event.
        // Exercise that native tracking owner using the same window point.
        pointer.mouseMoved(with: hover)
        settle()
        XCTAssertEqual(try XCTUnwrap(hoverPoints.last), NSPoint(x: pointer.bounds.midX, y: resting.position(of: 0)))
        XCTAssertNotEqual(try tickPixels(), restingPixels, "Hover must visibly grow the tick in the rendered rail")
        XCTAssertTrue(hosted.firstResponder === terminal)
        let afterHover = await provider.readWindows()
        XCTAssertEqual(afterHover, before, "Hover uses cached prompt/reply previews")

        let click = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: hosted.windowNumber, context: nil, eventNumber: 4, clickCount: 1, pressure: 1))
        hosted.sendEvent(click)
        settle()
        XCTAssertEqual(jumps, ["turn-1"], "A physical point on the first tick invokes exactly that turn's jump callback")
        XCTAssertEqual(terminal.clicks, 0, "Rail navigation must not deliver a click or input to the retained terminal")
        XCTAssertTrue(hosted.firstResponder === terminal)
        XCTAssertFalse(controller.isPresented)

        pointer.mouseExited(with: hover)
        settle()
        XCTAssertEqual(try tickPixels(), restingPixels, "Leaving the rail restores the compact tick")
        controller.stop()
    }

    private func waitReady(_ controller: ConversationHistoryController) async {
        for _ in 0..<100 where controller.state != .ready { await Task.yield() }
        XCTAssertEqual(controller.state, .ready)
    }
    private func railPointer(in content: NSView) throws -> ConversationRailPointerView {
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        return try XCTUnwrap(descendants(content).compactMap { $0 as? ConversationRailPointerView }.first)
    }
    private func makeController(provider: any ConversationHistoryProviding) -> ConversationHistoryController {
        let controller = ConversationHistoryController()
        controller.select(deviceID: UUID(), paneID: "fixture-pane", session: .init(source: "herdr:claude", agent: "claude", kind: "id", value: "fixture-session"), provider: provider)
        controller.setVisible(true)
        return controller
    }
    private func show<V: View>(_ view: V, width: CGFloat, height: CGFloat) -> NSWindow {
        let host = NSHostingView(rootView: view)
        let result = NSWindow(contentRect: .init(x: 0, y: 0, width: width, height: height), styleMask: [.titled], backing: .buffered, defer: false)
        result.isReleasedWhenClosed = false
        result.title = "History fixture \(UUID().uuidString)"
        result.contentView = host
        result.orderFrontRegardless()
        window = result
        settle()
        return result
    }
    private func settle() { RunLoop.current.run(until: Date().addingTimeInterval(0.15)) }

    /// SwiftUI static text exposes its spoken content in AXValue, while buttons
    /// use AXDescription/AXTitle. Inspect the correct native attribute for each.
    private func accessibleText(in window: NSWindow) -> [(id: String?, text: String)] {
        func attribute(_ element: AXUIElement, _ key: String) -> AnyObject? {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
        }
        let app = AXUIElementCreateApplication(getpid())
        let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
        var values: [(id: String?, text: String)] = []
        func walk(_ element: AXUIElement, depth: Int = 0) {
            guard depth < 40 else { return }
            let text = (attribute(element, kAXValueAttribute) as? String)
                ?? (attribute(element, kAXDescriptionAttribute) as? String)
                ?? (attribute(element, kAXTitleAttribute) as? String)
            if let text { values.append((attribute(element, kAXIdentifierAttribute) as? String, text)) }
            for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] { walk(child, depth: depth + 1) }
        }
        for item in windows where attribute(item, kAXTitleAttribute) as? String == window.title { walk(item) }
        return values
    }
}

private actor HistoryViewFixtureProvider: ConversationHistoryProviding {
    private var windows: [ConversationWindow] = []
    func readWindows() -> [ConversationWindow] { windows }
    func read(target: String, expectedSessionID: String, window: ConversationWindow, limits: ConversationLimits) async throws -> ConversationPage {
        windows.append(window)
        if case .after = window {
            return .init(binding: .init(provider: "claude", sessionID: "fixture-session", generation: "g"), revision: "r", messages: [
                .init(id: "reply-next-page", turnID: "turn-2", role: "assistant", order: 3, blocks: [.init(id: "page-2", kind: "text", text: "The rest of the reply to this same turn")])
            ])
        }
        return .init(binding: .init(provider: "claude", sessionID: "fixture-session", generation: "g"), revision: "r", messages: [
            .init(id: "user-1", turnID: "turn-1", role: "user", order: 0, blocks: [.init(id: "u1", kind: "text", text: "First question")]),
            .init(id: "reply-1", turnID: "turn-1", role: "assistant", order: 1, blocks: [.init(id: "a1", kind: "text", text: "First reply")]),
            .init(id: "user-2", turnID: "turn-2", role: "user", order: 2, blocks: [.init(id: "u2", kind: "text", text: "Second question")])
        ], turns: [
            .init(id: "turn-1", messageID: "user-1", preview: "First question", ordinal: 1),
            .init(id: "turn-2", messageID: "user-2", preview: "Second question", ordinal: 2)
        ], beforeCursor: "older", afterCursor: "newer")
    }
    func readBlock(target: String, expectedSessionID: String, blockCursor: String, maxBytes: Int) async throws -> BlockPage {
        throw ConversationHistoryError.invalidContinuation
    }
}

private actor ExpandedHistoryViewFixtureProvider: ConversationHistoryProviding {
    let delayed: Bool
    let completeness: String
    private var cursors: [String] = []
    init(delayed: Bool = false, completeness: String = "source_available") { self.delayed = delayed; self.completeness = completeness }
    func blockReads() -> [String] { cursors }
    private var binding: ConversationBinding { .init(provider: "claude", sessionID: "fixture-session", generation: "g") }
    func read(target: String, expectedSessionID: String, window: ConversationWindow, limits: ConversationLimits) async throws -> ConversationPage {
        .init(binding: binding, revision: "r", completeness: completeness, messages: [
            .init(id: "reply-long", role: "assistant", messageRevision: "mr", blocks: [
                .init(id: "text", kind: "text", text: "Hello ", blockCursor: "text-1", truncated: true),
                .init(id: "code", kind: "code", text: "print(\"", blockCursor: "code-1", truncated: true),
                .init(id: "tool", kind: "tool_result", text: "hidden full tool", name: "Fixture tool")
            ])
        ])
    }
    func readBlock(target: String, expectedSessionID: String, blockCursor: String, maxBytes: Int) async throws -> BlockPage {
        cursors.append(blockCursor)
        if delayed { try await Task.sleep(for: .seconds(30)) }
        switch blockCursor {
        case "text-1": return .init(binding: binding, revision: "r", messageID: "reply-long", messageRevision: "mr", blockID: "text", kind: "text", text: "世界 🌍", sliceIndex: 1)
        case "code-1": return .init(binding: binding, revision: "r", messageID: "reply-long", messageRevision: "mr", blockID: "code", kind: "code", text: "世界", sliceIndex: 1, nextCursor: "code-2")
        case "code-2": return .init(binding: binding, revision: "r", messageID: "reply-long", messageRevision: "mr", blockID: "code", kind: "code", text: "\")\n// done", sliceIndex: 2)
        default: throw ConversationHistoryError.invalidContinuation
        }
    }
}

private actor ForwardPagedHistoryFixtureProvider: ConversationHistoryProviding {
    private var windows: [ConversationWindow] = []
    private var binding: ConversationBinding { .init(provider: "claude", sessionID: "fixture-session", generation: "g") }
    func readWindows() -> [ConversationWindow] { windows }
    func read(target: String, expectedSessionID: String, window: ConversationWindow, limits: ConversationLimits) async throws -> ConversationPage {
        windows.append(window)
        switch window {
        case .around:
            return .init(binding: binding, revision: "r", messages: [
                .init(id: "old-user", turnID: "old-turn", role: "user", origin: "human", order: 0, blocks: [.init(id: "old-u", kind: "text", text: "Older question")]),
                .init(id: "old-reply-start", turnID: "old-turn", role: "assistant", order: 1, blocks: [.init(id: "old-a", kind: "text", text: "First page of the reply")])
            ], afterCursor: "same-turn-tail")
        case .after:
            return .init(binding: binding, revision: "r", messages: [
                .init(id: "old-tool", turnID: "old-turn", role: "tool", origin: "tool", order: 2, blocks: [.init(id: "old-t", kind: "tool_result", text: "Tool output")]),
                .init(id: "old-reply-tail", turnID: "old-turn", role: "assistant", order: 3, blocks: [.init(id: "old-end", kind: "text", text: "Final reply after the tool")])
            ])
        default:
            return .init(binding: binding, revision: "r", messages: [
                .init(id: "current-user", turnID: "current-turn", role: "user", origin: "human", order: 4, blocks: [.init(id: "current-u", kind: "text", text: "Latest question")])
            ], turns: [
                .init(id: "old-turn", messageID: "old-user", preview: "Older question", ordinal: 1),
                .init(id: "current-turn", messageID: "current-user", preview: "Latest question", ordinal: 2)
            ])
        }
    }
    func readBlock(target: String, expectedSessionID: String, blockCursor: String, maxBytes: Int) async throws -> BlockPage {
        throw ConversationHistoryError.invalidContinuation
    }
}

private struct HistoryTerminalFixture: View {
    let terminal: NSView
    let controller: ConversationHistoryController
    var onJump: ((String) -> Void)? = nil
    var body: some View {
        HistoryNativeTerminal(view: terminal)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.leading, ConversationHistoryOverlay.gutterWidth)
            .overlay { ConversationHistoryOverlay(controller: controller, onJump: onJump) }
    }
}
private struct HistoryNativeTerminal: NSViewRepresentable {
    let view: NSView
    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class HistoryMouseTerminal: NSView {
    static let cellWidth: CGFloat = 8
    private let line = "First column selection fixture"
    var clicks = 0
    var drags = 0
    private(set) var selectionStart: NSPoint?
    private(set) var selectedText = ""
    override var acceptsFirstResponder: Bool { true }
    // Injected sendEvent does not activate the test application through the
    // WindowServer. Accept that first click so this fixture exercises native
    // event dispatch rather than testing application-activation policy.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        clicks += 1
        selectionStart = convert(event.locationInWindow, from: nil)
        selectedText = ""
        window?.makeFirstResponder(self)
    }
    override func mouseDragged(with event: NSEvent) {
        drags += 1
        guard let selectionStart else { return }
        let end = convert(event.locationInWindow, from: nil)
        let characters = Array(line)
        let lower = min(characters.count, max(0, Int(min(selectionStart.x, end.x) / Self.cellWidth)))
        let upper = min(characters.count, max(lower, Int(max(selectionStart.x, end.x) / Self.cellWidth)))
        selectedText = String(characters[lower..<upper])
    }
}
