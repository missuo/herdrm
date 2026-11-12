import AppKit
import HerdrKit
import SwiftUI
import XCTest
@testable import herdrm

/// Settings › Appearance › Use herdr status symbols (#77).
@MainActor
final class HerdrStatusSymbolsTests: XCTestCase {
    private var saved: Any?

    override func setUp() {
        super.setUp()
        saved = UserDefaults.standard.object(forKey: SidebarDefaults.statusSymbolsKey)
    }

    override func tearDown() {
        UserDefaults.standard.set(saved, forKey: SidebarDefaults.statusSymbolsKey)
        super.tearDown()
    }

    /// The same symbols herdr's sidebar draws in its "distinct symbols" style.
    func testSymbolsMatchHerdrs() {
        func symbol(_ status: AgentStatus, unread: Bool = false) -> String {
            AgentStatusGlyph.herdrSymbol(status, unreadDone: unread).symbol
        }
        XCTAssertEqual(symbol(.blocked), "×")
        XCTAssertEqual(symbol(.working), "◐")
        XCTAssertEqual(symbol(.done, unread: true), "✓")
        XCTAssertEqual(symbol(.idle, unread: true), "✓", "an unread result survives an idle report")
        XCTAssertEqual(symbol(.done), "○", "a result you have read is idle, as herdr shows it once viewed")
        XCTAssertEqual(symbol(.idle), "○")
        XCTAssertEqual(symbol(.unknown), "·")
    }

    /// Off, an idle agent shows nothing (the Codex-style marks); on, it shows ○.
    func testTheSettingSwitchesWhatTheGlyphDraws() throws {
        func inkedPixels() throws -> Int {
            let renderer = ImageRenderer(content: AgentStatusGlyph(status: .idle)
                .frame(width: 24, height: 24).background(Color.black))
            let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
            var count = 0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                    if color.redComponent + color.greenComponent + color.blueComponent > 0.3 { count += 1 }
                }
            }
            return count
        }
        UserDefaults.standard.set(false, forKey: SidebarDefaults.statusSymbolsKey)
        XCTAssertEqual(try inkedPixels(), 0)
        UserDefaults.standard.set(true, forKey: SidebarDefaults.statusSymbolsKey)
        XCTAssertGreaterThan(try inkedPixels(), 0)
    }

    /// The sidebar with the option on, each status once (fake Agents 1–5).
    func testSidebarShowsHerdrSymbolsDemo() throws {
        UserDefaults.standard.set(true, forKey: SidebarDefaults.statusSymbolsKey)
        let sidebar = try SidebarHarness(spaces: 1, agents: 5, pinnedHeaders: false, height: 900)
        let model = sidebar.model
        let deviceID = try XCTUnwrap(model.visibleAgents.first).device.id
        var agents = try XCTUnwrap(model.sessions[deviceID]?.agents)
        XCTAssertEqual(agents.count, 5)
        let statuses: [AgentStatus] = [.blocked, .working, .working, .idle, .unknown]
        agents = zip(agents, statuses).map { $0.updatingStatus($1) }
        model.sessions[deviceID]?.agents = agents
        model.updateSnapshotAttention(agents: agents, deviceID: deviceID)
        var done = agents[2].updatingStatus(.done)
        done.completionSeq = 7
        agents[2] = done
        model.sessions[deviceID]?.agents = agents
        model.updateSnapshotAttention(agents: agents, deviceID: deviceID)
        sidebar.settleSidebar()
        XCTAssertTrue(sidebar.actionRowNames().contains { $0.hasPrefix("Agent 3, Unread") }, "\(sidebar.actionRowNames())")

        let screenshot = FileManager.default.temporaryDirectory.appendingPathComponent("herdr-status-symbols-demo.png")
        try sidebar.writeSnapshot(to: screenshot)
        let attachment = XCTAttachment(contentsOfFile: screenshot)
        attachment.name = "herdr status symbols (fake Agents 1–5)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
