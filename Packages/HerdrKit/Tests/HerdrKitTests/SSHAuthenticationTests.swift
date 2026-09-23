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
    func testStandaloneTerminalCommandsMatchDeviceTransport() {
        let local = HerdrService(
            device: Device(name: "L", kind: .local),
            autoStartLocalServer: false
        ).terminalCommand()
        XCTAssertEqual(local.executable, "/bin/sh")
        XCTAssertTrue(local.args.last?.contains("exec \"${SHELL:-/bin/zsh}\" -l") == true)
        XCTAssertNil(local.authorizationID)

        let remote = HerdrService(
            device: Device(
                id: UUID(),
                name: "R",
                kind: .ssh(target: "user@example.test:2222")
            ),
            autoStartLocalServer: false
        ).terminalCommand()
        XCTAssertEqual(remote.executable, "/usr/bin/ssh")
        XCTAssertTrue(remote.args.contains("-tt"))
        XCTAssertTrue(remote.args.contains("StrictHostKeyChecking=accept-new"))
        XCTAssertTrue(remote.args.contains("ServerAliveInterval=15"))
        XCTAssertEqual(remote.args.last, "ssh://user@example.test:2222")
    }

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
        XCTAssertTrue(
            local.environment["PATH"]?.contains("/opt/homebrew/bin") == true,
            "local attach must use the same search PATH as lookup"
        )
        XCTAssertNil(local.environment["TERM"], "SwiftTerm owns TERM")

        let remote = HerdrService(device: Device(name: "R", kind: .ssh(target: "u@h")), localServer: nil)
            .attachCommand(paneID: "w1:p1", serverVersion: "0.8.2")
        XCTAssertEqual(remote.executable, "/usr/bin/ssh")
        // The whole script must run under sh on the far side, not the login shell.
        XCTAssertTrue(remote.args.last?.hasPrefix("exec /bin/sh -c '") == true)
        XCTAssertTrue(remote.args.last?.contains("export PATH=") == true)
        XCTAssertEqual(
            remote.environment["HOME"],
            ProcessInfo.processInfo.environment["HOME"],
            "remote attach must inherit the local environment used by OpenSSH"
        )
        XCTAssertTrue(
            remote.environment["PATH"]?.contains("/opt/homebrew/bin") == true,
            "remote attach must expose Match exec helpers installed by Homebrew"
        )
        if let agentSocket = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] {
            XCTAssertEqual(
                remote.environment["SSH_AUTH_SOCK"], agentSocket,
                "remote attach must preserve access to the caller's SSH agent"
            )
        }
    }

    func testOrdinaryTerminalAttachCommandsUseTerminalIDLocallyAndRemotely() {
        let local = HerdrService(device: Device(name: "L", kind: .local), localServer: nil)
            .attachCommand(target: .terminal(terminalID: "term_abc123"), serverVersion: "0.8.2")
        XCTAssertTrue(
            local.args.last?.contains("exec \"$hb\" terminal attach 'term_abc123' --takeover") == true
        )

        let remote = HerdrService(device: Device(name: "R", kind: .ssh(target: "u@h")), localServer: nil)
            .attachCommand(target: .terminal(terminalID: "term_abc123"), serverVersion: "0.8.2")
        XCTAssertEqual(remote.executable, "/usr/bin/ssh")
        XCTAssertTrue(remote.args.last?.contains("terminal attach") == true)
        XCTAssertTrue(remote.args.last?.contains("term_abc123") == true)
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
        printf '%s\\n' "$@" > \(HerdrService.shellQuoted(argumentsURL.path))
        cat > \(HerdrService.shellQuoted(capturedURL.path))
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

    func testDirectoryUploadStreamsTarOfTheFolder() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("herdrm-dir-upload-\(UUID().uuidString)", isDirectory: true)
        let folder = directory.appendingPathComponent("-my notes", isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("sub"),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("hello".utf8).write(to: folder.appendingPathComponent("a.txt"))
        try Data("deep".utf8).write(to: folder.appendingPathComponent("sub/b.txt"))

        let capturedURL = directory.appendingPathComponent("captured.tar")
        let argumentsURL = directory.appendingPathComponent("arguments.txt")
        let executableURL = directory.appendingPathComponent("fake-ssh")
        let script = """
        #!/bin/sh
        printf '%s\\n' "$@" > \(HerdrService.shellQuoted(argumentsURL.path))
        cat > \(HerdrService.shellQuoted(capturedURL.path))
        printf '/home/test/.cache/herdrm/attachments/abc/-my notes\\n'
        """
        try script.write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executableURL.path)

        let remotePath = try await SSHTunnel.uploadDirectory(
            target: "test@example.invalid",
            localURL: folder,
            remoteDirectoryName: "abc",
            credentialID: nil,
            executableURL: executableURL
        )

        XCTAssertEqual(remotePath, "/home/test/.cache/herdrm/attachments/abc/-my notes")
        let arguments = try String(contentsOf: argumentsURL, encoding: .utf8)
        XCTAssertTrue(arguments.contains("tar -xmf -"))
        XCTAssertTrue(arguments.contains("umask 077"))

        let list = Process()
        list.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        list.arguments = ["-tf", capturedURL.path]
        let output = Pipe()
        list.standardOutput = output
        try list.run()
        list.waitUntilExit()
        let entries = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n").map(String.init)
        XCTAssertTrue(entries.contains("./-my notes/a.txt"), "\(entries)")
        XCTAssertTrue(entries.contains("./-my notes/sub/b.txt"), "\(entries)")
        XCTAssertFalse(entries.contains { $0.contains("/._") }, "\(entries)")
    }

    func testDirectoryUploadValidation() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("herdrm-dir-guard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("small.bin")
        try Data([0x01, 0x02]).write(to: fileURL)

        XCTAssertEqual(try SSHTunnel.validateDirectoryUploadCandidate(directory), 2)
        XCTAssertThrowsError(try SSHTunnel.validateDirectoryUploadCandidate(fileURL))
        let broken = directory.appendingPathComponent("line\nbreak", isDirectory: true)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        XCTAssertThrowsError(try SSHTunnel.validateDirectoryUploadCandidate(broken))
    }

    func testUploadFilenamePreservesOnlySafeExtension() {
        let png = SSHTunnel.uploadFilename(for: URL(fileURLWithPath: "/tmp/private design.PNG"))
        XCTAssertTrue(png.hasSuffix(".png"))
        XCTAssertFalse(png.contains("private"))
        XCTAssertTrue(SSHTunnel.isSafeRemoteFilename(png))

        let unsafe = SSHTunnel.uploadFilename(for: URL(fileURLWithPath: "/tmp/file.bad$ext"))
        XCTAssertFalse(unsafe.contains("bad$ext"))
        XCTAssertTrue(SSHTunnel.isSafeRemoteFilename(unsafe))
    }

    func testUploadRejectsUnsafeRemoteFilename() async {
        for name in ["a\"; rm -rf ~; echo \".png", "../escape.png", ".hidden.png", "sp ace.png", ""] {
            XCTAssertFalse(SSHTunnel.isSafeRemoteFilename(name), name)
        }
        do {
            _ = try await SSHTunnel.uploadFile(
                target: "test@example.invalid",
                localURL: URL(fileURLWithPath: "/dev/null"),
                remoteFilename: "$(id).png",
                credentialID: nil
            )
            XCTFail("expected an unsafe filename to be rejected")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("unsafe remote filename"))
        }
    }

    func testUploadTimeoutScalesWithFileSize() {
        XCTAssertEqual(SSHTunnel.uploadTimeout(fileSizeBytes: 0), 30)
        // A 50 MB paste must not be killed by a fixed one-minute watchdog.
        XCTAssertGreaterThan(SSHTunnel.uploadTimeout(fileSizeBytes: SSHTunnel.maximumUploadBytes), 180)
        XCTAssertLessThanOrEqual(SSHTunnel.uploadTimeout(fileSizeBytes: Int.max / 2), 600)
    }

    func testUploadRejectsOversizedAndIrregularFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("herdrm-upload-guard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertThrowsError(try SSHTunnel.validateUploadCandidate(directory))
        XCTAssertThrowsError(try SSHTunnel.validateUploadCandidate(URL(string: "https://example.com/a.png")!))

        let fileURL = directory.appendingPathComponent("small.bin")
        try Data([0x01]).write(to: fileURL)
        XCTAssertEqual(try SSHTunnel.validateUploadCandidate(fileURL), 1)
    }

}

