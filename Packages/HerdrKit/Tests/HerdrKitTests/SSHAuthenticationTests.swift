import XCTest
import Security
@testable import HerdrKit

final class SSHAuthenticationTests: XCTestCase {
    func testForwardingFailureExtractsTheLastOpenSSHChannelError() {
        let stderr = """
        Warning: Permanently added 'remote' to the list of known hosts.
        channel 1: open failed: unknown channel type: unsupported channel type
        channel 2: open failed: connect failed: dial unix /tmp/herdr.sock: connect: connection refused
        """

        XCTAssertEqual(
            SSHTunnel.forwardingFailure(in: stderr),
            "channel 2: open failed: connect failed: dial unix /tmp/herdr.sock: connect: connection refused"
        )
    }

    func testForwardingFailureIgnoresUnrelatedSSHWarnings() {
        XCTAssertNil(SSHTunnel.forwardingFailure(in: "Warning: remote host identification changed"))
    }

    func testKeychainCredentialConfiguresAskPassAuthentication() throws {
        let deviceID = UUID()
        defer { try? SSHCredentialStore.removePassword(for: deviceID) }

        XCTAssertNil(try SSHCredentialStore.password(for: deviceID))
        try SSHCredentialStore.setPassword("test-password", for: deviceID)
        XCTAssertEqual(try SSHCredentialStore.password(for: deviceID), "test-password")

        let authentication = SSHTunnel.authenticationConfiguration(for: deviceID)
        XCTAssertEqual(
            authentication.arguments,
            ["-o", "BatchMode=no", "-o", "NumberOfPasswordPrompts=1"]
        )
        XCTAssertEqual(
            authentication.environment[SSHCredentialStore.askPassModeEnvironmentKey],
            "1"
        )
        let rawAuthorizationID = try XCTUnwrap(
            authentication.environment[SSHCredentialStore.authorizationIDEnvironmentKey]
        )
        let authorizationID = try XCTUnwrap(UUID(uuidString: rawAuthorizationID))
        XCTAssertEqual(
            try SSHCredentialStore.consumePassword(authorizationID: authorizationID),
            "test-password"
        )
        XCTAssertNil(try SSHCredentialStore.consumePassword(authorizationID: authorizationID))
        XCTAssertFalse(authentication.environment["SSH_ASKPASS", default: ""].isEmpty)

        try SSHCredentialStore.removePassword(for: deviceID)
        XCTAssertNil(try SSHCredentialStore.password(for: deviceID))
    }

    func testLegacyLocalCredentialMigratesToKeychain() throws {
        let deviceID = UUID()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "dev.bybee.herdrm.ssh-password",
            kSecAttrAccount as String: deviceID.uuidString,
        ]
        defer {
            try? SSHCredentialStore.removePassword(for: deviceID)
            SecItemDelete(query as CFDictionary)
        }

        let applicationSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let passwordDirectory = applicationSupport
            .appendingPathComponent("HerdrM/SSHCredentials/passwords", isDirectory: true)
        let passwordFile = passwordDirectory.appendingPathComponent(deviceID.uuidString)
        try FileManager.default.createDirectory(
            at: passwordDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Data("legacy-password".utf8).write(to: passwordFile)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: passwordFile.path
        )

        XCTAssertEqual(try SSHCredentialStore.password(for: deviceID), "legacy-password")
        XCTAssertFalse(FileManager.default.fileExists(atPath: passwordFile.path))
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, nil), errSecSuccess)
    }
}
final class SSHDestinationTests: XCTestCase {
    func testCustomPortTargetsBecomeSSHURIs() {
        XCTAssertEqual(SSHTunnel.sshDestination("vincent@10.10.10.87:2222"), "ssh://vincent@10.10.10.87:2222")
        XCTAssertEqual(SSHTunnel.sshDestination("host.example.com:23"), "ssh://host.example.com:23")
        XCTAssertEqual(SSHTunnel.sshDestination("vincent@[fe80::1]:2222"), "ssh://vincent@[fe80::1]:2222")
    }

