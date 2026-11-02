#if os(macOS)
import CryptoKit
import Darwin
import Foundation

/// A phone paired with this Mac through the relay.
public struct RelayPairedPhone: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    /// The phone's Noise static public key.
    public var staticKey: Data
    /// `ssh-ed25519 AAAA…` installed in `~/.ssh/authorized_keys` for it.
    public var sshKey: String
    public var pairedAt: Date
}

/// Where the Mac keeps its relay identity and its paired phones. The
/// production store uses the Keychain and Application Support; tests use
/// `memory`.
public protocol RelayHostStore: AnyObject, Sendable {
    var signingKey: Curve25519.Signing.PrivateKey { get }
    var noiseKey: Curve25519.KeyAgreement.PrivateKey { get }
    func phones() -> [RelayPairedPhone]
    func psk(forPhone id: String) -> Data?
    func add(_ phone: RelayPairedPhone, psk: Data) throws
    func remove(phoneID: String)
}

/// Keychain for keys and PSKs; the phone list (no secrets) as JSON.
public final class RelayKeychainHostStore: RelayHostStore, @unchecked Sendable {
    private let keychain: RelayKeychain
    private let fileURL: URL
    private let lock = NSLock()
    public let signingKey: Curve25519.Signing.PrivateKey
    public let noiseKey: Curve25519.KeyAgreement.PrivateKey

    public init(keychain: RelayKeychain = RelayKeychain(), directory: URL? = nil) {
        self.keychain = keychain
        let dir = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HerdrM", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("relay-phones.json")
        signingKey = keychain.signingKey("host.signing")
        noiseKey = keychain.agreementKey("host.noise")
    }

    public func phones() -> [RelayPairedPhone] {
        lock.withLock {
            guard let data = try? Data(contentsOf: fileURL) else { return [] }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return (try? decoder.decode([RelayPairedPhone].self, from: data)) ?? []
        }
    }

    public func psk(forPhone id: String) -> Data? { keychain.data("phone.psk.\(id)") }

    public func add(_ phone: RelayPairedPhone, psk: Data) throws {
        guard keychain.set(psk, for: "phone.psk.\(phone.id)") else {
            throw RelayError.refused(String(localized: "Couldn't save the pairing in the Keychain."))
        }
        try save(phones().filter { $0.id != phone.id && $0.staticKey != phone.staticKey } + [phone])
    }

    public func remove(phoneID: String) {
        keychain.remove("phone.psk.\(phoneID)")
        try? save(phones().filter { $0.id != phoneID })
    }

    private func save(_ phones: [RelayPairedPhone]) throws {
        try lock.withLock {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(phones).write(to: fileURL, options: .atomic)
        }
    }
}

/// `~/.ssh/authorized_keys` lines for paired phones. Each is restricted to
/// logins from this Mac itself, which is where the relay's sessions come from,
/// and tagged so it can be removed again.
public enum RelayAuthorizedKeys {
    public static func tag(phoneID: String) -> String { "herdrm-relay:\(phoneID)" }

    /// `localOnly`: the key logs in only from this Mac itself, i.e. through
    /// the relay. Off when the Mac also accepts the phone directly.
    public static func line(sshKey: String, phoneID: String, localOnly: Bool = true) -> String {
        let parts = sshKey.split(separator: " ")
        let keyPart = parts.prefix(2).joined(separator: " ")
        let restriction = localOnly ? #"from="127.0.0.1,::1" "# : ""
        return "\(restriction)\(keyPart) \(tag(phoneID: phoneID))"
    }

    /// Only well-formed Ed25519 keys are accepted from a phone.
    public static func isValid(sshKey: String) -> Bool {
        let parts = sshKey.split(separator: " ")
        guard parts.count >= 2, parts[0] == "ssh-ed25519",
              let blob = Data(base64Encoded: String(parts[1])), blob.count == 51
        else { return false }
        return true
    }

