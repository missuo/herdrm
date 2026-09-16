import AppKit
import XCTest
@testable import herdrm

final class SidebarStickyLayoutUnitTests: XCTestCase {
    func testVisibleSectionsOmitTerminalsWhenHidden() {
        XCTAssertEqual(
            SidebarStickyLayout.visibleSections(terminalsVisible: false),
            [.spaces, .agents]
        )
    }

    func testVisibleSectionsIncludeTerminalsWhenShown() {
        XCTAssertEqual(
            SidebarStickyLayout.visibleSections(terminalsVisible: true),
            [.spaces, .agents, .terminals]
        )
    }

    func testPinnedSectionStaysOnSpacesUntilAgentsHeaderReachesTop() {
        let bodies: [SidebarSectionID: CGFloat] = [
            .spaces: 400,
            .agents: 400,
            .terminals: 200,
        ]
        let takeover = SidebarStickyLayout.headerHeight + 400 + SidebarStickyLayout.interSectionGap

        XCTAssertEqual(
            SidebarStickyLayout.pinnedSection(
                scrollOffsetY: 0,
                sectionBodyHeights: bodies,
                terminalsVisible: true
            ),
            .spaces
        )
        XCTAssertEqual(
            SidebarStickyLayout.pinnedSection(
                scrollOffsetY: takeover - 1,
                sectionBodyHeights: bodies,
                terminalsVisible: true
            ),
            .spaces
        )
        XCTAssertEqual(
            SidebarStickyLayout.pinnedSection(
                scrollOffsetY: takeover,
                sectionBodyHeights: bodies,
                terminalsVisible: true
            ),
            .agents
        )
    }

    func testPinnedSectionHandsOffAgentsToTerminals() {
        let bodies: [SidebarSectionID: CGFloat] = [
            .spaces: 100,
            .agents: 100,
            .terminals: 100,
        ]
        let spacesSpan = SidebarStickyLayout.headerHeight + 100 + SidebarStickyLayout.interSectionGap
        let agentsSpan = SidebarStickyLayout.headerHeight + 100 + SidebarStickyLayout.interSectionGap
        let terminalsTakeover = spacesSpan + agentsSpan

        XCTAssertEqual(
            SidebarStickyLayout.pinnedSection(
                scrollOffsetY: terminalsTakeover - 1,
                sectionBodyHeights: bodies,
                terminalsVisible: true
            ),
            .agents
        )
        XCTAssertEqual(
            SidebarStickyLayout.pinnedSection(
                scrollOffsetY: terminalsTakeover,
                sectionBodyHeights: bodies,
                terminalsVisible: true
            ),
            .terminals
        )
    }
}

final class SidebarStickyContractTests: XCTestCase {
    func testPinnedViewsContractIsSectionHeaders() {
        XCTAssertTrue(SidebarStickyLayout.pinsSectionHeaders)
        XCTAssertEqual(SidebarStickyLayout.pinnedViews, [.sectionHeaders])
    }

    func testAccessibilityIdentifiersAreStable() {
        XCTAssertEqual(SidebarSectionID.spaces.accessibilityIdentifier, "sidebar.section.spaces")
        XCTAssertEqual(SidebarSectionID.agents.accessibilityIdentifier, "sidebar.section.agents")
        XCTAssertEqual(SidebarSectionID.terminals.accessibilityIdentifier, "sidebar.section.terminals")
    }

    func testHeaderAndGapConstantsMatchSidebarChrome() {
        XCTAssertEqual(SidebarStickyLayout.headerHeight, 28)
        XCTAssertEqual(SidebarStickyLayout.interSectionGap, 10)
    }
}
