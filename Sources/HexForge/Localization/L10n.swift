import Foundation

/// Languages the interface can be rendered in. English is the source language.
enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    var id: String { rawValue }

    /// Name shown in the Language menu, always written in its own script.
    var endonym: String {
        switch self {
        case .english: return "English"
        case .simplifiedChinese: return "中文"
        }
    }
}

/// Runtime, in-app localization.
///
/// The app is assembled from a bare SwiftPM executable with no `.lproj` resource
/// bundle to lean on, so user-facing text is resolved at render time against
/// `L10n.zh` and keyed by its English source text. A missing entry falls back to
/// English instead of surfacing a raw key, which keeps the app usable even if a
/// translation is overlooked.
enum L10n {

    /// Mirrors `AppState.language`. Set it before asking for any string.
    static var language: AppLanguage = .english

    private static let defaultsKey = "HexForge.Language"
    /// One-time marker: 1.1.0 onward ships with an English interface.
    private static let englishResetKey = "HexForge.LanguageReset.1_1_0"

    static func savedLanguage() -> AppLanguage {
        // The interface language was switched to English for this release.
        // Clear whatever was persisted earlier exactly once, so a manual
        // choice made afterwards still sticks.
        if !UserDefaults.standard.bool(forKey: englishResetKey) {
            UserDefaults.standard.set(true, forKey: englishResetKey)
            UserDefaults.standard.set(AppLanguage.english.rawValue, forKey: defaultsKey)
            return .english
        }
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
              let saved = AppLanguage(rawValue: raw) else { return .english }
        return saved
    }

    static func persist(_ language: AppLanguage) {
        UserDefaults.standard.set(language.rawValue, forKey: defaultsKey)
    }

    /// Translates an English literal, returning it unchanged for English or a
    /// missing entry.
    static func t(_ english: String) -> String {
        guard language != .english else { return english }
        return zh[english] ?? english
    }

    /// Translates an English format template and substitutes `args`. Use `%d` for
    /// integers and `%@` for strings; reach for positional forms such as `%1$@`
    /// and `%2$d` whenever Chinese word order differs from English.
    static func f(_ english: String, _ args: CVarArg...) -> String {
        String(format: t(english), arguments: args)
    }

    /// Translation tables, one per source-file group, merged into `zh`.
    static let tables: [[String: String]] = [
        zhApp, zhCore, zhPanels, zhFiles, zhDisk, zhAnalyze, zhServices, zhSweep
    ]

    static let zh: [String: String] = {
        var merged: [String: String] = [:]
        for table in tables { merged.merge(table) { current, _ in current } }
        return merged
    }()
}

/// Short alias used at every call site: `L.t("File")`, `L.f("Cursor: %d", n)`.
typealias L = L10n
