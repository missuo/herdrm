import Foundation
import HerdrTailcat
import Security

/// This install's tailcat client identity: one node key, generated on first
/// use and kept in the Keychain, shared by every tailcat device. Its public
/// half ("nodekey:…") is what a host lists in the herdr.tailcat plugin's
/// allow.list (or `tailcat serve --allow`); without a persistent key every
/// session would get a fresh ephemeral one that an allowlisting host rejects.
///
/// The key stays in tailscale's own "privkey:" text form, opaque to Swift —
/// the embedded Go runtime generates, decodes, and derives the public key, so
/// the format always matches what `tailcat genkey --client` produces.
public enum TailcatClientKeyStore {
    static let service = "sb.moe.herdrm.tailcat-client-key"
    static let account = "client-key"

    /// The client key, generated and saved on first use. A stored key is
    /// returned as-is, even if damaged: replacing it silently would change the
    /// identity every allow list knows, so a bad key surfaces as a connect
    /// error instead and the user decides to regenerate.
    public static func ensure() throws -> String {
        if let existing = try load() { return existing }
        let key = try generate()
        switch add(key) {
        case errSecSuccess:
            return key
        case errSecDuplicateItem:
            // Another caller generated one first (two devices connecting at
            // once); use theirs so both bridges share one identity.
            if let existing = try load() { return existing }
            throw HerdrError.tailcatBridgeFailed("tailcat client key vanished from the Keychain")
        case let status:
            throw HerdrError.tailcatBridgeFailed("Keychain write failed (\(status))")
        }
    }

    /// The "nodekey:" public key to add to a host's allow list.
    public static func publicKey() throws -> String {
        try publicKey(of: ensure())
    }

    /// Replaces the client key with a fresh one and returns its public key.
    /// Live bridges keep the old identity until restarted; the caller
    /// reconnects them. Every host's allow list needs the new public key.
    @discardableResult
    public static func regenerate() throws -> String {
        let key = try generate()
        let update: [String: Any] = [kSecValueData as String: Data(key.utf8)]
        var status = SecItemUpdate(baseQuery() as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound { status = add(key) }
        guard status == errSecSuccess else {
            throw HerdrError.tailcatBridgeFailed("Keychain write failed (\(status))")
        }
        return try publicKey(of: key)
    }

    private static func generate() throws -> String {
        do {
            return try TailcatBridge.generateClientKey()
        } catch {
            throw HerdrError.tailcatBridgeFailed(error.localizedDescription)
        }
    }

    private static func publicKey(of key: String) throws -> String {
        do {
            return try TailcatBridge.publicKey(ofClientKey: key)
        } catch {
            throw HerdrError.tailcatBridgeFailed(
                "the saved tailcat client key is unreadable (\(error.localizedDescription)) — regenerate it"
            )
        }
    }

    private static func load() throws -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return String(decoding: data, as: UTF8.self)
        case errSecItemNotFound:
            return nil
        default:
            throw HerdrError.tailcatBridgeFailed("Keychain read failed (\(status))")
        }
    }

    private static func add(_ key: String) -> OSStatus {
        var query = baseQuery()
        query[kSecValueData as String] = Data(key.utf8)
        // An identity of this install, not portable data: keep it out of
        // backups restored onto another device.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(query as CFDictionary, nil)
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
