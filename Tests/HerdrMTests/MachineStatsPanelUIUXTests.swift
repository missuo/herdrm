import AppKit
import HerdrKit
import SwiftUI
import XCTest
@testable import herdrm

@MainActor
final class MachineStatsPanelUIUXTests: XCTestCase {
    func testLongPanelFitsScrollsAndDismissesAfterResize() throws {
        let device = Device(name: "test1", kind: .local, socketPath: "/tmp/herdrm-test-no-socket")
        let model = AppModel()
        model.devices = [device]
        var sample = MachineSample()
        sample.os = "Linux"
        sample.host = "test1"
        sample.memTotalBytes = 16_000_000_000
        sample.memUsedBytes = 8_000_000_000
        for i in 1...40 {
            let pid = Int32(i + 100)
            sample.processes[pid] = MachineProcess(pid: pid, ppid: 1, cpuTime: 1, rssBytes: 1_000_000, name: "test\(i)")
        }
        var snapshot = MachineStatsComputer.snapshot(previous: nil, current: sample)
        // Many mounted volumes are another unbounded source of panel content.
        let frame = """
        @@hm-begin
        os Linux
        host test1
        @@df
        Filesystem 1024-blocks Used Available Capacity Mounted on
        \((1...30).map { "/dev/test\($0) 100000 50000 50000 50% /test\($0)" }.joined(separator: "\n"))
        """
        snapshot.disks = try XCTUnwrap(MachineStatsParser.parse(frame)).disks
        XCTAssertGreaterThan(snapshot.disks.count, 20)
        model.machineStats._setSnapshotForTesting(snapshot, device: device)
        model.showMachineStats = true
        let root = NSHostingView(rootView: MachineStatsOverlay(model: model, device: device))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 980, height: 620), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.contentView = root
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        settle(root)

        let scroll = try XCTUnwrap(findScroll(in: root))
        for height in [620.0, 800.0] {
            window.setContentSize(NSSize(width: 980, height: height))
            settle(root)
            let frame = scroll.convert(scroll.bounds, to: nil)
            let close = try XCTUnwrap(window.standardWindowButton(.closeButton))
            let closeFrame = try XCTUnwrap(close.superview).convert(close.frame, to: nil)
            XCTAssertLessThan(frame.maxY, closeFrame.minY, "panel must not cover traffic lights")
            XCTAssertGreaterThan(try XCTUnwrap(scroll.documentView).bounds.height, scroll.contentView.bounds.height, "long content must scroll")
        }
        let panelFrame = scroll.convert(scroll.bounds, to: nil)
        let panelPoint = NSPoint(x: panelFrame.midX, y: panelFrame.midY)
        let panelTarget = try XCTUnwrap(root.hitTest(root.superview?.convert(panelPoint, from: nil) ?? panelPoint))
        XCTAssertTrue(panelTarget === scroll || panelTarget.isDescendant(of: scroll), "panel content must receive clicks above the dismissal layer")
        let document = try XCTUnwrap(scroll.documentView)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.bounds.height - scroll.contentView.bounds.height)))
        scroll.reflectScrolledClipView(scroll.contentView)
        XCTAssertGreaterThan(scroll.contentView.bounds.origin.y, 0, "bottom rows are reachable")

        // A hover panel: nothing outside it catches clicks meant for the window.
        let point = NSPoint(x: 700, y: 300)
        let target = root.hitTest(root.superview?.convert(point, from: nil) ?? point)
        XCTAssertFalse(target.map { $0 === scroll || $0.isDescendant(of: scroll) } ?? false,
                       "a click outside the panel must not land in it")

        model.setMachineStatsHover(card: true, immediately: true)
        XCTAssertTrue(model.showMachineStats, "known-yes: hovering the card shows the panel")
        model.setMachineStatsHover(card: false, panel: false, immediately: true)
        XCTAssertFalse(model.showMachineStats, "leaving the card and the panel hides it")
    }

    func testShortPanelKeepsItsOwnHeight() throws {
        let device = Device(name: "test1", kind: .local, socketPath: "/tmp/herdrm-test-no-socket")
        let model = AppModel()
        model.devices = [device]
        var sample = MachineSample()
        sample.os = "Linux"
        sample.host = "test1"
        sample.memTotalBytes = 16_000_000_000
        sample.memUsedBytes = 8_000_000_000
        sample.processes[101] = MachineProcess(pid: 101, ppid: 1, cpuTime: 1, rssBytes: 1_000_000, name: "test1")
        model.machineStats._setSnapshotForTesting(MachineStatsComputer.snapshot(previous: nil, current: sample), device: device)
        model.showMachineStats = true
        let root = NSHostingView(rootView: MachineStatsOverlay(model: model, device: device))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 980, height: 800), styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        settle(root)
        XCTAssertNil(findScroll(in: root), "a panel that fits must not stretch into a window-tall scroll view")
    }

    private func findScroll(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for child in view.subviews { if let scroll = findScroll(in: child) { return scroll } }
        return nil
    }

    private func settle(_ root: NSView) {
        let until = Date().addingTimeInterval(0.5)
        while Date() < until {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            root.layoutSubtreeIfNeeded()
        }
    }
}
