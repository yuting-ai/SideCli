import Foundation

enum AppPreferences {
    static let languageKey = "sidecli.language"
    static let languageDefault = AppLanguage.english.rawValue

    static func language() -> AppLanguage {
        let raw = (UserDefaults.standard.object(forKey: languageKey) as? String) ?? languageDefault
        return AppLanguage(rawValue: raw) ?? .english
    }

    static func bootstrapLanguageIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: languageKey) == nil else { return }
        defaults.set(languageDefault, forKey: languageKey)
    }
}
