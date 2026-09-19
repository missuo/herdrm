import XCTest
@testable import HerdrKit

final class WindowsSSHProbeTests: XCTestCase {
    func testUnixHomeRequiresAbsolutePath() {
        XCTAssertTrue(SSHTunnel.isUnixHome("/home/david"))
        XCTAssertTrue(SSHTunnel.isUnixHome("/Users/david"))
        XCTAssertFalse(SSHTunnel.isUnixHome("$HOME"))
        XCTAssertFalse(SSHTunnel.isUnixHome("\"$HOME\""))
        XCTAssertFalse(SSHTunnel.isUnixHome(#"C:\Users\david"#))
    }

    func testWindowsHomeAcceptsDriveLetterPaths() {
        XCTAssertTrue(SSHTunnel.isWindowsHome(#"C:\Users\david"#))
        XCTAssertTrue(SSHTunnel.isWindowsHome("C:/Users/david"))
        XCTAssertTrue(SSHTunnel.isWindowsHome(#"d:\Users\david"#))
        XCTAssertFalse(SSHTunnel.isWindowsHome("/home/david"))
        XCTAssertFalse(SSHTunnel.isWindowsHome("Users\\david"))
        XCTAssertFalse(SSHTunnel.isWindowsHome("C:"))
    }

    func testParseWindowsEnvironmentProbe() {
        let home = Data(#"C:\Users\david"#.utf8).base64EncodedString()
        let exe = Data(#"C:\Users\david\.herdr\packages\standalone\current\herdr.exe"#.utf8)
            .base64EncodedString()
        let output = """
        herdr-windows-home:1:\(home)
        herdr-windows-herdr:1:\(exe)
        """
        let parsed = SSHTunnel.parseWindowsEnvironmentProbe(output)
        XCTAssertEqual(parsed?.home, #"C:\Users\david"#)
        XCTAssertEqual(
            parsed?.herdrExecutable,
            #"C:\Users\david\.herdr\packages\standalone\current\herdr.exe"#
        )
    }

    func testParseWindowsEnvironmentProbeRejectsIncompleteOutput() {
        XCTAssertNil(SSHTunnel.parseWindowsEnvironmentProbe("herdr-windows-home:1:QzpcdG1w"))
        XCTAssertNil(SSHTunnel.parseWindowsEnvironmentProbe("not-a-probe"))
    }

    func testRemoteAPIBridgeCommandUsesPowerShellEncodedCommand() {
        let command = SSHRemoteAPIBridge.remoteCommand(
            herdrExecutable: #"C:\Users\david\.herdr\herdr.exe"#
        )
        XCTAssertTrue(command.hasPrefix("powershell.exe -NoLogo -NoProfile -NonInteractive -EncodedCommand "))
        let encoded = String(command.split(separator: " ").last!)
        let data = try! XCTUnwrap(Data(base64Encoded: encoded))
        let script = String(data: data, encoding: .utf16LittleEndian)
            ?? String(bytes: data, encoding: .utf16LittleEndian)
        // EncodedCommand is UTF-16LE; reconstruct via utf16 pairs if needed.
        let decoded: String = {
            if let direct = String(data: data, encoding: .utf16LittleEndian) { return direct }
            var scalars: [UInt16] = []
            let bytes = [UInt8](data)
            var i = 0
            while i + 1 < bytes.count {
                scalars.append(UInt16(bytes[i]) | (UInt16(bytes[i + 1]) << 8))
                i += 2
            }
            return String(decoding: scalars, as: UTF16.self)
        }()
        XCTAssertEqual(decoded, #"& 'C:\Users\david\.herdr\herdr.exe' --session default remote-api-bridge"#)
        _ = script
    }

    func testLocalSocketPathIsStableForTarget() {
        let a = SSHTunnel.localSocketPath(for: "z7m")
        let b = SSHTunnel.localSocketPath(for: "z7m")
        XCTAssertEqual(a, b)
        XCTAssertTrue(a.hasSuffix(".sock"))
    }
}
