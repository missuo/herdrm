import Foundation
import Tailcat

/// Errors thrown by the embedded tailcat bridge.
public enum TailcatBridgeError: Error, Sendable {
    /// The Go runtime refused to start the bridge (bad socket path, etc.).
    case startFailed(String)
}

extension TailcatBridgeError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .startFailed(let reason): return reason
        }
    }
}

/// In-process tailcat bridge, embedded as an xcframework (gomobile).
///
/// One bridge per device holds a single tailcat (WireGuard/DERP) session to
/// the host's herdr.tailcat plugin and serves it on a local Unix socket, so
/// `SocketRPC`, the event stream, and (on macOS) terminal attach reach the
/// remote herdr exactly as the SSH forward lets them — by talking to a local
/// socket path. Unlike the earlier helper-binary transport this runs inside
/// the app process, so it works on iOS too and needs nothing installed on
/// `PATH`.
///
/// The gomobile entry points (`TailcatmobileStartBridge` and friends) are
/// process-global and thread-safe; this actor namespaces them per socket path
/// and owns cleanup. It is deliberately free of HerdrKit types so HerdrKit can
/// depend on it: the caller supplies the token (read from the Keychain) and
/// the socket path.
public actor TailcatBridge {
    public static let shared = TailcatBridge()

    /// The socket paths with a live bridge, so a disconnect tears theirs down.
    private var active: Set<String> = []

    private init() {}

    /// The local socket path for a device's bridge. Pure and deterministic
    /// within the process so a synchronous terminal-attach command can name it
    /// without awaiting the bridge. Kept short: sockaddr_un caps at 104 bytes.
    public nonisolated static func localSocketPath(deviceID: UUID) -> String {
        let hex = deviceID.uuidString.replacingOccurrences(of: "-", with: "")
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("herdrm-tailcat", isDirectory: true)
        return dir.appendingPathComponent("\(hex.prefix(16)).sock").path
    }

    /// Ensures the bridge for a device is up and returns its local socket path.
    /// Idempotent: a live bridge is reused as-is. The token is handed to the Go
    /// runtime directly — it never touches a process list or environment block.
    public func ensureUp(deviceID: UUID, token: String) throws -> String {
        let socketPath = Self.localSocketPath(deviceID: deviceID)
        if active.contains(socketPath) { return socketPath }

        var nsError: NSError?
        guard TailcatmobileStartBridge(token, socketPath, &nsError) else {
            throw TailcatBridgeError.startFailed(
                nsError?.localizedDescription ?? "the embedded tailcat bridge failed to start"
            )
        }
        active.insert(socketPath)
        return socketPath
    }

    /// The most recent asynchronous bridge error for a device (a failed warm-up
    /// handshake, a refused tunnel dial), if any — used to explain a connect
    /// failure after the fact.
    public func recentError(deviceID: UUID) -> String? {
        let text = TailcatmobileBridgeError(Self.localSocketPath(deviceID: deviceID))
        return text.isEmpty ? nil : text
    }

    public func tearDown(deviceID: UUID) {
        let socketPath = Self.localSocketPath(deviceID: deviceID)
        guard active.remove(socketPath) != nil else { return }
        TailcatmobileStopBridge(socketPath)
    }

    public func tearDownAll() {
        for socketPath in active { TailcatmobileStopBridge(socketPath) }
        active.removeAll()
    }
}
