#if os(iOS)
import AppIntents

struct OpenClipHistory: AppIntent {
    static let title: LocalizedStringResource = "Open clipboard history"
    static let openAppWhenRun = true
    static let request = Notification.Name("ClipRelay.OpenHistory")

    @MainActor func perform() async throws -> some IntentResult {
        UserDefaults.standard.set(true, forKey: "phone.openHistory")
        NotificationCenter.default.post(name: Self.request, object: nil)
        return .result()
    }
}

struct PhoneShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenClipHistory(), phrases: ["Open history in \(.applicationName)"],
                    shortTitle: "Open clipboard history", systemImageName: "list.clipboard")
    }
}
#endif
