import CryptoKit
import Foundation
import os
import Security

private let keyLog = Logger(subsystem: "sb.moe.herdrm-ios", category: "devicekey")

/// This phone's SSH identity: one Ed25519 key generated on device, private
/// bytes kept in the Keychain and never exported. Enrolling a Mac means
/// appending `authorizedKeysLine` to that Mac's ~/.ssh/authorized_keys.
enum DeviceKey {
    private static let service = "sb.moe.herdrm-ios.ssh"
    private static let account = "device-ed25519-private-key"

    static func ensure() -> Curve25519.Signing.PrivateKey {
        if let existing = load() { return existing }
        let key = Curve25519.Signing.PrivateKey()
        store(key)
        return key
    }

    private static func load() -> Curve25519.Signing.PrivateKey? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data)
        else {
            keyLog.error("device key load failed: \(status)")
            return nil
        }
        return key
    }

    private static func store(_ key: Curve25519.Signing.PrivateKey) {
        var query = baseQuery()
        query[kSecValueData as String] = key.rawRepresentation
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            keyLog.error("device key store failed: \(status)")
        }
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    // MARK: - SSH wire formats

    /// RFC 4253 §6.6 public key blob: string "ssh-ed25519" + string raw-key.
    static func publicKeyBlob(_ key: Curve25519.Signing.PrivateKey) -> Data {
        var blob = Data()
        appendString(&blob, Data("ssh-ed25519".utf8))
        appendString(&blob, key.publicKey.rawRepresentation)
        return blob
    }

    /// The line to append to a host's ~/.ssh/authorized_keys.
    static func authorizedKeysLine(_ key: Curve25519.Signing.PrivateKey, comment: String = "herdrm-ios") -> String {
        "ssh-ed25519 \(publicKeyBlob(key).base64EncodedString()) \(comment)"
    }

    private static func appendString(_ data: inout Data, _ payload: Data) {
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(payload)
    }
}