final class AgentAttachmentDeliveryPolicyTests: XCTestCase {
    private let pathCapabilities = AgentAttachmentCapabilities(
        nativeClipboardImageData: true,
        imagePath: .shellQuoted,
        filePath: .shellQuoted
    )

    func testManifestDecodingAndAliasRegistry() throws {
        let data = Data(
            """
            [
              {
                "agent": "codex",
                "aliases": ["openai-codex", "codex_cli"],
                "capabilities": {
                  "attachments": {
                    "native_clipboard_image_data": true,
                                        "image_path": "shell_quoted",
                                        "file_path": "shell_quoted"
                  }
                },
                "source": "bundled"
              },
              { "agent": "legacy" }
            ]
            """.utf8
        )
        let manifests = try JSONDecoder().decode([AgentManifestInfo].self, from: data)
        let registry = AgentAttachmentCapabilityRegistry(manifests: manifests)

        XCTAssertEqual(registry.capabilities(for: "codex"), pathCapabilities)
        XCTAssertEqual(registry.capabilities(for: "OPENAI-CODEX"), pathCapabilities)
        XCTAssertEqual(registry.capabilities(for: "codex_cli"), pathCapabilities)
        XCTAssertNil(registry.capabilities(for: "legacy"))
        XCTAssertNil(registry.capabilities(for: nil))
    }

