import CryptoKit
import Foundation
import HerdrKit
import HerdrSSH

/// How the phone reaches a device's herdr session: direct SSH with a
/// `direct-streamlocal` channel per RPC (herdr is one-request-per-connection),
/// or the tailcat tunnel re-served on a local Unix socket by the embedded
/// bridge (same NDJSON API, no shell).
protocol MobileTransport: AnyObject, Sendable {
    func request(method: String, params: JSONValue) async throws -> JSONValue
    func events(kinds: [String], statusPaneIDs: [String]) -> AsyncThrowingStream<HerdrEvent, Error>
    func openTerminal(command: String, columns: Int, rows: Int) async throws -> SSHPTYChannel
    func close() async
}

extension MobileTransport {
    func request<T: Decodable>(
        method: String,
        params: JSONValue = .object([:]),
        as type: T.Type
    ) async throws -> T {
        let result = try await request(method: method, params: params)
        let data = try JSONEncoder().encode(result)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw HerdrError.malformedResponse("\(method): \(error)")
        }
    }
}

enum MobileTransportError: LocalizedError {
    case hostKeyChanged(fingerprint: String)
    case missingPassword
    case homeProbeFailed
    case tailcatTerminalUnsupported

    var errorDescription: String? {
        switch self {
        case .hostKeyChanged(let fingerprint):
            return String(
                localized: "This device's SSH host key changed (\(fingerprint)). If the host was reinstalled, remove and re-add the device."
            )
        case .missingPassword:
            return String(localized: "No password saved for this device.")
        case .homeProbeFailed:
            return String(localized: "Could not resolve the home directory on the device.")
        case .tailcatTerminalUnsupported:
            return String(localized: "Terminal attach isn't available over tailcat on iOS yet — the tunnel carries herdr's control plane only.")
        }
    }
}

/// Owns one authenticated SSH connection to a device. RPCs each open a fresh
/// streamlocal channel (herdr closes the socket after one reply); the event
/// subscription holds a long-lived channel and streams NDJSON lines.
final class SSHDirectTransport: MobileTransport {
    private let connection: SSHConnection
    private let socketPath: String

    private static let requestTimeout: Duration = .seconds(15)

    private init(connection: SSHConnection, socketPath: String) {
        self.connection = connection
        self.socketPath = socketPath
    }

    /// Connects, verifies the pinned host key (TOFU on first contact),
    /// authenticates (device key or Keychain password), and resolves the
    /// remote herdr socket path against the remote $HOME.
    static func connect(device: MobileDevice) async throws -> SSHDirectTransport {
        let connection = try await SSHConnection.connect(
            to: SSHEndpoint(host: device.host, port: device.port),
            timeout: .seconds(10)
        )
        do {
            let hostKey = connection.hostKey
            let fingerprint = Self.fingerprint(hostKey.key)
            if let pinned = KnownHostsStore.fingerprint(
                host: device.host, port: device.port, algorithm: hostKey.algorithm
            ) {
                guard pinned == fingerprint else {
                    throw MobileTransportError.hostKeyChanged(fingerprint: fingerprint)
                }
            } else {
                KnownHostsStore.pin(
                    host: device.host, port: device.port,
                    algorithm: hostKey.algorithm, fingerprint: fingerprint
                )
            }

            switch device.authMethod {
            case .deviceKey:
                // The private key stays in CryptoKit; libssh2 only ever sees
                // the signature produced by this closure.
                let key = DeviceKey.ensure()
                try await connection.authenticate(
                    username: device.username,
                    publicKey: DeviceKey.publicKeyBlob(key),
                    signer: { challenge in try key.signature(for: challenge) },
                    timeout: .seconds(15)
                )
            case .password:
                guard let password = MobileSecretStore.password(for: device.id) else {
                    throw MobileTransportError.missingPassword
                }
                try await connection.authenticate(
                    username: device.username,
                    password: password,
                    timeout: .seconds(15)
                )
            }

            let socketPath: String
            if let override = device.socketPath, !override.isEmpty {
                socketPath = override
            } else {
                // sshd exec is not a login shell, but $HOME is always set.
                let result = try await connection.execute(
                    "printf '%s' \"$HOME\"", timeout: .seconds(10)
                )
                guard let home = String(data: result.stdout, encoding: .utf8),
                      home.hasPrefix("/")
                else { throw MobileTransportError.homeProbeFailed }
                socketPath = home + "/.config/herdr/herdr.sock"
            }
            return SSHDirectTransport(connection: connection, socketPath: socketPath)
        } catch {
            try? await connection.close(timeout: .seconds(2))
            throw error
        }
    }

