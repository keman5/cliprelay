import Foundation

enum ClipRelayPreferences {
    static let locales = ["en", "zh-Hans", "zh-Hant", "ja", "ko", "de", "fr", "es"]
    static let defaults: UserDefaults = {
        #if os(iOS)
        return UserDefaults(suiteName: "group.cc.macseek.cliprelay") ?? .standard
        #else
        return .standard
        #endif
    }()

    static var language: String {
        get { defaults.string(forKey: "ui.language") ?? "system" }
        set { defaults.set(newValue, forKey: "ui.language") }
    }

    static var theme: String {
        get { defaults.string(forKey: "ui.theme") ?? "system" }
        set { defaults.set(newValue, forKey: "ui.theme") }
    }

    static var keyboardStartsWithClipboard: Bool {
        get { defaults.object(forKey: "keyboard.startsWithClipboard") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "keyboard.startsWithClipboard") }
    }

    static var keyboardCapturesClipboard: Bool {
        get { defaults.bool(forKey: "keyboard.capturesClipboard") }
        set { defaults.set(newValue, forKey: "keyboard.capturesClipboard") }
    }

    static var keyboardSendsClipboard: Bool {
        get { defaults.bool(forKey: "keyboard.sendsClipboard") }
        set { defaults.set(newValue, forKey: "keyboard.sendsClipboard") }
    }

    static var keyboardPasteboardVersion: Int? {
        get { defaults.object(forKey: "keyboard.pasteboardVersion") as? Int }
        set { defaults.set(newValue, forKey: "keyboard.pasteboardVersion") }
    }

    static func match(_ preferred: [String]) -> String {
        for tag in preferred {
            let code = tag.replacingOccurrences(of: "_", with: "-")
            let parts = code.lowercased().split(separator: "-")
            guard let base = parts.first else { continue }
            if base == "zh" {
                if parts.contains("hant") { return "zh-Hant" }
                if parts.contains("hans") { return "zh-Hans" }
                return parts.contains(where: { ["tw", "hk", "mo"].contains($0) }) ? "zh-Hant" : "zh-Hans"
            }
            if locales.contains(String(base)) { return String(base) }
        }
        return "en"
    }

    static var resolvedLanguage: String { language == "system" ? match(Locale.preferredLanguages) : match([language]) }

    static func localized(_ key: String) -> String {
        guard let path = Bundle.main.path(forResource: resolvedLanguage, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return key }
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }
}
