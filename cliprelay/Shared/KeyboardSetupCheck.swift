import Foundation

enum KeyboardSetupCheck {
    enum Access { case limited, full }

    static func challenge() -> String { "ClipRelaySetup-" + UUID().uuidString }

    static func response(to challenge: String, fullAccess: Bool) -> String {
        challenge + (fullAccess ? ".full" : ".limited")
    }

    static func result(from text: String, for challenge: String) -> Access? {
        switch text {
        case response(to: challenge, fullAccess: true): return .full
        case response(to: challenge, fullAccess: false): return .limited
        default: return nil
        }
    }

    #if os(iOS)
    private static var challengeFile: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.cc.macseek.cliprelay")?
            .appendingPathComponent("KeyboardSetupCheck")
    }

    static var activeChallenge: String? {
        guard let challengeFile else { return nil }
        return try? String(contentsOf: challengeFile, encoding: .utf8)
    }

    static func activate(_ challenge: String) -> Bool {
        guard let challengeFile else { return false }
        do {
            try Data(challenge.utf8).write(to: challengeFile, options: .atomic)
            return true
        } catch { return false }
    }

    static func clear(_ challenge: String) {
        guard let challengeFile, activeChallenge == challenge else { return }
        try? FileManager.default.removeItem(at: challengeFile)
    }
    #endif
}
