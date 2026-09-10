import Foundation
import Security

/// A Mac (or other host) running herdr, reached over SSH or through the
/// herdr.tailcat plugin's tunnel. Unlike the Mac app there is no "Local"
/// device — the phone always talks to a remote herdr. Secrets never live
/// here: SSH passwords and tailcat tokens go to the Keychain keyed by `id`.
struct MobileDevice: Codable, Identifiable, Hashable {
    enum Kind: String, Codable, CaseIterable {
        case ssh
        /// Control plane only on iOS: the tunnel carries the herdr API and
        /// client sockets but no shell, so terminal attach stays SSH-only.
        case tailcat
    }

    enum AuthMethod: String, Codable, CaseIterable {
        /// This phone's Ed25519 key, enrolled in the host's authorized_keys.
        case deviceKey
        case password
    }

    var id: UUID
    var kind: Kind
    var name: String
    var host: String
    var port: UInt16
    var username: String
    var authMethod: AuthMethod
    /// Socket path override; nil means ~/.config/herdr/herdr.sock on the host.
    var socketPath: String?

    init(
        id: UUID = UUID(),
        kind: Kind = .ssh,
        name: String,
        host: String = "",
        port: UInt16 = 22,
        username: String = "",
        authMethod: AuthMethod = .deviceKey,
        socketPath: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.authMethod = authMethod
        self.socketPath = socketPath
    }

    /// Devices stored before the tailcat kind existed decode as SSH.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .ssh
        name = try container.decode(String.self, forKey: .name)
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? ""
        port = try container.decodeIfPresent(UInt16.self, forKey: .port) ?? 22
        username = try container.decodeIfPresent(String.self, forKey: .username) ?? ""
        authMethod = try container.decodeIfPresent(AuthMethod.self, forKey: .authMethod) ?? .deviceKey
        socketPath = try container.decodeIfPresent(String.self, forKey: .socketPath)
    }

    var isTailcat: Bool { kind == .tailcat }

    var subtitle: String {
        switch kind {
        case .ssh:
            return port == 22 ? "\(username)@\(host)" : "\(username)@\(host):\(port)"
        case .tailcat:
            return String(localized: "Tailcat tunnel")
        }
    }
}

/// Persists the device list as a versioned JSON envelope in UserDefaults.
@MainActor
final class MobileDeviceStore {
    private static let key = "devices.v1"
    private struct Envelope: Codable {
        var version: Int
        var devices: [MobileDevice]
    }

    func load() -> [MobileDevice] {
        guard let data = UserDefaults.standard.data(forKey: Self.key),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data)
        else { return [] }
        return envelope.devices
    }

    func save(_ devices: [MobileDevice]) {
        let envelope = Envelope(version: 1, devices: devices)
        if let data = try? JSONEncoder().encode(envelope) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}

/// Keychain-backed secrets, this-device-only: SSH passwords keyed by device id.
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` deliberately keeps them
/// out of iCloud Keychain and device-to-device migration.
enum MobileSecretStore {
    private static let service = "dev.bybee.herdrm.ios.ssh"

    static func password(for deviceID: UUID) -> String? {
        var query = baseQuery(deviceID: deviceID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func setPassword(_ password: String, for deviceID: UUID) {
        let data = Data(password.utf8)
        var query = baseQuery(deviceID: deviceID)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        guard status == errSecItemNotFound else { return }
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(query as CFDictionary, nil)
    }

    static func removePassword(for deviceID: UUID) {
        SecItemDelete(baseQuery(deviceID: deviceID) as CFDictionary)
    }

    private static func baseQuery(deviceID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "host-password-\(deviceID.uuidString)",
        ]
    }
}

/// Trust-on-first-use host key pinning, keyed host:port + algorithm so several
/// host-key algorithms per endpoint are trusted independently.
enum KnownHostsStore {
    private static let key = "knownHostFingerprints.v1"

    static func fingerprint(host: String, port: UInt16, algorithm: String) -> String? {
        store()["\(host):\(port)|\(algorithm)"]
    }

    static func pin(host: String, port: UInt16, algorithm: String, fingerprint: String) {
        var map = store()
        map["\(host):\(port)|\(algorithm)"] = fingerprint
        UserDefaults.standard.set(map, forKey: key)
    }

    static func unpin(host: String, port: UInt16) {
        var map = store()
        for entryKey in map.keys where entryKey.hasPrefix("\(host):\(port)|") {
            map.removeValue(forKey: entryKey)
        }
        UserDefaults.standard.set(map, forKey: key)
    }

    private static func store() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
    }
}
