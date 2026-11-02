import CryptoKit
import Foundation

/// Herdrm's relay: how a phone reaches a Mac with no public address. The relay
/// matches the two and forwards end-to-end encrypted frames it can't read; the
/// wire protocol is docs/PROTOCOL.md in the (private) herdrm-relay repository,
/// and `RelayNoise` is the handshake.
public enum RelayProtocol {
    /// The relay Herdrm uses unless the Mac is pointed elsewhere.
    public static let defaultRelayURL = URL(string: "wss://herdrm-relay.owo.network")!

    public static let maxFrame = 65535
    /// A pairing QR code is good for this long, and for one phone.
    public static let pairingLifetime: TimeInterval = 10 * 60

    /// Close codes the relay sends (WebSocket application range).
    public enum CloseCode: Int, Sendable {
        case authFailed = 4401
        case hostOffline = 4404
        case replaced = 4409
        case busy = 4429
        case acceptTimeout = 4504
    }

    /// `HostID(pub)`: the first 16 bytes of SHA-256 of the Mac's Ed25519
    /// relay key, base32 lowercase without padding.
    public static func hostID(for publicKey: Curve25519.Signing.PublicKey) -> String {
        let digest = Data(SHA256.hash(data: publicKey.rawRepresentation)).prefix(16)
        return base32(digest).lowercased()
    }

    static func base32(_ data: Data) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var out = ""
        var buffer = 0
        var bits = 0
        for byte in data {
            buffer = (buffer << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                out.append(alphabet[(buffer >> (bits - 5)) & 31])
                bits -= 5
            }
        }
        if bits > 0 { out.append(alphabet[(buffer << (5 - bits)) & 31]) }
        return out
    }

    static func hostMessage(nonce: Data) -> Data { Data("herdrm-relay/1 host ".utf8) + nonce }
    static func acceptMessage(session: String) -> Data { Data("herdrm-relay/1 accept \(session)".utf8) }

    static func endpoint(_ relay: URL, path: String, query: [String: String]) -> URL {
        var components = URLComponents(url: relay, resolvingAgainstBaseURL: false)!
        let base = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = base + path
        components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.url!
    }

    /// A relay control message (JSON text frame; byte fields base64).
    struct Control: Codable, Equatable {
        var t: String
        var nonce: Data?
        var pub: Data?
        var sig: Data?
        var session: String?
    }
}

/// What a pairing QR code carries: where the Mac waits, how to recognize it,
/// and the one-time secret that admits one phone.
///
/// `herdrm://pair?v=1&relay=…&id=…&k=…&psk=…&n=…&u=…`
public struct RelayPairingLink: Equatable, Sendable {
    public var relay: URL
    public var hostID: String
    /// The Mac's Noise static public key (X25519, 32 bytes).
    public var hostStatic: Data
    public var psk: Data
    public var hostName: String
    /// The Mac account SSH logs in as.
    public var userName: String

    public init(relay: URL, hostID: String, hostStatic: Data, psk: Data, hostName: String, userName: String) {
        self.relay = relay
        self.hostID = hostID
        self.hostStatic = hostStatic
        self.psk = psk
        self.hostName = hostName
        self.userName = userName
    }

    public var url: URL {
        var c = URLComponents()
        c.scheme = "herdrm"
        c.host = "pair"
        c.queryItems = [
            URLQueryItem(name: "v", value: "1"),
            URLQueryItem(name: "relay", value: relay.absoluteString),
            URLQueryItem(name: "id", value: hostID),
            URLQueryItem(name: "k", value: hostStatic.base64URL),
            URLQueryItem(name: "psk", value: psk.base64URL),
            URLQueryItem(name: "n", value: hostName),
            URLQueryItem(name: "u", value: userName),
        ]
        return c.url!
    }

    public init?(url: URL) {
        guard url.scheme == "herdrm", url.host == "pair",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return nil }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard value("v") == "1",
              let relayString = value("relay"), let relay = URL(string: relayString),
              relay.scheme == "wss" || relay.scheme == "ws",
              let hostID = value("id"), hostID.count == 26,
              let k = value("k").flatMap(Data.init(base64URL:)), k.count == 32,
              let psk = value("psk").flatMap(Data.init(base64URL:)), psk.count == 32,
              let user = value("u"), !user.isEmpty
        else { return nil }
        self.init(relay: relay, hostID: hostID, hostStatic: k, psk: psk,
                  hostName: value("n") ?? "Mac", userName: user)
    }

    public init?(string: String) {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        self.init(url: url)
    }
}

/// The JSON payloads inside the Noise session.
public enum RelayMessage {
    /// Message 2's payload: who the phone reached.
    public struct HostInfo: Codable, Equatable, Sendable {
        public var v: Int = 1
        public var name: String
        public var user: String
        /// The Mac's `ssh-ed25519 AAAA…` host key, so the phone pins it.
        public var sshHostKey: String?

        public init(name: String, user: String, sshHostKey: String?) {
            self.name = name
            self.user = user
            self.sshHostKey = sshHostKey
        }
    }

    /// The phone's first transport message.
    public struct Hello: Codable, Equatable, Sendable {
        public var t = "hello"
        public var name: String
        /// `ssh-ed25519 AAAA…`: installed on the Mac at pairing.
        public var sshKey: String

        public init(name: String, sshKey: String) {
            self.name = name
            self.sshKey = sshKey
        }
    }

    /// The Mac's answer to `Hello`: `welcome`, or `error` with a message.
    public struct Reply: Codable, Equatable, Sendable {
        public var t: String
        public var message: String?

        public static let welcome = Reply(t: "welcome", message: nil)
        public static func error(_ message: String) -> Reply { Reply(t: "error", message: message) }
    }
}

public enum RelayError: LocalizedError, Equatable {
    case hostOffline
    case hostDidNotAnswer
    case busy
    case authenticationFailed
    case replaced
    case protocolViolation(String)
    case refused(String)
    case closed

    public var errorDescription: String? {
        switch self {
        case .hostOffline: return String(localized: "The Mac isn't connected to the relay. Open Herdrm on the Mac and make sure iPhone access is on.")
        case .hostDidNotAnswer: return String(localized: "The Mac didn't answer through the relay.")
        case .busy: return String(localized: "The Mac has too many phones connected.")
        case .authenticationFailed: return String(localized: "The relay couldn't verify this Mac.")
        case .replaced: return String(localized: "Another copy of Herdrm on this Mac took over the relay connection.")
        case .protocolViolation(let what): return String(localized: "Relay protocol error: \(what)")
        case .refused(let message): return message
        case .closed: return String(localized: "The relay connection closed.")
        }
    }

    static func from(closeCode: Int) -> RelayError? {
        switch RelayProtocol.CloseCode(rawValue: closeCode) {
        case .hostOffline: return .hostOffline
        case .acceptTimeout: return .hostDidNotAnswer
        case .busy: return .busy
        case .authFailed: return .authenticationFailed
        case .replaced: return .replaced
        case nil: return nil
        }
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    init?(base64URL: String) {
        var s = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        self.init(base64Encoded: s)
    }
}
