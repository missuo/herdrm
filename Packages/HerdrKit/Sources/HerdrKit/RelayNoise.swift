import CryptoKit
import Foundation

/// Noise_IKpsk2_25519_ChaChaPoly_SHA256, the end-to-end handshake between
/// Herdrm on a phone (initiator) and the Mac it pairs with (responder), as
/// specified in the relay's docs/PROTOCOL.md and checked byte for byte against
/// the Go reference (`flynn/noise`) in `RelayNoiseTests`.
///
/// ```
/// <- s                       (the Mac's static key, from the QR code)
/// -> e, es, s, ss
/// <- e, ee, se, psk
/// ```
public enum RelayNoise {
    public static let protocolName = "Noise_IKpsk2_25519_ChaChaPoly_SHA256"
    /// Plaintext bound per transport message, well under Noise's 65535-byte
    /// message limit once the 16-byte tag is added.
    public static let maxPlaintext = 16 * 1024

    public enum Failure: Error, Equatable {
        case malformedMessage
        case decryptionFailed
        case badKey
        case nonceExhausted
    }

    /// The bound a session is negotiated for: one Mac's relay host id.
    public static func prologue(hostID: String) -> Data { Data("herdrm-relay/1 \(hostID)".utf8) }
}

/// One direction of an established session (Noise CipherState).
public struct NoiseCipher: Sendable {
    private let key: SymmetricKey
    private var nonce: UInt64 = 0

    init(key: SymmetricKey) { self.key = key }

    public mutating func encrypt(_ plaintext: Data, ad: Data = Data()) throws -> Data {
        guard nonce < UInt64.max else { throw RelayNoise.Failure.nonceExhausted }
        defer { nonce += 1 }
        return try Self.seal(plaintext, key: key, nonce: nonce, ad: ad)
    }

    public mutating func decrypt(_ ciphertext: Data, ad: Data = Data()) throws -> Data {
        guard nonce < UInt64.max else { throw RelayNoise.Failure.nonceExhausted }
        let plaintext = try Self.open(ciphertext, key: key, nonce: nonce, ad: ad)
        nonce += 1 // only a message that decrypts consumes its nonce
        return plaintext
    }

    /// ChaCha20-Poly1305 with Noise's nonce layout: 32 zero bits, then the
    /// 64-bit counter little-endian.
    static func nonceBytes(_ n: UInt64) -> ChaChaPoly.Nonce {
        var bytes = Data(count: 4)
        withUnsafeBytes(of: n.littleEndian) { bytes.append(contentsOf: $0) }
        return try! ChaChaPoly.Nonce(data: bytes)
    }

    static func seal(_ plaintext: Data, key: SymmetricKey, nonce: UInt64, ad: Data) throws -> Data {
        let box = try ChaChaPoly.seal(plaintext, using: key, nonce: nonceBytes(nonce), authenticating: ad)
        // A fresh buffer: CryptoKit's ciphertext can be a slice with a nonzero start index.
        return Data(box.ciphertext) + box.tag
    }

    static func open(_ ciphertext: Data, key: SymmetricKey, nonce: UInt64, ad: Data) throws -> Data {
        guard ciphertext.count >= 16 else { throw RelayNoise.Failure.malformedMessage }
        let box = try ChaChaPoly.SealedBox(
            nonce: nonceBytes(nonce),
            ciphertext: ciphertext.prefix(ciphertext.count - 16),
            tag: ciphertext.suffix(16))
        do {
            return try ChaChaPoly.open(box, using: key, authenticating: ad)
        } catch {
            throw RelayNoise.Failure.decryptionFailed
        }
    }
}

/// Noise SymmetricState: chaining key, handshake hash, and the current key.
struct NoiseSymmetricState {
    private(set) var ck: Data
    private(set) var h: Data
    private var k: SymmetricKey?
    private var n: UInt64 = 0

    init(protocolName: String) {
        let name = Data(protocolName.utf8)
        h = name.count <= 32 ? name + Data(count: 32 - name.count) : Data(SHA256.hash(data: name))
        ck = h
    }