    func testPlainTargetsPassThroughUntouched() {
        XCTAssertEqual(SSHTunnel.sshDestination("vincent@10.10.10.87"), "vincent@10.10.10.87")
        XCTAssertEqual(SSHTunnel.sshDestination("my-config-alias"), "my-config-alias")
        XCTAssertEqual(SSHTunnel.sshDestination("ssh://vincent@host:2222"), "ssh://vincent@host:2222")
        // A bare IPv6 address's colons are not a port.
        XCTAssertEqual(SSHTunnel.sshDestination("fe80::1"), "fe80::1")
        XCTAssertEqual(SSHTunnel.sshDestination("vincent@fe80::1"), "vincent@fe80::1")
        // Malformed ports pass through for ssh to reject with its own error.
        XCTAssertEqual(SSHTunnel.sshDestination("host:99999"), "host:99999")
        XCTAssertEqual(SSHTunnel.sshDestination("host:"), "host:")
    }
}

final class AttachBinarySelectionTests: XCTestCase {
    func testKnownServerVersionProbesForAnExactMatch() {
        let fragment = HerdrService.attachBinarySelection(serverVersion: "0.8.2")
        XCTAssertTrue(fragment.contains("for d in $PATH"))
        XCTAssertTrue(fragment.contains("'0.8.2'"))
        XCTAssertTrue(fragment.contains("hb=herdr"), "first-found binary must stay the fallback")
    }

    func testUnknownOrUnsafeServerVersionFallsBackToPlainHerdr() {
        XCTAssertEqual(HerdrService.attachBinarySelection(serverVersion: nil), "hb=herdr")
        XCTAssertEqual(HerdrService.attachBinarySelection(serverVersion: ""), "hb=herdr")
        // Anything but digits and dots must not reach the shell.
        XCTAssertEqual(HerdrService.attachBinarySelection(serverVersion: "0.8'; rm -rf /"), "hb=herdr")
    }

    func testAttachCommandsRunTheSelectedBinaryThroughSh() {
        let local = HerdrService(device: Device(name: "L", kind: .local), localServer: nil)
            .attachCommand(paneID: "w1:p1", serverVersion: "0.8.2")
        XCTAssertEqual(local.executable, "/bin/sh")
        XCTAssertTrue(local.args.last?.contains("exec \"$hb\" agent attach 'w1:p1'") == true)

        let remote = HerdrService(device: Device(name: "R", kind: .ssh(target: "u@h")), localServer: nil)
            .attachCommand(paneID: "w1:p1", serverVersion: "0.8.2")
        XCTAssertEqual(remote.executable, "/usr/bin/ssh")
        // The whole script must run under sh on the far side, not the login shell.
        XCTAssertTrue(remote.args.last?.hasPrefix("exec /bin/sh -c '") == true)
    }
}

final class SSHFileTransferTests: XCTestCase {
    func testUploadStreamsFileAndReturnsRemotePath() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("herdrm-upload-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = directory.appendingPathComponent("source.png")
        let capturedURL = directory.appendingPathComponent("captured.bin")
        let argumentsURL = directory.appendingPathComponent("arguments.txt")
        let executableURL = directory.appendingPathComponent("fake-ssh")
        let payload = Data([0x00, 0x01, 0x0A, 0xFF, 0x42])
        try payload.write(to: sourceURL)

        let script = """
        #!/bin/sh
        printf '%s\\n' "$@" > \(shellQuote(argumentsURL.path))
        cat > \(shellQuote(capturedURL.path))
        printf '/home/test/.cache/herdrm/attachments/test.png\\n'
        """
        try script.write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executableURL.path)

        let remotePath = try await SSHTunnel.uploadFile(
            target: "test@example.invalid:2222",
            localURL: sourceURL,
            remoteFilename: "test.png",
            credentialID: nil,
            executableURL: executableURL
        )

        XCTAssertEqual(remotePath, "/home/test/.cache/herdrm/attachments/test.png")
        XCTAssertEqual(try Data(contentsOf: capturedURL), payload)
        let arguments = try String(contentsOf: argumentsURL, encoding: .utf8)
        XCTAssertTrue(arguments.contains("ssh://test@example.invalid:2222"))
        XCTAssertTrue(arguments.contains("umask 077"))
        XCTAssertTrue(arguments.contains("chmod 700"))
        XCTAssertTrue(arguments.contains("chmod 600"))
        XCTAssertTrue(arguments.contains("test.png.part"))
    }

    func testUploadFilenamePreservesOnlySafeExtension() {
        let png = SSHTunnel.uploadFilename(for: URL(fileURLWithPath: "/tmp/private design.PNG"))
        XCTAssertTrue(png.hasSuffix(".png"))
        XCTAssertFalse(png.contains("private"))

        let unsafe = SSHTunnel.uploadFilename(for: URL(fileURLWithPath: "/tmp/file.bad$ext"))
        XCTAssertFalse(unsafe.contains("bad$ext"))
    }

    private func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
