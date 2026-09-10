import Foundation
import HerdrTailcat

/// Owns the embedded tailcat bridges, one per tailcat device.
///
/// A thin HerdrKit-side coordinator over `HerdrTailcat.TailcatBridge`: it maps a
/// device to its deterministic local socket path and reads the connection token
/// from the Keychain, then hands both to the in-process WireGuard/DERP bridge.
/// The bridge serves the remote herdr on that socket, so `SocketRPC`, the event
/// stream, and terminal attach reach it exactly as the SSH forward lets them —
/// but with no external `tailcat` CLI, and on iOS too.
///
/// A process-wide manager is required because terminal attach builds its command
/// from a fresh `HerdrService` (see `AttachTerminalView`) and cannot reach the
/// session's service; the deterministic socket path lets it name the socket
/// without any shared state.
public actor TailcatBridgeManager {
    public static let shared = TailcatBridgeManager()

    private init() {}

    /// The local socket path for a device's bridge. Pure and deterministic
    /// within the process so a synchronous terminal-attach command can name it
    /// without awaiting the manager.
    public nonisolated static func localSocketPath(deviceID: UUID) -> String {
        TailcatBridge.localSocketPath(deviceID: deviceID)
    }

    /// Ensures the bridge for a device is running and returns its local socket
    /// path. Idempotent: a live bridge is reused as-is. The token is read from
    /// the Keychain and handed straight to the Go runtime, so it never touches
    /// a process list or environment block.
    public func ensureUp(deviceID: UUID) async throws -> String {
        let stored = (try? TailcatCredentialStore.token(for: deviceID)) ?? nil
        guard let token = stored, !token.isEmpty else {
            throw HerdrError.tailcatTokenMissing
        }
        do {
            return try await TailcatBridge.shared.ensureUp(deviceID: deviceID, token: token)
        } catch let error as TailcatBridgeError {
            throw HerdrError.tailcatBridgeFailed(error.localizedDescription)
        }
    }

    /// The most recent asynchronous bridge error for a device (bad token,
    /// unreachable server), if any — used to explain a connect failure after
    /// the fact.
    public func recentError(deviceID: UUID) async -> String? {
        await TailcatBridge.shared.recentError(deviceID: deviceID)
    }

    public func tearDown(deviceID: UUID) async {
        await TailcatBridge.shared.tearDown(deviceID: deviceID)
    }

    public func tearDownAll() async {
        await TailcatBridge.shared.tearDownAll()
    }
}