    mutating func mixHash(_ data: Data) {
        h = Data(SHA256.hash(data: h + data))
    }

    mutating func mixKey(_ ikm: Data) {
        let out = Self.hkdf(chainingKey: ck, ikm: ikm, outputs: 2)
        ck = out[0]
        k = SymmetricKey(data: out[1])
        n = 0
    }

    mutating func mixKeyAndHash(_ ikm: Data) {
        let out = Self.hkdf(chainingKey: ck, ikm: ikm, outputs: 3)
        ck = out[0]
        mixHash(out[1])
        k = SymmetricKey(data: out[2])
        n = 0
    }

    mutating func encryptAndHash(_ plaintext: Data) throws -> Data {
        guard let k else {
            mixHash(plaintext)
            return plaintext
        }
        let c = try NoiseCipher.seal(plaintext, key: k, nonce: n, ad: h)
        n += 1
        mixHash(c)
        return c
    }

    mutating func decryptAndHash(_ ciphertext: Data) throws -> Data {
        guard let k else {
            mixHash(ciphertext)
            return ciphertext
        }
        let p = try NoiseCipher.open(ciphertext, key: k, nonce: n, ad: h)
        n += 1
        mixHash(ciphertext)
        return p
    }

    func split() -> (NoiseCipher, NoiseCipher) {
        let out = Self.hkdf(chainingKey: ck, ikm: Data(), outputs: 2)
        return (NoiseCipher(key: SymmetricKey(data: out[0])), NoiseCipher(key: SymmetricKey(data: out[1])))
    }

    /// Noise's HKDF: HMAC-SHA256 extract with the chaining key, then expand
    /// one 32-byte block per output.
    static func hkdf(chainingKey: Data, ikm: Data, outputs: Int) -> [Data] {
        let tempKey = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: ikm, using: SymmetricKey(data: chainingKey))))
        var result: [Data] = []
        var previous = Data()
        for i in 1...outputs {
            previous = Data(HMAC<SHA256>.authenticationCode(for: previous + [UInt8(i)], using: tempKey))
            result.append(previous)
        }
        return result
    }
}

/// An established session: `send` for messages to the peer, `receive` for
/// messages from it.
public struct NoiseSession: Sendable {
    public var send: NoiseCipher
    public var receive: NoiseCipher
    /// The peer's static public key (raw 32 bytes).
    public let peerStatic: Data
    /// The handshake hash, unique to this session.
    public let handshakeHash: Data
}

private func dh(_ privateKey: Curve25519.KeyAgreement.PrivateKey, _ publicKey: Data) throws -> Data {
    guard let peer = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKey) else {
        throw RelayNoise.Failure.badKey
    }
    guard let secret = try? privateKey.sharedSecretFromKeyAgreement(with: peer) else {
        throw RelayNoise.Failure.badKey
    }
    return secret.withUnsafeBytes { Data($0) }
}

private let dhLength = 32

/// The phone's side.
public struct NoiseInitiator {
    private var state: NoiseSymmetricState
    private let staticKey: Curve25519.KeyAgreement.PrivateKey
    private let ephemeral: Curve25519.KeyAgreement.PrivateKey
    private let responderStatic: Data
    private let psk: Data

    /// `ephemeral` is for tests only; production always draws a fresh one.
    public init(
        prologue: Data,
        staticKey: Curve25519.KeyAgreement.PrivateKey,
        responderStatic: Data,
        psk: Data,
        ephemeral: Curve25519.KeyAgreement.PrivateKey = .init()
    ) throws {
        guard psk.count == 32, responderStatic.count == dhLength else { throw RelayNoise.Failure.badKey }
        state = NoiseSymmetricState(protocolName: RelayNoise.protocolName)
        state.mixHash(prologue)
        state.mixHash(responderStatic) // <- s
        self.staticKey = staticKey
        self.ephemeral = ephemeral
        self.responderStatic = responderStatic
        self.psk = psk
    }

