import XCTest

@testable import HerdrKit

final class TailcatBridgeTests: XCTestCase {
    func testLocalSocketPathIsDeterministicAndShort() {
        let id = UUID()
        let first = TailcatBridgeManager.localSocketPath(deviceID: id)
        let second = TailcatBridgeManager.localSocketPath(deviceID: id)
        XCTAssertEqual(first, second, "attach must resolve the same socket the bridge binds")
        // sockaddr_un caps at 104 bytes.
        XCTAssertLessThan(first.utf8.count, 104)
        XCTAssertNotEqual(first, TailcatBridgeManager.localSocketPath(deviceID: UUID()))
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

    /// Full embedded-bridge E2E: bring the in-process tailcat bridge up with a
    /// real token and ping the remote herdr over its local socket, proving the
    /// WireGuard/DERP path end to end with no external `tailcat` CLI. Needs a
    /// live token: HERDRM_E2E_TAILCAT_TOKEN=$(herdr plugin action … token).
    func testEmbeddedBridgeRoundtripsAPing() async throws {
        guard let token = ProcessInfo.processInfo.environment["HERDRM_E2E_TAILCAT_TOKEN"],
              !token.isEmpty
        else {
            throw XCTSkip("set HERDRM_E2E_TAILCAT_TOKEN to run the live embedded-tailcat E2E")
        }
        let id = UUID()
        defer {
            TailcatCredentialStore.removeToken(for: id)
            Task { await TailcatBridgeManager.shared.tearDown(deviceID: id) }
        }
        try TailcatCredentialStore.setToken(token, for: id)

        let socketPath = try await TailcatBridgeManager.shared.ensureUp(deviceID: id)
        let rpc = SocketRPC(socketPath: socketPath)
        let pong = try await rpc.request(method: "ping", params: .object([:]), as: PingResult.self)
        XCTAssertGreaterThanOrEqual(pong.protocolVersion, 17)
    }

    /// A tailcat device with no saved token fails fast with the dedicated
    /// error, before the embedded bridge is ever asked to start.
    func testEnsureUpWithoutATokenThrowsTokenMissing() async {
        let id = UUID()
        TailcatCredentialStore.removeToken(for: id)
        do {
            _ = try await TailcatBridgeManager.shared.ensureUp(deviceID: id)
            XCTFail("expected tailcatTokenMissing")
        } catch let error as HerdrError {
            guard case .tailcatTokenMissing = error else {
                return XCTFail("expected tailcatTokenMissing, got \(error)")
            }
        } catch {
            XCTFail("expected HerdrError.tailcatTokenMissing, got \(error)")
        }
    }
}
