#if os(macOS)
import Foundation

/// Bridges a local Unix socket to a herdr socket exposed by the
/// `herdr.tailcat` server plugin (WireGuard + DERP via the `tailcat` CLI,
/// no accounts, no control plane).
///
/// The bridge is inetd-shaped: a local listener accepts each connection and
/// hands the accepted socket fd straight to a `tailcat <token> 6464` child as
/// its stdin/stdout, so tailcat itself moves every byte and this process never
/// pumps data. herdr is one-request-per-connection, which maps exactly onto
/// tailcat's one-session-per-process model — but each session pays a fresh
/// WireGuard/DERP handshake (~1–2 s), so a tailcat device feels slower than
/// SSH; the UI should set that expectation.
public actor TailcatTunnel {
    /// The virtual port the herdr.tailcat plugin serves inside the tunnel.
    public static let herdrPort = "6464"

    private let credentialID: UUID
    private var listenerFD: Int32 = -1
    private var localSocketPath: String?
    private var acceptTask: Task<Void, Never>?
    private var children: [Int32: Process] = [:]

    public init(credentialID: UUID) {
        self.credentialID = credentialID
    }

    /// Ensures the local bridge is listening and returns its socket path.
    public func ensureUp() async throws -> String {
        if let localSocketPath, listenerFD >= 0 {
            return localSocketPath
        }
        guard let binary = Self.findTailcatBinary() else {
            throw HerdrError.tunnelFailed(
                "tailcat not found — install it with \"brew install tailcat\""
            )
        }
        guard let token = try TailcatCredentialStore.token(for: credentialID),
              !token.isEmpty
        else {
            throw HerdrError.tunnelFailed("no tailcat token saved for this device")
        }

        let path = Self.bridgeSocketPath(credentialID: credentialID)
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(atPath: path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw HerdrError.tunnelFailed("socket(): \(String(cString: strerror(errno)))")
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            throw HerdrError.tunnelFailed("bridge socket path too long")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, len)
            }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            let reason = String(cString: strerror(errno))
            close(fd)
            throw HerdrError.tunnelFailed("bind/listen: \(reason)")
        }

        listenerFD = fd
        localSocketPath = path
        startAccepting(binary: binary, token: token)
        return path
    }

    public func tearDown() {
        acceptTask?.cancel()
        acceptTask = nil
        if listenerFD >= 0 {
            close(listenerFD)
            listenerFD = -1
        }
        if let localSocketPath {
            try? FileManager.default.removeItem(atPath: localSocketPath)
        }
        localSocketPath = nil
        for (fd, child) in children {
            child.terminate()
            close(fd)
        }
        children.removeAll()
    }

    private func startAccepting(binary: String, token: String) {
        let listener = listenerFD
        acceptTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                let client = accept(listener, nil, nil)
                guard client >= 0 else {
                    if errno == EINTR { continue }
                    break  // listener closed by tearDown
                }
                await self?.spawnSession(binary: binary, token: token, clientFD: client)
            }
        }
    }

    /// inetd style: the accepted socket becomes the child's stdin and stdout,
    /// so tailcat reads and writes the client directly. Our copy of the fd is
    /// closed once the child owns it; the child's exit closes the connection.
    private func spawnSession(binary: String, token: String, clientFD: Int32) {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: binary)
        child.arguments = [token, Self.herdrPort]
        let handle = FileHandle(fileDescriptor: clientFD, closeOnDealloc: false)
        child.standardInput = handle
        child.standardOutput = handle
        child.standardError = FileHandle.nullDevice
        child.terminationHandler = { [weak self] _ in
            Task { await self?.reap(clientFD) }
        }
        do {
            try child.run()
            children[clientFD] = child
            // The child inherited the fd; drop our copy so its EOF propagates.
            close(clientFD)
        } catch {
            close(clientFD)
        }
    }

    private func reap(_ clientFD: Int32) {
        children.removeValue(forKey: clientFD)
    }

    /// Deterministic bridge path so `attachCommand` (nonisolated) can point a
    /// local herdr CLI at the tunnel without touching actor state. Derived
    /// from the device id, not the token. Short: sockaddr_un caps at 104 bytes.
    public static func bridgeSocketPath(credentialID: UUID) -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("herdrm-tunnels", isDirectory: true)
            .appendingPathComponent("tc-\(abs(credentialID.uuidString.hashValue) % 100_000).sock")
            .path
    }

    /// tailcat from the login-shell PATH, the GUI PATH, or well-known prefixes.
    static func findTailcatBinary() -> String? {
        if let found = (ShellEnvironment.cached ?? .empty).findExecutable("tailcat") {
            return found
        }
        let wellKnown = [
            "/opt/homebrew/bin/tailcat",
            "/usr/local/bin/tailcat",
            "\(NSHomeDirectory())/.local/bin/tailcat",
        ]
        return wellKnown.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
#endif  // os(macOS)