    /// `-> e, es, s, ss` with `payload`.
    public mutating func writeMessage1(payload: Data) throws -> Data {
        let e = ephemeral.publicKey.rawRepresentation
        var out = e
        state.mixHash(e)
        state.mixKey(e) // psk handshakes mix e into the key as well
        state.mixKey(try dh(ephemeral, responderStatic))
        out += try state.encryptAndHash(staticKey.publicKey.rawRepresentation)
        state.mixKey(try dh(staticKey, responderStatic))
        out += try state.encryptAndHash(payload)
        return out
    }

    /// `<- e, ee, se, psk`; returns the responder's payload and the session.
    public mutating func readMessage2(_ message: Data) throws -> (payload: Data, session: NoiseSession) {
        guard message.count >= dhLength + 16 else { throw RelayNoise.Failure.malformedMessage }
        let re = Data(message.prefix(dhLength))
        state.mixHash(re)
        state.mixKey(re)
        state.mixKey(try dh(ephemeral, re))    // ee
        state.mixKey(try dh(staticKey, re))    // se
        state.mixKeyAndHash(psk)
        let payload = try state.decryptAndHash(Data(message.dropFirst(dhLength)))
        let (toResponder, toInitiator) = state.split()
        return (payload, NoiseSession(send: toResponder, receive: toInitiator,
                                      peerStatic: responderStatic, handshakeHash: state.h))
    }
}

/// The Mac's side. It learns the phone's static key from message 1 and only
/// then picks the PSK for it.
public struct NoiseResponder {
    private var state: NoiseSymmetricState
    private let staticKey: Curve25519.KeyAgreement.PrivateKey
    private let ephemeral: Curve25519.KeyAgreement.PrivateKey
    private var initiatorEphemeral = Data()
    public private(set) var initiatorStatic = Data()

    public init(
        prologue: Data,
        staticKey: Curve25519.KeyAgreement.PrivateKey,
        ephemeral: Curve25519.KeyAgreement.PrivateKey = .init()
    ) {
        state = NoiseSymmetricState(protocolName: RelayNoise.protocolName)
        state.mixHash(prologue)
        state.mixHash(staticKey.publicKey.rawRepresentation)
        self.staticKey = staticKey
        self.ephemeral = ephemeral
    }

    /// Reads `-> e, es, s, ss`; returns the phone's payload. `initiatorStatic`
    /// is set afterwards.
    public mutating func readMessage1(_ message: Data) throws -> Data {
        guard message.count >= dhLength + dhLength + 16 + 16 else { throw RelayNoise.Failure.malformedMessage }
        let re = Data(message.prefix(dhLength))
        state.mixHash(re)
        state.mixKey(re)
        state.mixKey(try dh(staticKey, re)) // es
        let encryptedStatic = message.dropFirst(dhLength).prefix(dhLength + 16)
        let rs = try state.decryptAndHash(Data(encryptedStatic))
        state.mixKey(try dh(staticKey, rs)) // ss
        let payload = try state.decryptAndHash(Data(message.dropFirst(dhLength + dhLength + 16)))
        initiatorEphemeral = re
        initiatorStatic = rs
        return payload
    }

    /// `<- e, ee, se, psk` with `payload`, under the PSK chosen for
    /// `initiatorStatic`.
    public mutating func writeMessage2(payload: Data, psk: Data) throws -> (message: Data, session: NoiseSession) {
        guard psk.count == 32, initiatorEphemeral.count == dhLength else { throw RelayNoise.Failure.badKey }
        let e = ephemeral.publicKey.rawRepresentation
        var out = e
        state.mixHash(e)
        state.mixKey(e)
        state.mixKey(try dh(ephemeral, initiatorEphemeral)) // ee
        state.mixKey(try dh(ephemeral, initiatorStatic))    // se
        state.mixKeyAndHash(psk)
        out += try state.encryptAndHash(payload)
        let (toResponder, toInitiator) = state.split()
        return (out, NoiseSession(send: toInitiator, receive: toResponder,
                                  peerStatic: initiatorStatic, handshakeHash: state.h))
    }
}