    public static func add(sshKey: String, phoneID: String, localOnly: Bool = true, file: URL = defaultFile) throws {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        var text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let tag = tag(phoneID: phoneID)
        text = text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasSuffix(" " + tag) }.joined(separator: "\n")
        if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
        text += line(sshKey: sshKey, phoneID: phoneID, localOnly: localOnly) + "\n"
        try write(text, to: file)
    }

    public static func remove(phoneID: String, file: URL = defaultFile) {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return }
        let tag = tag(phoneID: phoneID)
        let kept = text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasSuffix(" " + tag) }.joined(separator: "\n")
        if kept != text { try? write(kept, to: file) }
    }

    private static func write(_ text: String, to file: URL) throws {
        try Data(text.utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    public static var defaultFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/authorized_keys")
    }
}

/// The Mac's side of the relay: stays registered, answers phones, pairs new
/// ones while a code is showing, and forwards each session to the local sshd.
public actor RelayHost {
    public enum Status: Equatable, Sendable {
        case stopped
        case connecting
        case online
        case failed(String)
    }

    public struct PendingPairing: Equatable, Sendable {
        public let link: RelayPairingLink
        public let expires: Date
    }

    public let relay: URL
    public nonisolated let hostID: String
    private let store: RelayHostStore
    private let hostName: String
    private let userName: String
    /// Opens the connection a session is forwarded to (sshd by default).
    private let forward: @Sendable () throws -> Int32
    private let authorizedKeys: URL?
    /// The user's public address for this Mac (`host` or `host:port`), sent
    /// to phones so they connect directly when they can.
    private let directAddress: String?
    /// The SSH host key reported to phones; nil reads this Mac's own.
    private let sshHostKeyLine: String?
    private let onEvent: @Sendable (Event) -> Void

    public enum Event: Sendable {
        case status(Status)
        case paired(RelayPairedPhone)
        case pairingChanged(PendingPairing?)
    }

    private var runTask: Task<Void, Never>?
    private var control: RelaySocket?
    private var pending: (psk: Data, expires: Date)?
    public private(set) var status: Status = .stopped

    /// - Parameters:
    ///   - authorizedKeys: the file new phones' SSH keys go into; nil to
    ///     skip (tests).
    ///   - forward: what a session talks to; default `127.0.0.1:22`.
    public init(
        relay: URL = RelayProtocol.defaultRelayURL,
        store: RelayHostStore,
        hostName: String = Host.current().localizedName ?? "Mac",
        userName: String = NSUserName(),
        authorizedKeys: URL? = RelayAuthorizedKeys.defaultFile,
        directAddress: String? = nil,
        sshHostKey: String? = nil,
        forward: (@Sendable () throws -> Int32)? = nil,
        onEvent: @escaping @Sendable (Event) -> Void = { _ in }
    ) {
        self.relay = relay
        self.store = store
        self.hostID = RelayProtocol.hostID(for: store.signingKey.publicKey)
        self.hostName = hostName
        self.userName = userName
        self.authorizedKeys = authorizedKeys
        let direct = directAddress?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.directAddress = (direct?.isEmpty ?? true) ? nil : direct
        self.sshHostKeyLine = sshHostKey
        self.forward = forward ?? { try RelayHost.connectLocalSSH() }
        self.onEvent = onEvent
    }

    // MARK: Lifecycle

    public func start() {
        guard runTask == nil else { return }
        syncAuthorizedKeys()
        runTask = Task { await self.runLoop() }
    }

    /// Keeps every paired phone's key line in step with the direct address:
    /// restricted to this Mac while the relay is the only way in, open once
    /// the phone may also connect directly.
    private func syncAuthorizedKeys() {
        guard let authorizedKeys else { return }
        for phone in store.phones() {
            try? RelayAuthorizedKeys.add(sshKey: phone.sshKey, phoneID: phone.id,
                                         localOnly: directAddress == nil, file: authorizedKeys)
        }
    }

    public func stop() {
        runTask?.cancel()
        runTask = nil
        control?.close()
        control = nil
        setStatus(.stopped)
    }

    private func setStatus(_ s: Status) {
        guard s != status else { return }
        status = s
        onEvent(.status(s))
    }

    private func runLoop() async {
        var delay: UInt64 = 1
        while !Task.isCancelled {
            setStatus(.connecting)
            do {
                let socket = try await register()
                control = socket
                setStatus(.online)
                delay = 1
                // Two missed pongs close the socket, which ends the read
                // below with an error and so reconnects.
                let heartbeat = Task {
                    var missed = 0
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 25_000_000_000)
                        if Task.isCancelled { return }
                        missed = await socket.ping() ? 0 : missed + 1
                        if missed >= 2 {
                            socket.close()
                            return
                        }
                    }
                }
                defer { heartbeat.cancel() }
                while !Task.isCancelled {
                    let message = try await socket.receiveControl()
                    if message.t == "incoming", let session = message.session {
                        Task { await self.handle(session: session) }
                    }
                }
            } catch {
                control?.close()
                control = nil
                if Task.isCancelled { break }
                if case RelayError.replaced = error {
                    // Another Herdrm on this Mac holds the slot; don't fight it.
                    setStatus(.failed(error.localizedDescription))
                    return
                }
                setStatus(.failed(error.localizedDescription))
            }
            try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            delay = min(delay * 2, 30)
        }
    }

    private func register() async throws -> RelaySocket {
        let socket = RelaySocket(url: RelayProtocol.endpoint(relay, path: "/v1/host", query: ["id": hostID]))
        do {
            let challenge = try await socket.receiveControl()
            guard challenge.t == "challenge", let nonce = challenge.nonce else {
                throw RelayError.protocolViolation("expected challenge")
            }
            let key = store.signingKey
            try await socket.send(control: .init(
                t: "auth", pub: key.publicKey.rawRepresentation,
                sig: try key.signature(for: RelayProtocol.hostMessage(nonce: nonce))))
            guard try await socket.receiveControl().t == "ready" else {
                throw RelayError.protocolViolation("expected ready")
            }
            return socket
        } catch {
            socket.close()
            throw error
        }
    }

    // MARK: Pairing

    /// A fresh pairing code, replacing any showing one.
    public func beginPairing() -> PendingPairing {
        var psk = Data(count: 32)
        _ = psk.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        let expires = Date().addingTimeInterval(RelayProtocol.pairingLifetime)
        pending = (psk, expires)
        let p = PendingPairing(link: RelayPairingLink(
            relay: relay, hostID: hostID, hostStatic: store.noiseKey.publicKey.rawRepresentation,
            psk: psk, hostName: hostName, userName: userName), expires: expires)
        onEvent(.pairingChanged(p))
        return p
    }

    /// Whether a pairing code is showing and still valid.
    public var isPairingPending: Bool {
        guard let pending else { return false }
        return pending.expires > Date()
    }

    func setPendingExpiryForTesting(_ date: Date) {
        if let current = pending { pending = (current.psk, date) }
    }

    public func cancelPairing() {
        pending = nil
        onEvent(.pairingChanged(nil))
    }

    public func removePhone(_ id: String) {
        store.remove(phoneID: id)
        if let authorizedKeys { RelayAuthorizedKeys.remove(phoneID: id, file: authorizedKeys) }
    }

    // MARK: Sessions

    private func handle(session: String) async {
        let socket = RelaySocket(url: RelayProtocol.endpoint(relay, path: "/v1/accept", query: ["id": hostID, "session": session]))
        do {
            try await socket.send(control: .init(
                t: "auth", sig: try store.signingKey.signature(for: RelayProtocol.acceptMessage(session: session))))
            var noise = NoiseResponder(prologue: RelayNoise.prologue(hostID: hostID), staticKey: store.noiseKey)
            let opening = try noise.readMessage1(try await socket.receiveData())
            let phoneStatic = noise.initiatorStatic
            let wantsPairing = (try? JSONDecoder().decode(Opening.self, from: opening))?.pair == true

            let known = store.phones().first { $0.staticKey == phoneStatic }
            let psk: Data
            let pairing: Bool
            if wantsPairing || known == nil, let pending, pending.expires > Date() {
                psk = pending.psk
                pairing = true
            } else if let known, let stored = store.psk(forPhone: known.id) {
                psk = stored
                pairing = false
            } else {
                socket.close() // unknown phone and no code showing
                return
            }
            let info = RelayMessage.HostInfo(name: hostName, user: userName, sshHostKey: sshHostKeyLine ?? Self.sshHostKey(),
                                             direct: directAddress)
            let (message2, noiseSession) = try noise.writeMessage2(payload: try JSONEncoder().encode(info), psk: psk)
            try await socket.send(message2)
            let stream = RelayStream(socket: socket, session: noiseSession)

            // The first transport message is the proof that the phone holds
            // the PSK; only now may a new phone be recorded.
            let hello = try await stream.readJSON(RelayMessage.Hello.self)
            if pairing {
                guard RelayAuthorizedKeys.isValid(sshKey: hello.sshKey) else {
                    try? await stream.writeJSON(RelayMessage.Reply.error(String(localized: "The phone sent an unusable SSH key.")))
                    stream.close()
                    return
                }
                // Pairing a known phone again keeps its id, so its key line
                // is replaced, not duplicated.
                let phone = RelayPairedPhone(
                    id: known?.id ?? UUID().uuidString.lowercased(), name: String(hello.name.prefix(80)),
                    staticKey: phoneStatic, sshKey: hello.sshKey, pairedAt: Date())
                if let authorizedKeys {
                    try RelayAuthorizedKeys.add(sshKey: hello.sshKey, phoneID: phone.id,
                                                localOnly: directAddress == nil, file: authorizedKeys)
                }
                try store.add(phone, psk: psk)
                pending = nil
                onEvent(.pairingChanged(nil))
                onEvent(.paired(phone))
            }
            let target: Int32
            do {
                target = try forward()
            } catch {
                try? await stream.writeJSON(RelayMessage.Reply.error(String(localized: "Remote Login is off on this Mac. Turn it on in System Settings → General → Sharing.")))
                stream.close()
                return
            }
            try await stream.writeJSON(RelayMessage.Reply.welcome)
            await RelayPump.run(descriptor: target, stream: stream)
        } catch {
            socket.close()
        }
    }

    /// Message 1's payload.
    private struct Opening: Decodable { var pair: Bool? }

    // MARK: Local SSH

    /// A blocking TCP connection to this Mac's sshd.
    public static func connectLocalSSH(port: UInt16 = 22) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw RelayError.closed }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            Darwin.close(fd)
            throw RelayError.closed
        }
        return fd
    }

    /// Whether sshd answers locally (System Settings → Sharing → Remote Login).
    public static func remoteLoginEnabled() -> Bool {
        guard let fd = try? connectLocalSSH() else { return false }
        Darwin.close(fd)
        return true
    }

    /// The Mac's SSH host key, so the phone can pin it on first contact.
    static func sshHostKey() -> String? {
        guard let text = try? String(contentsOfFile: "/etc/ssh/ssh_host_ed25519_key.pub", encoding: .utf8) else { return nil }
        let parts = text.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        return parts.prefix(2).joined(separator: " ")
    }
}

/// For tests: keys and phones in memory.
public final class RelayMemoryHostStore: RelayHostStore, @unchecked Sendable {
    public let signingKey = Curve25519.Signing.PrivateKey()
    public let noiseKey = Curve25519.KeyAgreement.PrivateKey()
    private let lock = NSLock()
    private var list: [RelayPairedPhone] = []
    private var psks: [String: Data] = [:]

    public init() {}

    public func phones() -> [RelayPairedPhone] { lock.withLock { list } }
    public func psk(forPhone id: String) -> Data? { lock.withLock { psks[id] } }
    public func add(_ phone: RelayPairedPhone, psk: Data) throws {
        lock.withLock {
            list.removeAll { $0.id == phone.id || $0.staticKey == phone.staticKey }
            list.append(phone)
            psks[phone.id] = psk
        }
    }
    public func remove(phoneID: String) {
        lock.withLock {
            list.removeAll { $0.id == phoneID }
            psks[phoneID] = nil
        }
    }
}
#endif
