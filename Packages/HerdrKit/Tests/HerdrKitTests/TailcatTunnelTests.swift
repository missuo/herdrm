import XCTest

@testable import HerdrKit

final class TailcatTunnelTests: XCTestCase {
    func testBridgeSocketPathIsDeterministicAndShort() {
        let id = UUID()
        let first = TailcatTunnel.bridgeSocketPath(credentialID: id)
        let second = TailcatTunnel.bridgeSocketPath(credentialID: id)
        XCTAssertEqual(first, second, "attachCommand must resolve the same path as ensureUp")
        // sockaddr_un caps at 104 bytes.
        XCTAssertLessThan(first.utf8.count, 104)
        XCTAssertNotEqual(first, TailcatTunnel.bridgeSocketPath(credentialID: UUID()))
    }

    func testTokenRoundtripsThroughTheKeychain() throws {
        let id = UUID()
        defer { TailcatCredentialStore.removeToken(for: id) }

        XCTAssertNil(try TailcatCredentialStore.token(for: id))
        try TailcatCredentialStore.setToken("tcp-test-token", for: id)
        XCTAssertEqual(try TailcatCredentialStore.token(for: id), "tcp-test-token")
        try TailcatCredentialStore.setToken("tcp-rotated", for: id)
        XCTAssertEqual(try TailcatCredentialStore.token(for: id), "tcp-rotated")
        TailcatCredentialStore.removeToken(for: id)
        XCTAssertNil(try TailcatCredentialStore.token(for: id))
    }

    /// Full-path E2E: a live tailcat tunnel to a herdr exposed by the
    /// herdr.tailcat plugin. Ping rides bridge socket → tailcat child →
    /// WireGuard/DERP → plugin daemon → herdr.sock and back. Needs a real
    /// token: HERDRM_E2E_TAILCAT_TOKEN=$(herdr plugin action … token).
    func testLiveTunnelRoundtripsAPing() async throws {
        guard let token = ProcessInfo.processInfo.environment["HERDRM_E2E_TAILCAT_TOKEN"],
              !token.isEmpty
        else {
            throw XCTSkip("set HERDRM_E2E_TAILCAT_TOKEN to run the live tailcat E2E")
        }
        guard TailcatTunnel.findTailcatBinary() != nil else {
            throw XCTSkip("tailcat binary not installed")
        }

        let id = UUID()
        defer { TailcatCredentialStore.removeToken(for: id) }
        try TailcatCredentialStore.setToken(token, for: id)

        let tunnel = TailcatTunnel(credentialID: id)
        defer { Task { await tunnel.tearDown() } }
        let socketPath = try await tunnel.ensureUp()

        let rpc = SocketRPC(socketPath: socketPath)
        let pong = try await rpc.request(method: "ping", params: .object([:]), as: PingResult.self)
        XCTAssertGreaterThanOrEqual(pong.protocolVersion, 17)

        // herdr is one-request-per-connection; a second request must get its
        // own tailcat session through the same bridge.
        let second = try await rpc.request(method: "ping", params: .object([:]), as: PingResult.self)
        XCTAssertEqual(second.version, pong.version)
    }
}
