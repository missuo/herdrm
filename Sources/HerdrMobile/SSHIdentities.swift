import Foundation
import HerdrKit
import LocalAuthentication
import Security

/// An SSH private key the user imported ("Identities"), for servers reached
/// directly by IP or hostname. Only metadata lives here; the key and its
/// passphrase are in the Keychain (`SSHIdentityStore`).
struct SSHIdentity: Codable, Identifiable, Hashable {
    typealias Kind = SSHPrivateKeyFile.Kind

    var id: UUID
    var name: String
    var kind: Kind
    /// `SHA256:…` as `ssh-keygen -l` prints it, when the file carries its
    /// public half (OpenSSH format always does, even when encrypted).
    var fingerprint: String?
    var hasPassphrase: Bool
    /// Face ID / passcode before the key can be used.
    var requiresAuthentication: Bool
    var addedAt: Date
}

/// The identity list (metadata, UserDefaults) and its secrets (Keychain).
///
/// The key and passphrase are stored this-device-only: never in iCloud
/// Keychain, backups that leave the device, or another phone. With
/// `requiresAuthentication` the Keychain itself demands Face ID / passcode
/// before handing them out. The app never shows, exports or logs a key after
/// import; only its fingerprint.
@MainActor
final class SSHIdentityStore {
    static let shared = SSHIdentityStore()

    private static let listKey = "sshIdentities.v1"
    private static let service = "dev.bybee.herdrm.ios.identity"
    private static let lastUsedKey = "sshIdentities.lastUsed.v1"

    /// One Face ID covers the keys a connection tries, and a reconnect soon
    /// after, instead of one prompt per key.
    private var context: LAContext = {
        let c = LAContext()
        c.touchIDAuthenticationAllowableReuseDuration = 120
        return c
    }()

    private(set) var identities: [SSHIdentity] = []

    private init() {
        identities = (UserDefaults.standard.data(forKey: Self.listKey))
            .flatMap { try? JSONDecoder().decode([SSHIdentity].self, from: $0) } ?? []
    }

    private func saveList() {
        if let data = try? JSONEncoder().encode(identities) {
            UserDefaults.standard.set(data, forKey: Self.listKey)
        }
    }

    func identity(_ id: UUID) -> SSHIdentity? { identities.first { $0.id == id } }

    enum StoreError: LocalizedError {
        case keychain(OSStatus)
        case passcodeRequired

        var errorDescription: String? {
            switch self {
            case .passcodeRequired:
                return String(localized: "Requiring Face ID needs a passcode on this device. Set one in Settings, or turn the option off.")
            case .keychain(let status):
                return String(localized: "Couldn't save the key in the Keychain (\(Int(status))).")
            }
        }
    }

    /// Validates and stores a key. Throws for anything that isn't a usable
    /// private key file.
    @discardableResult
    func add(name: String, keyText: String, passphrase: String?, requiresAuthentication: Bool) throws -> SSHIdentity {
        let summary = try SSHPrivateKeyFile.summarize(keyText)
        let id = UUID()
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let identity = SSHIdentity(
            id: id,
            name: trimmedName.isEmpty ? "\(summary.kind.label) key" : trimmedName,
            kind: summary.kind, fingerprint: summary.fingerprint,
            hasPassphrase: !(passphrase ?? "").isEmpty || summary.encrypted,
            requiresAuthentication: requiresAuthentication, addedAt: Date())
        let normalized = keyText.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        try store(Data(normalized.utf8), account: "\(id.uuidString).key", protected: requiresAuthentication)
        if let passphrase, !passphrase.isEmpty {
            do {
                try store(Data(passphrase.utf8), account: "\(id.uuidString).passphrase", protected: requiresAuthentication)
            } catch {
                delete(account: "\(id.uuidString).key")
                throw error
            }
        }
        identities.append(identity)
        saveList()
        return identity
    }

    func rename(_ id: UUID, to name: String) {
        guard let i = identities.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        identities[i].name = trimmed
        saveList()
    }

    func remove(_ id: UUID) {
        delete(account: "\(id.uuidString).key")
        delete(account: "\(id.uuidString).passphrase")
        identities.removeAll { $0.id == id }
        saveList()
        var used = lastUsed
        for (device, identity) in used where identity == id.uuidString { used[device] = nil }
        UserDefaults.standard.set(used, forKey: Self.lastUsedKey)
    }

    /// The key file and passphrase, for one sign-in. May show Face ID.
    func secret(for identity: SSHIdentity, reason: String) throws -> (key: Data, passphrase: String?) {
        context.localizedReason = reason
        let key = try read(account: "\(identity.id.uuidString).key")
        let passphrase = try? read(account: "\(identity.id.uuidString).passphrase")
        return (key, passphrase.map { String(decoding: $0, as: UTF8.self) })
    }

    // MARK: Automatic choice

    private var lastUsed: [String: String] {
        UserDefaults.standard.dictionary(forKey: Self.lastUsedKey) as? [String: String] ?? [:]
    }

    /// The key that last worked for `deviceID` first, then the rest newest
    /// first (OpenSSH's order is the file order; newest is a better guess).
    func candidates(for deviceID: UUID) -> [SSHIdentity] {
        let preferred = lastUsed[deviceID.uuidString].flatMap(UUID.init(uuidString:))
        let sorted = identities.sorted { $0.addedAt > $1.addedAt }
        guard let preferred, let first = sorted.first(where: { $0.id == preferred }) else { return sorted }
        return [first] + sorted.filter { $0.id != preferred }
    }

    func lastWorked(for deviceID: UUID) -> UUID? {
        lastUsed[deviceID.uuidString].flatMap(UUID.init(uuidString:))
    }

    func noteWorked(_ identity: SSHIdentity, for deviceID: UUID) {
        var used = lastUsed
        used[deviceID.uuidString] = identity.id.uuidString
        UserDefaults.standard.set(used, forKey: Self.lastUsedKey)
    }

    // MARK: Keychain

    private func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: kCFBooleanFalse!]
    }

    private func store(_ data: Data, account: String, protected: Bool) throws {
        delete(account: account)
        var query = base(account)
        query[kSecValueData as String] = data
        if protected {
            var error: Unmanaged<CFError>?
            guard let access = SecAccessControlCreateWithFlags(
                nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .userPresence, &error)
            else { throw StoreError.keychain(errSecParam) }
            query[kSecAttrAccessControl as String] = access
        } else {
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            if protected, status == errSecParam || status == errSecNotAvailable || status == -25293 {
                throw StoreError.passcodeRequired
            }
            throw StoreError.keychain(status)
        }
    }

    private func read(account: String) throws -> Data {
        var query = base(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext as String] = context
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { throw StoreError.keychain(status) }
        return data
    }

    private func delete(account: String) {
        SecItemDelete(base(account) as CFDictionary)
    }
}
