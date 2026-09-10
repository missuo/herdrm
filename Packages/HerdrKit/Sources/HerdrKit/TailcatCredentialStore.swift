import Foundation
import Security

/// Keychain storage for tailcat tunnel tokens, keyed by device id. A token is
/// a bearer credential — anyone holding it can drive the exposed herdr — so
/// it never touches devices.json; only the Keychain holds it.
public enum TailcatCredentialStore {
    static let service = "dev.bybee.herdrm.tailcat-token"

    public static func token(for deviceID: UUID) throws -> String? {
        var query = baseQuery(deviceID: deviceID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw HerdrError.tunnelFailed("Keychain read failed (\(status))")
        }
    }

    public static func setToken(_ token: String, for deviceID: UUID) throws {
        let data = Data(token.utf8)
        var query = baseQuery(deviceID: deviceID)
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(query as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw HerdrError.tunnelFailed("Keychain write failed (\(status))")
        }
    }

    public static func removeToken(for deviceID: UUID) {
        SecItemDelete(baseQuery(deviceID: deviceID) as CFDictionary)
    }

    private static func baseQuery(deviceID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: deviceID.uuidString,
        ]
    }
}