    func testLegacyServerFallbackOnlyAppliesWhenNoManifestAdvertisesCapabilities() throws {
        let legacyData = Data(
            """
            [
              { "agent": "claude" },
              { "agent": "codex" },
              { "agent": "copilot" }
            ]
            """.utf8
        )
        let legacyRegistry = AgentAttachmentCapabilityRegistry(
            manifests: try JSONDecoder().decode([AgentManifestInfo].self, from: legacyData)
        )
        XCTAssertEqual(legacyRegistry.capabilities(for: "claude_code"), pathCapabilities)
        XCTAssertEqual(
            legacyRegistry.capabilities(for: "OPENAI-CODEX"),
            pathCapabilities
        )
        XCTAssertEqual(legacyRegistry.capabilities(for: "github-copilot"), pathCapabilities)

        let capabilityAwareData = Data(
            """
            [
              {
                "agent": "codex",
                "capabilities": {
                  "attachments": {
                    "native_clipboard_image_data": true,
                    "image_path": "future_syntax"
                  }
                }
              },
              { "agent": "claude" }
            ]
            """.utf8
        )
        let capabilityAwareRegistry = AgentAttachmentCapabilityRegistry(
            manifests: try JSONDecoder().decode(
                [AgentManifestInfo].self,
                from: capabilityAwareData
            )
        )
        XCTAssertEqual(
            capabilityAwareRegistry.capabilities(for: "codex"),
            AgentAttachmentCapabilities(nativeClipboardImageData: true)
        )
        XCTAssertNil(capabilityAwareRegistry.capabilities(for: "claude"))
    }

    /// herdr 0.8.2's `server.agent_manifests` reports only an id and version —
    /// no aliases, no capabilities — so the built-in table has to recognize the
    /// bare manifest ids. Kinds outside it must stay nil and paste as plain text.
    func testBuiltInFallbackCoversVerifiedAgentKinds() throws {
        let data = Data(
            """
            [
              { "agent": "claude", "active_version": "2026.08.21.1" },
              { "agent": "codex", "active_version": "2026.08.09.1" },
              { "agent": "copilot", "active_version": "2026.07.07.1" },
              { "agent": "cursor", "active_version": "2026.08.03.1" },
              { "agent": "gemini", "active_version": "2026.06.10.1" },
              { "agent": "grok", "active_version": "2026.07.16.2" },
              { "agent": "opencode", "active_version": "2026.06.10.1" },
              { "agent": "pi", "active_version": "2026.06.10.1" },
              { "agent": "kimi", "active_version": "2026.06.10.1" }
            ]
            """.utf8
        )
        let registry = AgentAttachmentCapabilityRegistry(
            manifests: try JSONDecoder().decode([AgentManifestInfo].self, from: data)
        )

        for kind in ["claude", "codex", "copilot", "cursor", "gemini", "grok", "opencode", "pi"] {
            XCTAssertEqual(
                registry.capabilities(for: kind),
                pathCapabilities,
                "\(kind) should support pasted attachments"
            )
        }

        // herdr's own manifest aliases, in case detection ever reports one.
        XCTAssertEqual(registry.capabilities(for: "cursor-agent"), pathCapabilities)
        XCTAssertEqual(registry.capabilities(for: "grok-build"), pathCapabilities)
        XCTAssertEqual(registry.capabilities(for: "open-code"), pathCapabilities)

        // Advertised by herdr but unverified here: no capabilities, plain paste.
        XCTAssertNil(registry.capabilities(for: "kimi"))
        XCTAssertNil(registry.capabilities(for: "devin"))
    }

