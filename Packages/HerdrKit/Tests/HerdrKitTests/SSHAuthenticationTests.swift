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