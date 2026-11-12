import AppKit
import XCTest
@testable import herdrm

@MainActor
final class DeviceFileSelectionUIUXTests: XCTestCase {
    func testCommandClickTogglesFilesAndShiftClickSelectsTheDisplayedRange() async throws {
        let files = try await DeviceFilesHarness()
        try files.clickFile("test1.txt")
        try files.clickFile("test10.txt", modifiers: .command)
        XCTAssertTrue(files.visibleText.contains(String(localized: "Selected: \(2)")))
        try files.clickFile("test1.txt", modifiers: .command)
        XCTAssertTrue(files.visibleText.contains(String(localized: "Selected: \(1)")))

        try files.click("Size")
        try files.clickFile("test2.txt")
        try files.clickFile("test10.txt", modifiers: .shift)
        XCTAssertTrue(files.visibleText.contains(String(localized: "Selected: \(3)")))
    }

    func testSelectAllOnlySelectsFilesInTheFocusedPaneAndRefreshKeepsThem() async throws {
        let files = try await DeviceFilesHarness()
        try files.clickFile("test1.txt", pane: 1)
        try files.selectAll()
        XCTAssertEqual(files.visibleText.filter { $0 == String(localized: "Selected: \(3)") }.count, 1)
        await files.right.refresh()
        XCTAssertEqual(files.visibleText.filter { $0 == String(localized: "Selected: \(3)") }.count, 1)
    }
}
