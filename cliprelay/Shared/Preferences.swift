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

    static var paused: Bool { defaults.double(forKey: "clipboard.pauseUntil") > Date.now.timeIntervalSince1970 }
    #if os(iOS)
    static let phoneCaptureKey = "phone.captureVersion"
    static let keyboardCaptureKey = "keyboard.pasteboardVersion"
    static var phoneCapturesClipboard: Bool { defaults.bool(forKey: "phone.foregroundCapture") }

    static func setPhoneCapture(_ enabled: Bool, version: Int) {
        defaults.set(version, forKey: phoneCaptureKey)
        defaults.set(enabled, forKey: "phone.foregroundCapture")
    }

    static func updateCaptureBaselines(version: Int, pausing: Bool, store: UserDefaults = defaults) {
        for key in [phoneCaptureKey, keyboardCaptureKey] {
            store.set(version, forKey: key)
            store.set(pausing, forKey: key + ".resume")
        }
    }

    static func skipPausedCopy(version: Int, key: String, store: UserDefaults = defaults) -> Bool {
        let active = store.double(forKey: "clipboard.pauseUntil") > Date.now.timeIntervalSince1970
        guard active || store.bool(forKey: key + ".resume") else { return false }
        // iOS gives no copy timestamp after suspension. Discard the first observed value on resume.
        store.set(version, forKey: key)
        if !active { store.removeObject(forKey: key + ".resume") }
        return true
    }
    #endif
    static var historyLocked: Bool { defaults.bool(forKey: "phone.historyLock") }
    static var discoveryEnabled: Bool {
        #if os(macOS)
        defaults.object(forKey: "mac.lanDiscovery") as? Bool ?? true
        #else
        defaults.object(forKey: "phone.discovery") as? Bool ?? true
        #endif
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

enum MacHistoryPrivacy {
    static func isMasked(_ text: String, sensitive: Bool, codes: Bool, forDetail: Bool) -> Bool {
        let code = text.range(of: #"^\s*[0-9]{4,8}\s*$|(?:验证码|verification code|one.time code|\bOTP\b)[^0-9]{0,16}[0-9]{4,8}\b"#,
                              options: [.regularExpression, .caseInsensitive]) != nil
        if code { return codes || (sensitive && !forDetail) }
        return sensitive && !forDetail && text.range(
            of: #"(?:密码|口令|password|passcode|api[_ -]?key|access[_ -]?token)\s*[:：=]\s*\S+"#,
            options: [.regularExpression, .caseInsensitive]) != nil
    }
}
