import AppKit
import HerdrKit
import SwiftUI
import XCTest
@testable import herdrm

/// The sync section of the Claude Accounts window, read the way VoiceOver
/// reads it: the switch, the first-enable preview with its Apply button, and
/// the Re-authenticate… offer on a line that names a blocked account.
@MainActor
final class GrazrAccountsSyncUIUXTests: XCTestCase {
    private var window: NSWindow?

    override func tearDown() async throws {
        window?.close()
        window = nil
    }

    private func host(_ status: GrazrSyncStatus) -> [AccessibilityProbe.Element] {
        let model = AppModel()
        let device = Device(name: "cloud-dev", kind: .ssh(target: "me@cloud-dev"))
        model.devices = [device]
        model.sessions[device.id] = DeviceSessionState()
        model.grazrSyncStatus = status
        return host(GrazrAccountsSheet(model: model, device: device, autoload: false))
    }

    private func host(_ sheet: GrazrAccountsSheet) -> [AccessibilityProbe.Element] {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "GrazrAccountsSyncUIUX \(UUID().uuidString)"
        window.contentView = NSHostingView(rootView: sheet)
        window.orderFrontRegardless()
        self.window = window
        settle()
        return AccessibilityProbe.elements(in: window)
    }

    private func settle(seconds: TimeInterval = 0.5) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            window?.contentView?.layoutSubtreeIfNeeded()
        }
    }

    func testSyncToggleAndPreviewRender() {
        let text = "cloud-dev will move to gmail and take cloud-dev2’s order"
        let line = GrazrSyncLine(id: "push-1", text: text, tone: .ok, device: nil, blockedAccount: nil)
        let elements = host(.preview(lines: [line], pushes: []))

        let toggle = elements.first { $0.identifier == "grazr.sync.toggle" }
        XCTAssertNotNil(toggle, "no sync switch in \(elements.map { "\($0.role)|\($0.identifier ?? "")" })")
        XCTAssertTrue(["AXCheckBox", "AXSwitch"].contains(toggle?.role ?? ""), "switch role is \(toggle?.role ?? "nil")")
        XCTAssertTrue(elements.contains { ($0.name ?? $0.value ?? "").contains(text) }, "preview text missing")
        let apply = elements.first { $0.identifier == "grazr.sync.apply" }
        XCTAssertEqual(apply?.role, "AXButton")
        XCTAssertEqual(apply?.name, "Apply")
    }

    func testEachGrazrDeviceHasItsOwnSwitch() {
        let model = AppModel()
        let device = Device(name: "cloud-dev", kind: .ssh(target: "me@cloud-dev"))
        let other = Device(name: "cloud-dev2", kind: .ssh(target: "me@cloud-dev2"))
        model.devices = [device, other]
        var state = DeviceSessionState()
        state.usesGrazr = true
        model.sessions[device.id] = state
        model.sessions[other.id] = DeviceSessionState()
        model.grazrSyncStatus = .lines([])
        let elements = host(GrazrAccountsSheet(model: model, device: device, autoload: false))

        let row = elements.first { $0.identifier == "grazr.sync.device.\(device.id.uuidString)" }
        XCTAssertNotNil(row, "no switch for cloud-dev in \(elements.map { "\($0.role)|\($0.identifier ?? "")" })")
        XCTAssertTrue(["AXCheckBox", "AXSwitch"].contains(row?.role ?? ""), "row role is \(row?.role ?? "nil")")
        XCTAssertEqual(row?.name, "cloud-dev")
        XCTAssertEqual(row?.value, "1", "a device starts in the sync")
        XCTAssertNil(elements.first { $0.identifier == "grazr.sync.device.\(other.id.uuidString)" },
                     "a device without grazr has no switch")
    }

    func testBlockedLineOffersReauthenticate() {
        let device = Device(name: "cloud-dev", kind: .ssh(target: "me@cloud-dev"))
        let line = GrazrSyncLine(
            id: "problem-1", text: "cloud-dev: gmail is blocked (failed with 401), still on work",
            tone: .warning, device: device, blockedAccount: GrazrAccount(id: "id-gmail", name: "gmail")
        )
        let elements = host(.lines([line]))
        XCTAssertTrue(elements.contains { $0.role == "AXButton" && $0.name == "Re-authenticate…" },
                      "no Re-authenticate… button in \(elements.map { "\($0.role)|\($0.name ?? "")" })")
    }
}
