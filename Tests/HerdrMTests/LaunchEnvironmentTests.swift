import XCTest
@testable import herdrm

final class LaunchEnvironmentTests: XCTestCase {
    /// The app skips the Keychain migration, the relay and the askpass purge
    /// when it hosts these tests, so a test run never makes macOS ask about
    /// the installed app's Keychain items.
    func testTheTestHostIsRecognized() {
        XCTAssertTrue(LaunchEnvironment.isTestHost)
    }
}
