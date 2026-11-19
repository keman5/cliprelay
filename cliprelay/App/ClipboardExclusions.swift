#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum ClipboardExclusions {
    static let key = "clipboard.excludedApps"
    static let legacyKey = "clipboard.excludedBundles"

    private static let defaults = [
        (id: "com.apple.keychainaccess", name: "Keychain Access"),
        (id: "com.apple.passwords", name: "Passwords"),
        (id: "com.lunabee.sg.onesafemac", name: "oneSafe"),
        (id: "com.1password.1password", name: "1Password"),
        (id: "com.bitwarden.desktop", name: "Bitwarden"),
        (id: "org.keepassx.keepassxc", name: "KeePassXC"),
        (id: "com.markmcguill.strongbox", name: "Strongbox")
    ]

    private static func normalized(_ id: String) -> String {
        let id = id.lowercased()
        if id.hasPrefix("com.1password.") || id.hasPrefix("com.agilebits.") {
            return "com.1password.1password"
        }
        return id
    }

    static func ids(saved: String?, legacy: String?) -> [String] {
        func parse(_ text: String) -> [String] {
            text.split { $0.isWhitespace || $0 == "," }.map { normalized(String($0)) }
        }
        var seen = Set<String>()
        let ids = saved.map(parse) ?? (defaults.map(\.id) + parse(legacy ?? ""))
        return ids.filter { seen.insert($0).inserted }
    }

    static func contains(_ id: String, in exclusions: [String]) -> Bool {
        exclusions.contains(normalized(id))
    }

    @MainActor static func excludes(_ id: String, settings: UserDefaults) -> Bool {
        contains(id, in: ids(saved: settings.string(forKey: key), legacy: settings.string(forKey: legacyKey)))
    }

    @MainActor static func title(for id: String) -> String {
        let urls = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: id)
        if let app = urls.first {
            return FileManager.default.displayName(atPath: app.path)
        }
        return defaults.first { $0.id == id }?.name ?? id
    }

    static func adding(_ urls: [URL], to exclusions: [String]) -> [String] {
        var ids = exclusions
        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            guard let id = Bundle(url: url)?.bundleIdentifier, !contains(id, in: ids) else { continue }
            ids.append(normalized(id))
        }
        return ids
    }
}

struct ClipboardExclusionSettings: View {
    @AppStorage(ClipboardExclusions.key) private var stored: String?
    @AppStorage(ClipboardExclusions.legacyKey) private var legacy: String?
    @State private var pickingApps = false
    @ObservedObject var model: Model

    private var exclusions: [String] { ClipboardExclusions.ids(saved: stored, legacy: legacy) }

    var body: some View {
        DisclosureGroup("Excluded apps") {
            ForEach(exclusions, id: \.self) { id in
                let title = ClipboardExclusions.title(for: id)
                HStack {
                    Text(verbatim: title)
                    Spacer()
                    Button(role: .destructive) {
                        stored = exclusions.filter { $0 != id }.joined(separator: "\n")
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Text("Remove \(title) from excluded apps"))
                }
            }
            Button { pickingApps = true } label: {
                Label("Add apps…", systemImage: "plus")
            }
        }
        .fileImporter(isPresented: $pickingApps, allowedContentTypes: [.applicationBundle], allowsMultipleSelection: true) { result in
            model.operation {
                let updated = ClipboardExclusions.adding(try result.get(), to: exclusions)
                stored = updated.joined(separator: "\n")
            }
        }
    }
}
#endif
