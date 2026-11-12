#if os(macOS)
import Foundation
import Security

public enum SSHCredentialStore {
    public static let askPassModeEnvironmentKey = "HERDRM_SSH_ASKPASS"
    public static let authorizationIDEnvironmentKey = "HERDRM_SSH_AUTHORIZATION_ID"
    public static let persistenceDescription = "Saved in your macOS login Keychain"

    static let passwordService = "sb.moe.herdrm.ssh-password"
    static let authorizationService = "sb.moe.herdrm.ssh-authorization"

    public static func password(for deviceID: UUID) throws -> String? {
        if let password = try keychainPassword(for: deviceID) { return password }

        // Migrate credentials written by the short-lived Debug file-store implementation.
        guard let legacyData = try legacyLocalData(directory: "passwords", id: deviceID) else {
            return nil
        }
        let password = try decodePassword(legacyData)
        try setKeychainPassword(password, for: deviceID)
        try removeLegacyLocalData(directory: "passwords", id: deviceID)
        return password
    }

    public static func setPassword(_ password: String, for deviceID: UUID) throws {
        guard !password.isEmpty else {
            try removePassword(for: deviceID)
            return
        }

        try setKeychainPassword(password, for: deviceID)
    }

    public static func removePassword(for deviceID: UUID) throws {
        try removeKeychainPassword(for: deviceID)
        try? removeLegacyLocalData(directory: "passwords", id: deviceID)
    }

    static func createAuthorization(for deviceID: UUID) throws -> UUID? {
        guard try password(for: deviceID) != nil else { return nil }
        let authorizationID = UUID()
        var item = keychainQuery(service: authorizationService, account: authorizationID.uuidString)
        item[kSecValueData as String] = Data(deviceID.uuidString.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw SSHCredentialStoreError(status: status) }
        return authorizationID
    }

    /// Drops grants stranded by a crash between creation and askpass consumption.
    public static func purgeAuthorizations() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: authorizationService,
        ]
        SecItemDelete(query as CFDictionary)
    }

    public static func consumePassword(authorizationID: UUID) throws -> String? {
        guard let authorization = try keychainData(
            service: authorizationService,
            account: authorizationID.uuidString
        ) else { return nil }
        defer { try? removeAuthorization(authorizationID) }
        guard let rawDeviceID = String(data: authorization, encoding: .utf8),
              let deviceID = UUID(uuidString: rawDeviceID)
        else { throw SSHCredentialStoreError(status: errSecDecode) }
        return try password(for: deviceID)
    }

    public static func removeAuthorization(_ authorizationID: UUID) throws {
        let status = SecItemDelete(
            keychainQuery(service: authorizationService, account: authorizationID.uuidString) as CFDictionary
        )
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SSHCredentialStoreError(status: status)
        }
        try? removeLegacyLocalData(directory: "authorizations", id: authorizationID)
    }

    private static func decodePassword(_ data: Data) throws -> String {
        guard let password = String(data: data, encoding: .utf8) else {
            throw SSHCredentialStoreError(status: errSecDecode)
        }
        return password
    }

    private static func keychainPassword(for deviceID: UUID) throws -> String? {
        guard let data = try keychainData(
            service: passwordService,
            account: deviceID.uuidString
        ) else { return nil }
        return try decodePassword(data)
    }

    private static func setKeychainPassword(_ password: String, for deviceID: UUID) throws {
        let passwordData = Data(password.utf8)
        let query = keychainQuery(service: passwordService, account: deviceID.uuidString)
        let attributes: [String: Any] = [
            kSecValueData as String: passwordData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw SSHCredentialStoreError(status: updateStatus)
        }

        var newItem = query
        newItem[kSecValueData as String] = passwordData
        newItem[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(newItem as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw SSHCredentialStoreError(status: addStatus) }
    }

    private static func removeKeychainPassword(for deviceID: UUID) throws {
        let status = SecItemDelete(
            keychainQuery(service: passwordService, account: deviceID.uuidString) as CFDictionary
        )
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SSHCredentialStoreError(status: status)
        }
    }

    private static func keychainData(service: String, account: String) throws -> Data? {
        var query = keychainQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw SSHCredentialStoreError(status: status) }
        guard let data = result as? Data else { throw SSHCredentialStoreError(status: errSecDecode) }
        return data
    }

    private static func keychainQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func legacyLocalData(directory: String, id: UUID) throws -> Data? {
        let url = legacyLocalURL(directory: directory, id: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    private static func removeLegacyLocalData(directory: String, id: UUID) throws {
        let url = legacyLocalURL(directory: directory, id: id)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }

        let root = url.deletingLastPathComponent().deletingLastPathComponent()
        let children = ["passwords", "authorizations"].map {
            root.appendingPathComponent($0, isDirectory: true)
        }
        for directory in children + [root] {
            guard (try? FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty) == true
            else { continue }
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private static func legacyLocalURL(directory: String, id: UUID) -> URL {
        let applicationSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let root = applicationSupport
            .appendingPathComponent("HerdrM", isDirectory: true)
            .appendingPathComponent("SSHCredentials", isDirectory: true)
        return root
            .appendingPathComponent(directory, isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: false)
    }
}

public struct SSHCredentialStoreError: LocalizedError, Sendable {
    public let status: OSStatus

    public var errorDescription: String? {
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return "could not access SSH password in Keychain: \(detail)"
    }
}#endif  // os(macOS)
