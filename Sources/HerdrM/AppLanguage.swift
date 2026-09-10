import Foundation
import HerdrKit

/// In-app language override. `AppleLanguages` is read at process start, so a
/// change here only takes effect after the user quits and reopens herdrm.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    static let defaultsKey = "app.language"

    var id: String { rawValue }

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