    static func fingerprint(_ key: Data) -> String {
        "SHA256:" + Data(SHA256.hash(data: key)).base64EncodedString()
    }

    func request(method: String, params: JSONValue) async throws -> JSONValue {
        let payload = SocketRPC.encodeRequest(
            id: UUID().uuidString, method: method, params: params
        )
        let reply: Data
        do {
            reply = try await connection.exchangeStreamLocal(
                socketPath: socketPath,
                request: payload,
                timeout: Self.requestTimeout
            )
        } catch SSHError.streamLocalOpenFailed {
            throw HerdrError.remoteHerdrDown(target: "device", socketPath: socketPath)
        }
        // exchangeStreamLocal returns up to the first newline-terminated chunk;
        // trim a trailing newline before decoding.
        var line = reply
        if line.last == 0x0A { line.removeLast() }
        return try SocketRPC.decodeResponse(line)
    }

    func events(
        kinds: [String],
        statusPaneIDs: [String]
    ) -> AsyncThrowingStream<HerdrEvent, Error> {
        let connection = connection
        let socketPath = socketPath
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var scopedPaneIDs = statusPaneIDs
                    subscriptionAttempt: while !Task.isCancelled {
                        let channel = try await connection.openStreamLocal(
                            socketPath: socketPath, timeout: .seconds(10)
                        )
                        var retryWithoutScopedStatus = false
                        do {
                            let subscribe = SocketRPC.eventSubscriptionParams(
                                kinds: kinds,
                                statusPaneIDs: scopedPaneIDs
                            )
                            try await channel.write(
                                SocketRPC.encodeRequest(
                                    id: "events",
                                    method: "events.subscribe",
                                    params: subscribe
                                ),
                                timeout: .seconds(10)
                            )
                            var buffer = Data()
                            var sawAck = false
                            eventRead: while !Task.isCancelled {
                                // Long timeout: herdr only writes when something happens.
                                guard let chunk = try await channel.read(timeout: .seconds(3600)) else { break }
                                buffer.append(chunk)
                                while let index = buffer.firstIndex(of: 0x0A) {
                                    let line = buffer.prefix(upTo: index)
                                    buffer.removeSubrange(...index)
                                    guard !line.isEmpty else { continue }
                                    guard sawAck else {
                                        do {
                                            _ = try SocketRPC.decodeResponse(Data(line))
                                        } catch where SocketRPC.shouldRetryStatusSubscription(
                                            after: error,
                                            statusPaneIDs: scopedPaneIDs
                                        ) {
                                            retryWithoutScopedStatus = true
                                            break eventRead
                                        }
                                        sawAck = true
                                        continuation.yield(HerdrEvent(
                                            kind: HerdrEvent.subscriptionStartedKind,
                                            payload: .object([:])
                                        ))
                                        continue
                                    }
                                    if let event = SocketRPC.decodeEvent(Data(line)) {
                                        continuation.yield(event)
                                    }
                                }
                            }
                        } catch {
                            try? await channel.close(timeout: .seconds(2))
                            throw error
                        }
                        try? await channel.close(timeout: .seconds(2))
                        if retryWithoutScopedStatus {
                            scopedPaneIDs = []
                            continue subscriptionAttempt
                        }
                        if Task.isCancelled {
                            continuation.finish()
                        } else {
                            continuation.finish(throwing: HerdrError.connectionFailed(
                                "event stream ended"
                            ))
                        }
                        return
                    }
                    if !Task.isCancelled {
                        continuation.finish()
                    } else {
                        continuation.finish()
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// A PTY session channel running `command` directly (no login shell).
    /// sshd's exec PATH is bare, so callers prepend the well-known prefixes.
    func openTerminal(command: String, columns: Int, rows: Int) async throws -> SSHPTYChannel {
        try await connection.openPTY(
            command: command,
            columns: columns,
            rows: rows,
            timeout: .seconds(15)
        )
    }

    func close() async {
        try? await connection.close(timeout: .seconds(3))
    }
}

/// tailcat control-plane transport: the embedded bridge (HerdrTailcat, via
/// HerdrKit's `TailcatBridgeManager`) holds the WireGuard/DERP session and
/// re-serves the remote herdr API socket on a local Unix socket, so RPC and
/// the event stream are plain `SocketRPC` — the same face the Mac app's
/// tailcat devices use. The tunnel carries no shell, so terminal attach
/// throws; prompting and key input still work, both being socket RPCs.
final class TailcatMobileTransport: MobileTransport {
    private let deviceID: UUID
    private let rpc: SocketRPC

    private init(deviceID: UUID, socketPath: String) {
        self.deviceID = deviceID
        self.rpc = SocketRPC(socketPath: socketPath)
    }

    /// Brings the per-device bridge up (token straight from the Keychain to
    /// the Go runtime) and returns a transport over its local socket. The
    /// bridge binds its listeners before returning; the first tunnel dial
    /// doubles as the handshake, and a bad token surfaces on the first
    /// request via `recentError`.
    static func connect(device: MobileDevice) async throws -> TailcatMobileTransport {
        let socketPath = try await TailcatBridgeManager.shared.ensureUp(deviceID: device.id)
        return TailcatMobileTransport(deviceID: device.id, socketPath: socketPath)
    }

    func request(method: String, params: JSONValue) async throws -> JSONValue {
        do {
            return try await rpc.request(method: method, params: params)
        } catch {
            // A refused tunnel dial reads as a generic socket error; the
            // bridge's recorded error (bad token, unreachable server) is the
            // actionable version, mirroring HerdrService's tailcat path.
            if let detail = await TailcatBridgeManager.shared.recentError(deviceID: deviceID) {
                throw HerdrError.tailcatBridgeFailed(detail)
            }
            throw error
        }
    }

    func events(
        kinds: [String],
        statusPaneIDs: [String]
    ) -> AsyncThrowingStream<HerdrEvent, Error> {
        rpc.events(kinds: kinds, statusPaneIDs: statusPaneIDs)
    }

    func openTerminal(command _: String, columns _: Int, rows _: Int) async throws -> SSHPTYChannel {
        throw MobileTransportError.tailcatTerminalUnsupported
    }

    func close() async {
        await TailcatBridgeManager.shared.tearDown(deviceID: deviceID)
    }
}

enum MobileAttach {
    /// Non-login sshd exec leaves PATH at /usr/bin:/bin; herdr usually lives in
    /// a user prefix. Mirrors the Mac app's remote attach PATH handling.
    static let pathExport = #"export PATH="$PATH:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$HOME/bin""#

    /// APC marker printed just before exec. sshd runs the command through the
    /// user's shell, whose rc chatter would otherwise leak into the terminal;
    /// the attach session drops everything before this marker (Heeler's
    /// AttachBootstrapHandshake trick).
    static let bootstrapMarker = Data([0x1B, 0x5F]) + Data("herdrm-attach".utf8) + Data([0x1B, 0x5C])
    private static let markerPrintf = #"printf '\033_herdrm-attach\033\\'"#

    /// The remote command for attaching to an agent pane or a bare terminal.
    static func command(target: TerminalAttachTarget) -> String {
        let attach: String
        switch target {
        case .agent(let paneID):
            attach = "herdr agent attach \(ShellQuoting.quoted(paneID)) --takeover"
        case .terminal(let terminalID):
            attach = "herdr terminal attach \(ShellQuoting.quoted(terminalID)) --takeover"
        }
        let script = "\(pathExport); \(markerPrintf); exec \(attach)"
        return "/bin/sh -c \(ShellQuoting.quoted(script))"
    }
}
