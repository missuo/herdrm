import CryptoKit
import Foundation
import Security

/// Secrets for the relay (keys and pairing PSKs), as generic passwords in the
/// login / app Keychain, readable only after first unlock on this device.
public struct RelayKeychain: Sendable {
    public let service: String

    public init(service: String = "dev.bybee.herdrm.relay") {
        self.service = service
    }

    public func data(_ account: String) -> Data? {
        var query = base(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    @discardableResult
    public func set(_ data: Data, for account: String) -> Bool {
        SecItemDelete(base(account) as CFDictionary)
        var query = base(account)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    public func remove(_ account: String) {
        SecItemDelete(base(account) as CFDictionary)
    }

    private func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// The X25519 key stored under `account`, created on first use.
    public func agreementKey(_ account: String) -> Curve25519.KeyAgreement.PrivateKey {
        if let raw = data(account), let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw) {
            return key
        }
        let key = Curve25519.KeyAgreement.PrivateKey()
        set(key.rawRepresentation, for: account)
        return key
    }

    /// The Ed25519 key stored under `account`, created on first use.
    public func signingKey(_ account: String) -> Curve25519.Signing.PrivateKey {
        if let raw = data(account), let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) {
            return key
        }
        let key = Curve25519.Signing.PrivateKey()
        set(key.rawRepresentation, for: account)
        return key
    }
}
