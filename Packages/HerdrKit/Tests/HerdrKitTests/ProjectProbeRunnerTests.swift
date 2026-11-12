#if os(macOS)
import XCTest
@testable import HerdrKit

final class ProjectProbeRunnerTests: XCTestCase {
    private let remote = Device(name: "r", kind: .ssh(target: "dev@box"))

    func testSafeCwdsOnRemoteDropsOnlyBackslashAndControlCharacters() {
        let input = ["/home/dev/app", "/home/dev/it's", "/home/dev/a\\b", "/home/dev/a\nb", "/home/dev/a\u{7f}b", "/home/dev/ok dir"]
        XCTAssertEqual(
            DeviceProjectProbeRunner.safeCwds(input, for: remote),
            ["/home/dev/app", "/home/dev/it's", "/home/dev/ok dir"])
    }

    func testSafeCwdsOnLocalDropsControlCharactersButKeepsBackslashes() {
        let input = ["/Users/dev/it's", "/Users/dev/a\\b", "/Users/dev/a\nb", "/Users/dev/a\u{7f}b"]
        XCTAssertEqual(DeviceProjectProbeRunner.safeCwds(input, for: .local), ["/Users/dev/it's", "/Users/dev/a\\b"])
    }

    func testRunCollectingReturnsStdoutSoFarOnTimeout() async throws {
        let result = try await DeviceFileService(device: .local).runCollecting("echo part; exec sleep 30", timeout: 1)
        XCTAssertTrue(result.timedOut)
        XCTAssertNil(result.exitStatus)
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "part\n")
    }

    func testRunCollectingReturnsStdoutOnNonZeroExit() async throws {
        let result = try await DeviceFileService(device: .local).runCollecting("echo part; echo oops >&2; exit 3", timeout: 10)
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.exitStatus, 3)
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "part\n")
        XCTAssertEqual(String(decoding: result.stderr, as: UTF8.self), "oops\n")
    }
}
#endif