    func testVerifiedAgentsDeliverImagesLocallyAndRemotely() throws {
        let data = Data(
            """
            [
              { "agent": "cursor" },
              { "agent": "gemini" },
              { "agent": "grok" },
              { "agent": "opencode" },
              { "agent": "pi" }
            ]
            """.utf8
        )
        let registry = AgentAttachmentCapabilityRegistry(
            manifests: try JSONDecoder().decode([AgentManifestInfo].self, from: data)
        )
        let remote = Device.Kind.ssh(target: "user@example.test")

        for kind in ["cursor", "gemini", "grok", "opencode", "pi"] {
            let capabilities = registry.capabilities(for: kind)
            // Local: the agent shells out to osascript and reads the clipboard.
            XCTAssertEqual(
                AgentAttachmentDeliveryPolicy.action(
                    capabilities: capabilities,
                    deviceKind: .local,
                    source: .imageData
                ),
                .nativeClipboard,
                "\(kind) should read the local clipboard"
            )
            // Remote: the Mac clipboard is unreachable, so stage and paste paths.
            XCTAssertEqual(
                AgentAttachmentDeliveryPolicy.action(
                    capabilities: capabilities,
                    deviceKind: remote,
                    source: .imageData
                ),
                .devicePaths(.shellQuoted),
                "\(kind) should paste a staged remote path"
            )
            XCTAssertEqual(
                AgentAttachmentDeliveryPolicy.action(
                    capabilities: capabilities,
                    deviceKind: .local,
                    source: .files(allImages: false)
                ),
                .devicePaths(.shellQuoted),
                "\(kind) should paste a local path for generic files"
            )
        }
    }

    func testLocalDeliveryUsesNativeClipboardForImages() {
        XCTAssertEqual(
            AgentAttachmentDeliveryPolicy.action(
                capabilities: pathCapabilities,
                deviceKind: .local,
                source: .imageData
            ),
            .nativeClipboard
        )
        // Copied image files are images too: local agents that read clipboard
        // images natively get the paste shortcut, not a quoted path.
        XCTAssertEqual(
            AgentAttachmentDeliveryPolicy.action(
                capabilities: pathCapabilities,
                deviceKind: .local,
                source: .files(allImages: true)
            ),
            .nativeClipboard
        )
        XCTAssertEqual(
            AgentAttachmentDeliveryPolicy.action(
                capabilities: pathCapabilities,
                deviceKind: .local,
                source: .files(allImages: false)
            ),
            .devicePaths(.shellQuoted)
        )
    }

    func testRemoteDeliveryUsesDevicePathsForSupportedAgents() {
        let remote = Device.Kind.ssh(target: "user@example.test")
        XCTAssertEqual(
            AgentAttachmentDeliveryPolicy.action(
                capabilities: pathCapabilities,
                deviceKind: remote,
                source: .imageData
            ),
            .devicePaths(.shellQuoted)
        )
        XCTAssertEqual(
            AgentAttachmentDeliveryPolicy.action(
                capabilities: pathCapabilities,
                deviceKind: remote,
                source: .files(allImages: true)
            ),
            .devicePaths(.shellQuoted)
        )
        XCTAssertEqual(
            AgentAttachmentDeliveryPolicy.action(
                capabilities: pathCapabilities,
                deviceKind: remote,
                source: .files(allImages: false)
            ),
            .devicePaths(.shellQuoted)
        )
    }

    func testMissingCapabilitiesRemainUnsupported() {
        XCTAssertEqual(
            AgentAttachmentDeliveryPolicy.action(
                capabilities: nil,
                deviceKind: .ssh(target: "user@example.test"),
                source: .imageData
            ),
            .unsupported
        )
    }

    func testShellQuotedPathSyntaxEscapesApostrophes() {
        XCTAssertEqual(
            AgentAttachmentPathSyntax.shellQuoted.format("/tmp/it's here/image.png"),
            "'/tmp/it'\\''s here/image.png'"
        )
    }
}
