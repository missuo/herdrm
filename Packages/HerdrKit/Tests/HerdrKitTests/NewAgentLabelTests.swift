import XCTest
@testable import HerdrKit

final class NewAgentLabelTests: XCTestCase {
    func testUsesTheSpaceName() {
        XCTAssertEqual(NewAgentLabel.make(spaceLabel: "cotabby", kind: "claude", taken: []), "cotabby")
    }

    func testNumbersASecondAgentInTheSameSpace() {
        XCTAssertEqual(NewAgentLabel.make(spaceLabel: "cotabby", kind: "claude", taken: ["cotabby"]), "cotabby 2")
        XCTAssertEqual(
            NewAgentLabel.make(spaceLabel: "cotabby", kind: "claude", taken: ["cotabby", "cotabby 2", "cotabby 4"]),
            "cotabby 3"
        )
    }

    func testFallsBackToTheKindWithoutASpace() {
        XCTAssertEqual(NewAgentLabel.make(spaceLabel: nil, kind: "codex", taken: ["codex"]), "codex")
        XCTAssertEqual(NewAgentLabel.make(spaceLabel: "  ", kind: "codex", taken: []), "codex")
    }

    func testTrimsTheSpaceName() {
        XCTAssertEqual(NewAgentLabel.make(spaceLabel: " imperum-v2 \n", kind: "claude", taken: []), "imperum-v2")
    }
}
