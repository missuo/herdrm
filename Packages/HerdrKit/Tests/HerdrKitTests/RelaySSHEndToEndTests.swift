#if os(macOS)
import CryptoKit
import Darwin
import Foundation
import Testing
@testable import HerdrKit

/// The whole chain with a real sshd: a phone pairs through the deployed relay,
/// the Mac installs the phone's key, and the stock `ssh` client logs in through
/// the relay session and runs commands.
///
/// Needs a disposable sshd for the current user (never the system's):
/// HERDRM_RELAY_SSHD_PORT and HERDRM_RELAY_SSHD_AUTHKEYS (its AuthorizedKeysFile).
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["HERDRM_RELAY_SSHD_PORT"] != nil))
struct RelaySSHEndToEndTests {
    let env = ProcessInfo.processInfo.environment

    /// Accepts one TCP connection on 127.0.0.1 and pumps it into `stream`.
    static func bridge(_ stream: RelayStream) throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        listen(fd, 1)
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        Thread {
            let client = accept(fd, nil, nil)
            close(fd)
            guard client >= 0 else { return }
            Task { await RelayPump.run(descriptor: client, stream: stream) }
        }.start()
        return UInt16(bigEndian: bound.sin_port)
    }

    static func run(_ tool: String, _ args: [String]) throws -> (status: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    func ssh(port: UInt16, key: String, _ command: String) throws -> (status: Int32, out: String) {
        try Self.run("/usr/bin/ssh", [
            "-i", key, "-p", String(port), "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null", "-o", "LogLevel=ERROR",
            "\(NSUserName())@127.0.0.1", command,
        ])
    }

    @Test func sshLogsInThroughTheRelayWithTheKeyInstalledAtPairing() async throws {
        let port = try #require(env["HERDRM_RELAY_SSHD_PORT"].flatMap(UInt16.init))
        let authorizedKeys = URL(fileURLWithPath: try #require(env["HERDRM_RELAY_SSHD_AUTHKEYS"]))
        let before = try String(contentsOf: authorizedKeys, encoding: .utf8)
        defer { try? before.write(to: authorizedKeys, atomically: true, encoding: .utf8) }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let keyPath = dir.appendingPathComponent("phone_key").path
        #expect(try Self.run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", keyPath]).status == 0)
        let sshKey = try String(contentsOfFile: keyPath + ".pub", encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let store = RelayMemoryHostStore()
        let host = RelayHost(relay: RelayEndToEndTests.relay, store: store, hostName: "Test Mac",
                             authorizedKeys: authorizedKeys,
                             forward: { try RelayHost.connectLocalSSH(port: port) })
        await host.start()
        try await RelayEndToEndTests.waitOnline(host)
        defer { Task { await host.stop() } }
        let link = await host.beginPairing().link
        let phoneKey = Curve25519.KeyAgreement.PrivateKey()
        let hello = RelayMessage.Hello(name: "Test iPhone", sshKey: sshKey)

        // Before pairing the key is not there: ssh through a session fails.
        // (Pairing is what installs it.)
        let paired = try await RelayClient.connect(relay: link.relay, hostID: link.hostID, hostStatic: link.hostStatic,
                                                   psk: link.psk, phoneKey: phoneKey, hello: hello, pairing: true)
        let installed = try String(contentsOf: authorizedKeys, encoding: .utf8)
        #expect(installed.contains(#"from="127.0.0.1,::1" "#), "the key only works from the Mac's own end of the relay")
        #expect(installed.contains("herdrm-relay:"))

        let first = try ssh(port: try Self.bridge(paired.stream), key: keyPath, "printf relay-ok; uname -s")
        #expect(first.status == 0, "\(first.out)")
        #expect(first.out.contains("relay-ok"), "\(first.out)")
        #expect(first.out.contains("Darwin"), "\(first.out)")

        // A later session (stored key, no code) logs in again.
        let again = try await RelayClient.connect(relay: link.relay, hostID: link.hostID, hostStatic: link.hostStatic,
                                                  psk: link.psk, phoneKey: phoneKey, hello: hello)
        let big = try ssh(port: try Self.bridge(again.stream), key: keyPath, "head -c 3000000 /dev/zero | wc -c")
        #expect(big.status == 0, "\(big.out)")
        #expect(big.out.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("3000000"), "3 MB through the relay: \(big.out)")

        // Removing the phone takes its key away again.
        let phone = try #require(store.phones().first)
        await host.removePhone(phone.id)
        #expect(try !String(contentsOf: authorizedKeys, encoding: .utf8)
            .contains(RelayAuthorizedKeys.tag(phoneID: phone.id)))
    }
}
#endif

#if os(macOS)
/// Not a test: the Mac's side for driving the real iOS app in the Simulator.
/// Runs a RelayHost for HERDRM_RELAY_HARNESS_SECONDS, forwarding to the
/// disposable sshd, and writes a pairing link to HERDRM_RELAY_HARNESS_LINK.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["HERDRM_RELAY_HARNESS_SECONDS"] != nil))
struct RelayHostHarness {
    @Test func serveForTheSimulator() async throws {
        let env = ProcessInfo.processInfo.environment
        let seconds = try #require(env["HERDRM_RELAY_HARNESS_SECONDS"].flatMap(UInt64.init))
        let port = try #require(env["HERDRM_RELAY_SSHD_PORT"].flatMap(UInt16.init))
        let keys = URL(fileURLWithPath: try #require(env["HERDRM_RELAY_SSHD_AUTHKEYS"]))
        let linkFile = URL(fileURLWithPath: try #require(env["HERDRM_RELAY_HARNESS_LINK"]))
        // HERDRM_RELAY_HARNESS_DIRECT: the public address to report;
        // HERDRM_RELAY_HARNESS_SESSIONS: a file that gets a line per relayed session.
        let sessionLog = env["HERDRM_RELAY_HARNESS_SESSIONS"].map { URL(fileURLWithPath: $0) }
        let host = RelayHost(relay: RelayEndToEndTests.relay, store: RelayMemoryHostStore(),
                             hostName: "Harness Mac", authorizedKeys: keys,
                             directAddress: env["HERDRM_RELAY_HARNESS_DIRECT"],
                             // HERDRM_RELAY_HARNESS_HOSTKEY: the disposable sshd's .pub
                             sshHostKey: env["HERDRM_RELAY_HARNESS_HOSTKEY"].flatMap {
                                 try? String(contentsOfFile: $0, encoding: .utf8)
                                     .split(separator: " ").prefix(2).joined(separator: " ")
                             },
                             forward: {
                                 if let sessionLog, let h = try? FileHandle(forWritingTo: sessionLog) {
                                     h.seekToEndOfFile()
                                     h.write(Data("relayed\n".utf8))
                                     try? h.close()
                                 }
                                 return try RelayHost.connectLocalSSH(port: port)
                             })
        await host.start()
        try await RelayEndToEndTests.waitOnline(host)
        let pairing = await host.beginPairing()
        try pairing.link.url.absoluteString.write(to: linkFile, atomically: true, encoding: .utf8)
        try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
        await host.stop()
    }
}
#endif
