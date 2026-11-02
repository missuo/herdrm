#if os(macOS)
import CryptoKit
import Darwin
import Foundation
import Testing
@testable import HerdrKit

/// The Mac and the phone ends in Swift, through the deployed relay. The Mac
/// forwards to a local echo server instead of sshd, and writes no
/// authorized_keys, so nothing on this machine is touched.
///
/// Set HERDRM_RELAY_URL to test another relay; HERDRM_SKIP_RELAY_E2E=1 skips
/// (no network).
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["HERDRM_SKIP_RELAY_E2E"] == nil))
struct RelayEndToEndTests {
    static let relay = URL(string: ProcessInfo.processInfo.environment["HERDRM_RELAY_URL"] ?? "wss://herdrm-relay.owo.network")!

    /// A TCP echo server on 127.0.0.1; returns its port.
    static func echoServer() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        listen(fd, 8)
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        Thread {
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 { return }
                Thread {
                    var buffer = [UInt8](repeating: 0, count: 65536)
                    while true {
                        let n = read(client, &buffer, buffer.count)
                        if n <= 0 { break }
                        _ = RelayPump.writeAll(client, Data(buffer[0..<n]))
                    }
                    close(client)
                }.start()
            }
        }.start()
        return UInt16(bigEndian: bound.sin_port)
    }

    static func waitOnline(_ host: RelayHost) async throws {
        for _ in 0..<100 {
            if await host.status == .online { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        Issue.record("host never came online: \(await host.status)")
    }

    static let phoneSSHKey: String = {
        let key = Curve25519.Signing.PrivateKey()
        var blob = Data()
        func put(_ d: Data) {
            var n = UInt32(d.count).bigEndian
            blob.append(Data(bytes: &n, count: 4))
            blob.append(d)
        }
        put(Data("ssh-ed25519".utf8))
        put(key.publicKey.rawRepresentation)
        return "ssh-ed25519 " + blob.base64EncodedString()
    }()

    func makeHost(_ store: RelayMemoryHostStore, port: UInt16) -> RelayHost {
        RelayHost(relay: Self.relay, store: store, hostName: "Test Mac", userName: "tester",
                  authorizedKeys: nil, forward: { try RelayHost.connectLocalSSH(port: port) })
    }

    /// Round-trips `count` bytes through the session's echo.
    static func echo(_ stream: RelayStream, count: Int) async throws -> Bool {
        let payload = Data((0..<count).map { UInt8($0 % 251) })
        try await stream.write(payload)
        var received = Data()
        while received.count < payload.count { received += try await stream.read() }
        return received == payload
    }

    @Test func aPhonePairsByQRThenReconnectsWithItsStoredKey() async throws {
        let store = RelayMemoryHostStore()
        let host = makeHost(store, port: try Self.echoServer())
        await host.start()
        try await Self.waitOnline(host)
        defer { Task { await host.stop() } }

        let pairing = await host.beginPairing()
        let link = try #require(RelayPairingLink(url: pairing.link.url))
        #expect(link == pairing.link)

        let phoneKey = Curve25519.KeyAgreement.PrivateKey()
        let hello = RelayMessage.Hello(name: "Test iPhone", sshKey: Self.phoneSSHKey)
        let first = try await RelayClient.connect(relay: link.relay, hostID: link.hostID, hostStatic: link.hostStatic,
                                                  psk: link.psk, phoneKey: phoneKey, hello: hello, pairing: true)
        #expect(first.host.name == "Test Mac")
        #expect(first.host.user == "tester")
        #expect(try await Self.echo(first.stream, count: 100_000), "bytes reach the forwarded socket and come back")
        first.stream.close()

        let phones = store.phones()
        #expect(phones.count == 1)
        #expect(phones.first?.name == "Test iPhone")
        #expect(phones.first?.staticKey == phoneKey.publicKey.rawRepresentation)
        #expect(await host.cancelPairingIsConsumed())

        // The code is used up; the same phone gets in with the stored key.
        let again = try await RelayClient.connect(relay: link.relay, hostID: link.hostID, hostStatic: link.hostStatic,
                                                  psk: link.psk, phoneKey: phoneKey, hello: hello)
        #expect(try await Self.echo(again.stream, count: 5000))
        again.stream.close()

        // Another phone with the now-used code is turned away.
        await #expect(throws: (any Error).self) {
            _ = try await RelayClient.connect(relay: link.relay, hostID: link.hostID, hostStatic: link.hostStatic,
                                              psk: link.psk, phoneKey: .init(), hello: hello)
        }

        // Pairing the same phone again with a new code replaces its pairing:
        // the new secret works, and it is still one phone.
        let second = await host.beginPairing().link
        let repaired = try await RelayClient.connect(relay: second.relay, hostID: second.hostID, hostStatic: second.hostStatic,
                                                     psk: second.psk, phoneKey: phoneKey, hello: hello, pairing: true)
        repaired.stream.close()
        #expect(store.phones().count == 1)
        #expect(store.phones().first?.id == phones.first?.id)
        #expect(store.psk(forPhone: try #require(phones.first).id) == second.psk)
        let afterRepair = try await RelayClient.connect(relay: second.relay, hostID: second.hostID, hostStatic: second.hostStatic,
                                                        psk: second.psk, phoneKey: phoneKey, hello: hello)
        afterRepair.stream.close()

        // A removed phone is turned away too.
        await host.removePhone(try #require(phones.first).id)
        await #expect(throws: (any Error).self) {
            _ = try await RelayClient.connect(relay: second.relay, hostID: second.hostID, hostStatic: second.hostStatic,
                                              psk: second.psk, phoneKey: phoneKey, hello: hello)
        }
    }

    @Test func anExpiredCodeDoesNotPair() async throws {
        let store = RelayMemoryHostStore()
        let host = makeHost(store, port: try Self.echoServer())
        await host.start()
        try await Self.waitOnline(host)
        defer { Task { await host.stop() } }
        let link = await host.beginPairing().link
        await host.expirePairingForTesting()
        await #expect(throws: (any Error).self) {
            _ = try await RelayClient.connect(relay: link.relay, hostID: link.hostID, hostStatic: link.hostStatic,
                                              psk: link.psk, phoneKey: .init(),
                                              hello: .init(name: "late", sshKey: Self.phoneSSHKey), pairing: true)
        }
        #expect(store.phones().isEmpty)
    }

    @Test func aDirectAddressIsReportedAndOpensThePhonesKeyLine() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let keys = dir.appendingPathComponent(".ssh/authorized_keys")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RelayMemoryHostStore()
        let port = try Self.echoServer()
        func host(direct: String?) -> RelayHost {
            RelayHost(relay: Self.relay, store: store, hostName: "Test Mac", userName: "tester",
                      authorizedKeys: keys, directAddress: direct,
                      forward: { try RelayHost.connectLocalSSH(port: port) })
        }

        // Relay only: the key line is restricted to this Mac.
        let relayOnly = host(direct: nil)
        await relayOnly.start()
        try await Self.waitOnline(relayOnly)
        let link = await relayOnly.beginPairing().link
        let phoneKey = Curve25519.KeyAgreement.PrivateKey()
        let hello = RelayMessage.Hello(name: "Test iPhone", sshKey: Self.phoneSSHKey)
        let first = try await RelayClient.connect(relay: link.relay, hostID: link.hostID, hostStatic: link.hostStatic,
                                                  psk: link.psk, phoneKey: phoneKey, hello: hello, pairing: true)
        #expect(first.host.direct == nil)
        first.stream.close()
        #expect(try String(contentsOf: keys, encoding: .utf8).contains(#"from="127.0.0.1,::1" "#))
        await relayOnly.stop()

        // With a public address: it reaches the phone inside the session, and
        // the existing line is opened on start, since direct SSH comes from
        // anywhere.
        let direct = host(direct: "  203.0.113.7:2222 ")
        await direct.start()
        try await Self.waitOnline(direct)
        let second = try await RelayClient.connect(relay: link.relay, hostID: link.hostID, hostStatic: link.hostStatic,
                                                   psk: link.psk, phoneKey: phoneKey, hello: hello)
        #expect(second.host.direct == "203.0.113.7:2222")
        second.stream.close()
        var text = try String(contentsOf: keys, encoding: .utf8)
        #expect(!text.contains("from="))
        #expect(text.split(separator: "\n").count == 1, "still one line for the phone")
        await direct.stop()

        // Back to relay only: restricted again.
        let again = host(direct: "")
        await again.start()
        text = try String(contentsOf: keys, encoding: .utf8)
        #expect(text.contains(#"from="127.0.0.1,::1" "#))
        await again.stop()
    }

    @Test func aPhoneForAMacThatIsNotOnlineIsToldSo() async throws {
        let id = RelayProtocol.hostID(for: Curve25519.Signing.PrivateKey().publicKey)
        await #expect(throws: RelayError.hostOffline) {
            _ = try await RelayClient.connect(relay: Self.relay, hostID: id, hostStatic: Data(repeating: 9, count: 32),
                                              psk: Data(repeating: 1, count: 32), phoneKey: .init(),
                                              hello: .init(name: "x", sshKey: Self.phoneSSHKey))
        }
    }

    @Test func theHostIDMatchesTheRelay() throws {
        // protocol.HostID in herdrm-relay for ed25519.NewKeyFromSeed(0x06 × 32).
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 6, count: 32))
        #expect(key.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()
                == "8a875fff1eb38451577acd5afee405456568dd7c89e090863a0557bc7af49f17")
        #expect(RelayProtocol.hostID(for: key.publicKey) == "ojcwoicbea32nmzz7ccm43mrxm")
    }

    @Test func authorizedKeysLinesAreRestrictedTaggedAndRemovable() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = dir.appendingPathComponent(".ssh/authorized_keys")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "ssh-ed25519 AAAAexisting someone@laptop".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(RelayAuthorizedKeys.isValid(sshKey: Self.phoneSSHKey))
        #expect(!RelayAuthorizedKeys.isValid(sshKey: "ssh-rsa AAAA"))
        #expect(!RelayAuthorizedKeys.isValid(sshKey: #"ssh-ed25519 AAAA" command="rm -rf /""#))
        try RelayAuthorizedKeys.add(sshKey: Self.phoneSSHKey + " phone", phoneID: "p1", file: file)
        try RelayAuthorizedKeys.add(sshKey: Self.phoneSSHKey, phoneID: "p1", file: file) // no duplicate
        var lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines.first == "ssh-ed25519 AAAAexisting someone@laptop")
        #expect(lines.last == Substring(#"from="127.0.0.1,::1" "# + Self.phoneSSHKey + " herdrm-relay:p1"))
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)

        RelayAuthorizedKeys.remove(phoneID: "p1", file: file)
        lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        #expect(lines == ["ssh-ed25519 AAAAexisting someone@laptop"])
    }

    @Test func aPairingLinkRejectsGarbage() {
        #expect(RelayPairingLink(string: "https://example.com") == nil)
        #expect(RelayPairingLink(string: "herdrm://pair?v=1&relay=wss://r&id=short&k=AA&psk=AA&u=x") == nil)
        #expect(RelayPairingLink(string: "herdrm://pair?v=2") == nil)
    }
}

extension RelayHost {
    func expirePairingForTesting() { setPendingExpiryForTesting(Date().addingTimeInterval(-1)) }

    /// After a successful first pairing the code is consumed.
    func cancelPairingIsConsumed() -> Bool { isPairingPending == false }
}
#endif
