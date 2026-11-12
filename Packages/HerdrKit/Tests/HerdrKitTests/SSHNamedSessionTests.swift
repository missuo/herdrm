#if os(macOS)
import XCTest
@testable import HerdrKit

/// Named herdr sessions on SSH devices (issue #190): the forward, the attach
/// and the discovery scan must all reach `~/.config/herdr/sessions/<name>/`.
final class SSHNamedSessionTests: XCTestCase {
    func testSessionNamesNormalizeDefaultAndBlankToNil() {
        XCTAssertNil(Device.normalizedSessionName(nil))
        XCTAssertNil(Device.normalizedSessionName(""))
        XCTAssertNil(Device.normalizedSessionName("  "))
        XCTAssertNil(Device.normalizedSessionName("default"))
        XCTAssertEqual(Device.normalizedSessionName(" work "), "work")
        XCTAssertNil(Device(name: "R", kind: .ssh(target: "u@h"), sessionName: "default").sessionName)
    }

    func testSessionNameValidationRejectsPathsAndShellSyntax() {
        for valid in ["", "work", "agent-2", "a.b_c", "  work  "] {
            XCTAssertTrue(Device.isValidSessionName(valid), valid)
        }
        for invalid in [".", "..", "a/b", "../x", "a b", "a'b", "$(id)", "a;b", "é", String(repeating: "a", count: 65)] {
            XCTAssertFalse(Device.isValidSessionName(invalid), invalid)
        }
    }

    func testDevicesSavedBeforeSessionsStillDecode() throws {
        let legacy = #"[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"studio","kind":{"ssh":{"target":"u@h"}}}]"#
        let devices = try JSONDecoder().decode([Device].self, from: Data(legacy.utf8))
        XCTAssertEqual(devices.first?.sshTarget, "u@h")
        XCTAssertNil(devices.first?.sessionName)

        let named = Device(name: "work", kind: .ssh(target: "u@h"), sessionName: "work")
        let roundTrip = try JSONDecoder().decode(Device.self, from: JSONEncoder().encode(named))
        XCTAssertEqual(roundTrip.sessionName, "work")
    }

    func testRemoteSocketPathFollowsTheSession() {
        let unix = SSHTunnel.RemotePlatform.unix(home: "/home/u")
        XCTAssertEqual(SSHTunnel.remoteSocketPath(platform: unix, sessionName: nil), "/home/u/.config/herdr/herdr.sock")
        XCTAssertEqual(
            SSHTunnel.remoteSocketPath(platform: unix, sessionName: "work"),
            "/home/u/.config/herdr/sessions/work/herdr.sock"
        )
    }

    func testLocalForwardSocketDiffersPerSessionOnOneHost() {
        let base = SSHTunnel.localSocketPath(for: "u@h")
        XCTAssertEqual(SSHTunnel.localSocketPath(for: "u@h", sessionName: nil), base)
        XCTAssertEqual(SSHTunnel.localSocketPath(for: "u@h", sessionName: "default"), base)
        let work = SSHTunnel.localSocketPath(for: "u@h", sessionName: "work")
        XCTAssertNotEqual(work, base)
        XCTAssertEqual(work, SSHTunnel.localSocketPath(for: "u@h", sessionName: "work"))
        // The orphan reaper only accepts `<digits>.sock` names.
        let name = (work as NSString).lastPathComponent
        XCTAssertTrue(name.hasSuffix(".sock"))
        XCTAssertTrue(name.dropLast(5).allSatisfy(\.isNumber))
    }

    func testRemoteAttachPointsHerdrAtTheSessionSocket() {
        let device = Device(name: "work", kind: .ssh(target: "u@h"), sessionName: "work")
        let command = HerdrService(device: device, localServer: nil)
            .attachCommand(paneID: "w1:p1", serverVersion: "0.9.5")
        let remote = command.args.last ?? ""
        // The export sits inside the single-quoted sh -c script, so its own quotes are escaped.
        let export = remote.range(of: #"export HERDR_SOCKET_PATH="$HOME"/.config/herdr/sessions/'\''work'\''/herdr.sock;"#)
        let exec = remote.range(of: "exec \"$hb\" agent attach")
        XCTAssertNotNil(export, remote)
        if let export, let exec {
            XCTAssertLessThan(export.lowerBound, exec.lowerBound)
        }
    }

    func testDefaultSessionAttachSetsNoSocketOverride() {
        let device = Device(name: "R", kind: .ssh(target: "u@h"))
        let command = HerdrService(device: device, localServer: nil)
            .attachCommand(paneID: "w1:p1", serverVersion: "0.9.5")
        XCTAssertFalse(command.args.last?.contains("HERDR_SOCKET_PATH") ?? true)
        XCTAssertEqual(HerdrService.remoteSessionExport(sessionName: nil), "")
        XCTAssertEqual(HerdrService.remoteSessionExport(sessionName: "default"), "")
    }

    func testWindowsAttachUsesTheSessionsBridgeSocket() {
        let device = Device(name: "w", kind: .ssh(target: "u@win"), osID: "windows", sessionName: "work")
        let command = HerdrService(device: device, localServer: nil)
            .attachCommand(paneID: "w1:p1", serverVersion: "0.9.5")
        XCTAssertEqual(
            command.environment["HERDR_SOCKET_PATH"],
            SSHTunnel.localSocketPath(for: "u@win", sessionName: "work")
        )
    }

    func testScanOutputKeepsOnlyValidNamedSessions() {
        let output = "work\nagents\n\ndefault\nbad name\nwork\n../etc\n"
        XCTAssertEqual(SSHTunnel.namedSessions(inScanOutput: output), ["agents", "work"])
        XCTAssertEqual(SSHTunnel.namedSessions(inScanOutput: ""), [])
    }

    func testScanCommandListsSocketsUnderTheSessionsDirectory() {
        let command = SSHTunnel.namedSessionScanCommand
        XCTAssertTrue(command.contains(#""$HOME"/.config/herdr/sessions/*/herdr.sock"#))
        XCTAssertTrue(command.contains("[ -S"), "only live sockets, not stray files")
        XCTAssertTrue(command.hasSuffix("; true"), "an empty glob must not fail the ssh exec")
    }

    func testSubtitleNamesTheSession() {
        XCTAssertEqual(Device(name: "R", kind: .ssh(target: "u@h")).subtitle, "u@h · SSH")
        XCTAssertEqual(
            Device(name: "R", kind: .ssh(target: "u@h"), sessionName: "work").subtitle,
            "u@h · session work · SSH"
        )
    }
}
#endif
