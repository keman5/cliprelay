import UIKit

final class Share: UIViewController {
    private let status = UILabel()
    private let save = UIButton(type: .system)
    private let send = UIButton(type: .system)
    private var records: [(clip: Clip, source: String, pinned: Bool)] = []
    private var library: Library?

    override func viewDidLoad() {
        super.viewDidLoad()
        switch ClipRelayPreferences.theme {
        case "light": overrideUserInterfaceStyle = .light
        case "dark": overrideUserInterfaceStyle = .dark
        default: break
        }
        view.backgroundColor = .systemBackground
        status.font = .preferredFont(forTextStyle: .body)
        status.adjustsFontForContentSizeCategory = true
        status.numberOfLines = 5
        save.setTitle(localized("Save to ClipRelay"), for: .normal)
        send.setTitle(localized("Send to devices"), for: .normal)
        save.addAction(UIAction { [weak self] _ in self?.commit(send: false) }, for: .primaryActionTriggered)
        send.addAction(UIAction { [weak self] _ in self?.commit(send: true) }, for: .primaryActionTriggered)
        let cancel = UIButton(type: .system, primaryAction: UIAction(title: localized("Cancel")) { [weak self] _ in
            self?.extensionContext?.completeRequest(returningItems: nil)
        })
        let stack = UIStackView(arrangedSubviews: [status, save, send, cancel])
        stack.axis = .vertical
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
        ])
        save.isEnabled = false
        send.isEnabled = false
        Task { await prepare() }
    }

    private func localized(_ key: String) -> String { ClipRelayPreferences.localized(key) }

    private func prepare() async {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem])?.flatMap { $0.attachments ?? [] } ?? []
        do {
            guard !providers.isEmpty, providers.count <= 10 else { throw RelayFailure.invalid }
            let library = try Library(Library.directory())
            var total = 0
            for provider in providers {
                let clip = try await ClipboardPaste.load(provider)
                total += clip.bytes.count + (clip.plain?.utf8.count ?? 0)
                guard total <= Clip.limit else { throw RelayFailure.tooLarge }
                records.append((clip, "Share", false))
            }
            self.library = library
            status.text = records.prefix(5).map { item in
                [item.clip.name, localized(item.clip.kind), ByteCountFormatter.string(fromByteCount: Int64(item.clip.bytes.count), countStyle: .file)]
                    .joined(separator: " · ")
            }.joined(separator: "\n")
            let canSend = try !library.peers().isEmpty
            save.isEnabled = true
            send.isEnabled = canSend
        } catch { status.text = error.localizedDescription }
    }

    private func commit(send shouldSend: Bool) {
        guard let library else { return }
        do {
            _ = try library.importArchive(records, sendToPeers: shouldSend)
            guard shouldSend else {
                extensionContext?.completeRequest(returningItems: nil)
                return
            }
            view.isUserInteractionEnabled = false
            let ids = Set(records.map { $0.clip.id.uuidString })
            Task { @MainActor in
                await ExtensionDelivery.attempt(library, ids: ids)
                extensionContext?.completeRequest(returningItems: nil)
            }
        } catch { status.text = error.localizedDescription }
    }
}
