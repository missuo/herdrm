import AppKit
import Darwin
import Foundation
import HerdrKit

/// In-app language override. `AppleLanguages` is cached at process start, and
/// `String(localized:)` / menus / notifications do not follow a SwiftUI
/// `.environment(\.locale)` swap, so a change only takes effect in a new process.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    static let defaultsKey = "app.language"

    var id: String { rawValue }

    /// Localizations herdrm ships. Used to resolve a picker value (including
    /// Follow System) to the code `Bundle.main` would actually load.
    static let bundledLocalizations = ["en", "zh-Hans"]

    /// Effective localization this process is showing. Snapshotted at launch
    /// because `AppleLanguages` does not update `Bundle.main` until the next start.
    private(set) static var runningCode = "en"

    /// Native names for concrete languages; "Follow System" is the only
    /// option that is translated. English and Simplified Chinese keep their
    /// endonym from the catalog in every locale.
    var displayName: String {
        switch self {
        case .system:
            return String(localized: "Follow System")
        case .english:
            return String(localized: "language.name.en", defaultValue: "English")
        case .simplifiedChinese:
            return String(localized: "language.name.zh-Hans", defaultValue: "Chinese")
        }
    }

    static func current(defaults: UserDefaults = .standard) -> AppLanguage {
        AppLanguage(rawValue: defaults.string(forKey: defaultsKey) ?? "") ?? .system
    }

    static func apply(_ language: AppLanguage, defaults: UserDefaults = .standard) {
        defaults.set(language.rawValue, forKey: defaultsKey)
        switch language {
        case .system:
            defaults.removeObject(forKey: "AppleLanguages")
        case .english:
            defaults.set(["en"], forKey: "AppleLanguages")
        case .simplifiedChinese:
            defaults.set(["zh-Hans"], forKey: "AppleLanguages")
        }
    }

    static func synchronize(defaults: UserDefaults = .standard) {
        apply(current(defaults: defaults), defaults: defaults)
        runningCode = canonicalize(Bundle.main.preferredLocalizations.first ?? "en")
    }

    /// True only when relaunching would change the strings on screen. English →
    /// Follow System is a no-op if the Mac is already English.
    static func needsRelaunch(
        _ selection: AppLanguage,
        running: String = runningCode,
        systemLanguages: [String] = systemPreferredLanguages()
    ) -> Bool {
        effectiveCode(for: selection, systemLanguages: systemLanguages) != canonicalize(running)
    }

    static func effectiveCode(for language: AppLanguage, systemLanguages: [String]) -> String {
        let preferences: [String]
        switch language {
        case .english:
            preferences = ["en"]
        case .simplifiedChinese:
            preferences = ["zh-Hans"]
        case .system:
            preferences = systemLanguages
        }
        return Bundle.preferredLocalizations(
            from: bundledLocalizations,
            forPreferences: preferences
        ).first ?? "en"
    }

    /// System language list, not the app-domain `AppleLanguages` override this
    /// process may already have written.
    static func systemPreferredLanguages() -> [String] {
        if let languages = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"] as? [String],
           !languages.isEmpty {
            return languages
        }
        return Locale.preferredLanguages
    }

    static func canonicalize(_ code: String) -> String {
        Bundle.preferredLocalizations(
            from: bundledLocalizations,
            forPreferences: [code]
        ).first ?? "en"
    }

    /// Flush `AppleLanguages`, then quit through the usual terminate path so SSH
    /// tunnels tear down. A detached helper waits for this pid to vanish and
    /// reopens the bundle — two live herdrm processes would duplicate the device tree.
    @MainActor
    static func relaunch() {
        UserDefaults.standard.synchronize()
        if spawnRelaunchHelper() != nil {
            NSApp.terminate(nil)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            DispatchQueue.main.async {
                guard error == nil else { return }
                NSApp.terminate(nil)
            }
        }
    }

    static func relaunchHelperCommand(pid: pid_t, bundlePath: String) -> String {
        "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.1; done; exec /usr/bin/open \(ShellQuoting.quoted(bundlePath))"
    }

    private static func spawnRelaunchHelper() -> pid_t? {
        let argvStrings = [
            "/bin/sh",
            "-c",
            relaunchHelperCommand(
                pid: ProcessInfo.processInfo.processIdentifier,
                bundlePath: Bundle.main.bundlePath
            ),
        ]
        let envStrings = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }
        return withCStrings(argvStrings) { argv in
            withCStrings(envStrings) { envp in
                var actions: posix_spawn_file_actions_t?
                guard posix_spawn_file_actions_init(&actions) == 0 else { return nil }
                defer { posix_spawn_file_actions_destroy(&actions) }
                _ = posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
                _ = posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0)
                _ = posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)

                var attr: posix_spawnattr_t?
                guard posix_spawnattr_init(&attr) == 0 else { return nil }
                defer { posix_spawnattr_destroy(&attr) }
                // New session so the waiter is not SIGHUP'd when herdrm exits.
                posix_spawnattr_setflags(&attr, Int16(bitPattern: UInt16(POSIX_SPAWN_SETSID)))

                var pid: pid_t = 0
                let spawned = posix_spawn(&pid, "/bin/sh", &actions, &attr, argv, envp)
                return spawned == 0 ? pid : nil
            }
        }
    }

    private static func withCStrings<R>(
        _ values: [String],
        _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> R
    ) -> R {
        var pointers: [UnsafeMutablePointer<CChar>?] = values.map { strdup($0) }
        pointers.append(nil)
        defer {
            for pointer in pointers { free(pointer) }
        }
        return pointers.withUnsafeMutableBufferPointer { buffer in
            body(buffer.baseAddress!)
        }
    }
}

extension Device {
    var localizedSubtitle: String {
        switch kind {
        case .local:
            return String(localized: "This Mac · herdr.sock")
        case .ssh(let target):
            return String(localized: "\(target) · SSH")
        case .tailcat:
            return String(localized: "tailcat tunnel")
        }
    }
}
