#if os(macOS)
import Foundation
import Security

/// Herdrm's Keychain items were named after its old bundle id
/// (dev.bybee.herdrm.*). This moves each one to the current name: it reads
/// the old item, adds it under the new service with the same accessibility,
/// and deletes the old one. Reading an item the old app created may ask once;
/// the copy belongs to this app, so later reads don't ask.
public enum KeychainServiceMigration {
    /// Old service → new service, for every store that used the old prefix.
    public static let renames: [(from: String, to: String)] = [
        ("dev.bybee.herdrm.relay", RelayKeychain.defaultService),
        ("dev.bybee.herdrm.ssh-password", SSHCredentialStore.passwordService),
        ("dev.bybee.herdrm.ssh-authorization", SSHCredentialStore.authorizationService),
        ("dev.bybee.herdrm.tailcat-token", TailcatCredentialStore.service),
        ("dev.bybee.herdrm.tailcat-client-key", TailcatClientKeyStore.service),
    ]

    public static let migratedKey = "migration.legacyKeychainServices"

    /// Moves every item once per install. Items that could not be read stay
    /// under the old name and are tried again at the next launch.
    public static func migrateIfNeeded(_ defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: migratedKey) else { return }
        var complete = true
        for rename in renames where !move(from: rename.from, to: rename.to) { complete = false }
        if complete { defaults.set(true, forKey: migratedKey) }
    }

    /// Moves every generic password under `old` to `new`. An account that
    /// already exists under `new` keeps the new copy. True when nothing is
    /// left under `old`.
    @discardableResult
    public static func move(from old: String, to new: String) -> Bool {
        var done = true
        for (account, accessible) in accounts(service: old) {
            guard let data = data(service: old, account: account) else {
                done = false
                continue
            }
            var item = query(service: new, account: account)
            item[kSecValueData as String] = data
            if let accessible { item[kSecAttrAccessible as String] = accessible }
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess || added == errSecDuplicateItem else {
                done = false
                continue
            }
            SecItemDelete(query(service: old, account: account) as CFDictionary)
        }
        return done
    }

    private static func accounts(service: String) -> [(String, CFString?)] {
        var search: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(search as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]]
        else { return [] }
        return items.compactMap { attributes in
            guard let account = attributes[kSecAttrAccount as String] as? String else { return nil }
            return (account, (attributes[kSecAttrAccessible as String] as? String).map { $0 as CFString })
        }
    }

    private static func data(service: String, account: String) -> Data? {
        var search = query(service: service, account: account)
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(search as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private static func query(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
#endif
