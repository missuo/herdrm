import CryptoKit
import Foundation

/// What an SSH private key file is (type, fingerprint, encrypted or not),
/// read without decrypting it: the OpenSSH format keeps its public half in the
/// clear. Herdrm on iPhone checks imported keys with it.
public enum SSHPrivateKeyFile {
    public enum Kind: String, Codable, Sendable {
        case ed25519, ecdsa, rsa, other

        public var label: String {
            switch self {
            case .ed25519: return "Ed25519"
            case .ecdsa: return "ECDSA"
            case .rsa: return "RSA"
            case .other: return String(localized: "Private key")
            }
        }
    }

    public struct Summary: Equatable, Sendable {
        public var kind: Kind
        public var fingerprint: String?
        public var encrypted: Bool
    }

    public enum Problem: LocalizedError, Equatable {
        case publicKey
        case putty
        case unrecognized

        public var errorDescription: String? {
            switch self {
            case .publicKey: return String(localized: "That's a public key. Paste the private key: the file without .pub, starting with -----BEGIN.")
            case .putty: return String(localized: "PuTTY .ppk keys aren't supported. Convert it with: puttygen key.ppk -O private-openssh -o key")
            case .unrecognized: return String(localized: "This doesn't look like an SSH private key.")
            }
        }
    }

    public static func summarize(_ text: String) throws -> Summary {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("ssh-") || trimmed.hasPrefix("ecdsa-") { throw Problem.publicKey }
        if trimmed.hasPrefix("PuTTY-User-Key-File") { throw Problem.putty }
        if let body = block(trimmed, "OPENSSH PRIVATE KEY") {
            return try openSSH(body)
        }
        for (label, kind) in [("RSA PRIVATE KEY", Kind.rsa), ("EC PRIVATE KEY", .ecdsa),
                              ("PRIVATE KEY", .other), ("ENCRYPTED PRIVATE KEY", .other)] {
            if block(trimmed, label) != nil {
                let encrypted = label.hasPrefix("ENCRYPTED") || trimmed.contains("Proc-Type: 4,ENCRYPTED")
                return Summary(kind: kind, fingerprint: nil, encrypted: encrypted)
            }
        }
        throw Problem.unrecognized
    }

    /// The base64 body between `-----BEGIN label-----` and its END line.
    private static func block(_ text: String, _ label: String) -> Data? {
        let begin = "-----BEGIN \(label)-----", end = "-----END \(label)-----"
        guard let b = text.range(of: begin), let e = text.range(of: end, range: b.upperBound..<text.endIndex) else { return nil }
        let inner = text[b.upperBound..<e.lowerBound]
            .split(whereSeparator: \.isNewline)
            .filter { !$0.contains(":") } // PEM headers (Proc-Type, DEK-Info)
            .joined()
        return Data(base64Encoded: inner.trimmingCharacters(in: .whitespaces))
    }

    /// `openssh-key-v1`: magic, cipher, kdf, kdf options, key count, then the
    /// public key blob in the clear.
    private static func openSSH(_ data: Data) throws -> Summary {
        var reader = Reader(data)
        guard reader.bytes(15) == Data("openssh-key-v1\0".utf8),
              let cipher = reader.string(), reader.string() != nil, reader.string() != nil,
              reader.uint32() != nil, let blob = reader.string()
        else { throw Problem.unrecognized }
        var blobReader = Reader(blob)
        let type = blobReader.string().map { String(decoding: $0, as: UTF8.self) } ?? ""
        let kind: Kind = type == "ssh-ed25519" ? .ed25519
            : type.hasPrefix("ecdsa-") ? .ecdsa : type == "ssh-rsa" ? .rsa : .other
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: "")
        return Summary(kind: kind, fingerprint: "SHA256:" + digest,
                       encrypted: String(decoding: cipher, as: UTF8.self) != "none")
    }

    private struct Reader {
        let data: Data
        var offset = 0
        init(_ data: Data) { self.data = Data(data) }

        mutating func bytes(_ n: Int) -> Data? {
            guard n >= 0, offset + n <= data.count else { return nil }
            defer { offset += n }
            return data.subdata(in: offset..<offset + n)
        }

        mutating func uint32() -> UInt32? {
            bytes(4).map { $0.reduce(0) { $0 << 8 | UInt32($1) } }
        }

        mutating func string() -> Data? {
            guard let n = uint32(), n < 1 << 20 else { return nil }
            return bytes(Int(n))
        }
    }
}
