import LocalAuthentication
import SwiftUI
import UniformTypeIdentifiers

enum MacClipKind: String, CaseIterable, Identifiable {
    case text, link, code, image, document, pdf, archive
    var id: Self { self }
    var title: String {
        switch self {
        case .text: ClipRelayPreferences.localized("Text")
        case .link: ClipRelayPreferences.localized("Link")
        case .code: ClipRelayPreferences.localized("Code")
        case .image: ClipRelayPreferences.localized("Image")
        case .document: ClipRelayPreferences.localized("Document")
        case .pdf: "PDF"
        case .archive: ClipRelayPreferences.localized("Archive")
        }
    }
    var symbol: String {
        switch self {
        case .text: "textformat"
        case .link: "link"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .image: "photo"
        case .document: "doc.text"
        case .pdf: "doc.richtext"
        case .archive: "doc.zipper"
        }
    }
    var color: Color {
        switch self {
        case .text: .teal
        case .link: .blue
        case .code: .purple
        case .image: .pink
        case .document: .indigo
        case .pdf: .red
        case .archive: .orange
        }
    }
}

extension Summary {
    var macKind: MacClipKind {
        if kind == "Image" { return .image }
        if kind == "File" {
            let ext = (name as NSString).pathExtension.lowercased()
            let uti = type.flatMap { UTType($0) }
            if uti?.conforms(to: .pdf) == true || ext == "pdf" { return .pdf }
            if uti?.conforms(to: .archive) == true || ["zip", "rar", "7z", "tar", "gz", "bz2", "xz"].contains(ext) { return .archive }
            if ["swift", "js", "ts", "py", "go", "rs", "sh", "html", "css", "json"].contains(ext) { return .code }
            return .document
        }
        if let url = URL(string: name), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
           url.host != nil, !name.contains(where: \.isWhitespace) { return .link }
        if name.range(of: #"(?m)^(import |func |let |const |class |sudo |swift |npm |git |#!)|[{};].*[{};]"#, options: .regularExpression) != nil { return .code }
        return .text
    }

    var macFormat: String {
        if let type, let uti = UTType(type), !uti.isDynamic, uti != .data {
            if let ext = uti.preferredFilenameExtension { return ext.uppercased() }
            if let description = uti.localizedDescription { return description }
        }
        let ext = (name as NSString).pathExtension
        if kind == "File", !ext.isEmpty { return ext.uppercased() }
        return ClipRelayPreferences.localized(kind)
    }

    var macDisplayDate: Date? { lastCopied ?? date }
}

enum MacHistoryAuthentication {
    #if os(macOS)
    static let preference = "mac.requireBiometrics"
    static let policy = LAPolicy.deviceOwnerAuthenticationWithBiometrics
    #else
    static let preference = "phone.historyLock"
    static let policy = LAPolicy.deviceOwnerAuthentication
    #endif

    @MainActor static func verify(
        _ reason: String,
        required: Bool = ClipRelayPreferences.defaults.bool(forKey: preference),
        evaluate: (String) async throws -> Bool = { reason in
            try await LAContext().evaluatePolicy(policy, localizedReason: reason)
        }
    ) async throws -> Bool {
        guard !Task.isCancelled else { return false }
        guard required else { return true }
        do {
            let verified = try await evaluate(ClipRelayPreferences.localized(reason))
            return verified && !Task.isCancelled
        } catch let error as LAError where [.userCancel, .systemCancel, .appCancel, .userFallback].contains(error.code) {
            return false
        }
    }
}


extension Library {
    func exportText(to url: URL, sensitive: Bool, codes: Bool) throws {
        let data = try archiveIDs().map { record in
            let clip = try clip(record.id)
            let value = clip.text ?? clip.name
            let protected = MacHistoryPrivacy.isMasked(value, sensitive: sensitive, codes: codes, forDetail: false)
            return "[\(record.captured.ISO8601Format())] \(record.source) · \(protected ? "******" : value)"
        }.joined(separator: "\n")
        try Data(data.utf8).write(to: url, options: .atomic)
    }
}

enum ReleaseCheck {
    static func message() async throws -> String {
        struct Release: Decodable { let tag_name: String }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let api = URL(string: "https://api.github.com/repos/keman5/cliprelay/releases/latest")!
        let (data, response) = try await URLSession.shared.data(from: api)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw RelayFailure.unavailable }
        let release = try JSONDecoder().decode(Release.self, from: data)
        let latest = release.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        return latest.compare(version, options: .numeric) == .orderedDescending
            ? String(localized: "发现新版本 \(latest)。请在项目主页查看。")
            : String(localized: "已是最新版本")
    }
}
