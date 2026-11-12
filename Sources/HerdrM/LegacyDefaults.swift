import Foundation

/// Herdrm's bundle id changed from dev.bybee.herdrm to sb.moe.herdrm in
/// 0.7.0, and with it the preferences domain. The first launch under the new
/// id copies the old domain's settings over (devices, layout, Sparkle's
/// choices), without overwriting anything the new domain already has.
/// Keychain items move separately (`KeychainServiceMigration`).
enum LegacyDefaults {
    static let legacyDomain = "dev.bybee.herdrm"
    static let migratedKey = "migration.legacyDefaultsDomain"

    static func migrate(
        _ defaults: UserDefaults = .standard,
        bundleID: String? = Bundle.main.bundleIdentifier,
        from legacy: String = legacyDomain
    ) {
        guard let bundleID, bundleID != legacy, !defaults.bool(forKey: migratedKey) else { return }
        let current = defaults.persistentDomain(forName: bundleID) ?? [:]
        for (key, value) in defaults.persistentDomain(forName: legacy) ?? [:] where current[key] == nil {
            defaults.set(value, forKey: key)
        }
        defaults.set(true, forKey: migratedKey)
    }
}

enum LaunchEnvironment {
    /// Running as the host of HerdrMTests rather than as the app.
    static let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
}
