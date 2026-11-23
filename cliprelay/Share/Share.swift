import UIKit

final class Share: UIViewController {
    private let status = UILabel()
    private let save = UIButton(type: .system)
    private let send = UIButton(type: .system)
    private var records: [Clip] = []
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
            guard !ClipboardPaste.isPrivate(providers) else { status.text = localized("Private clipboard content was skipped"); return }
            let library = try Library(Library.directory())
            var total = 0
            var skipped: [String] = []
            for (index, provider) in providers.enumerated() {
                do {
                    let clip = try await ClipboardPaste.load(provider)
                    let bytes = clip.bytes.count + (clip.plain?.utf8.count ?? 0)
                    guard bytes <= Clip.limit - total else { throw RelayFailure.tooLarge }
                    records.append(clip)
                    total += bytes
                } catch {
                    let name = provider.suggestedName ?? String(format: localized("Item %lld"), index + 1)
                    skipped.append(name + " · " + localized(error.localizedDescription))
                }
            }
            self.library = library
            let accepted = records.map { item in
                [item.name, localized(item.kind), ByteCountFormatter.string(fromByteCount: Int64(item.bytes.count), countStyle: .file)]
                    .joined(separator: " · ")
            }
            status.text = (accepted + skipped).joined(separator: "\n")
            guard !records.isEmpty else { return }
            let canSend = try !library.peers().isEmpty
            save.isEnabled = true
            send.isEnabled = canSend && !ClipRelayPreferences.paused
        } catch { status.text = error.localizedDescription }
    }

    private func commit(send shouldSend: Bool) {
        guard let library else { return }
        do {
            if shouldSend && ClipRelayPreferences.paused { status.text = localized("已暂停记录与同步"); return }
            if shouldSend, try library.peers().isEmpty { throw RelayFailure.unauthorized }
            let ids = try library.saveCopies(records, source: "Share", sendToPeers: shouldSend, privateToDevice: !shouldSend)
            guard shouldSend else {
                extensionContext?.completeRequest(returningItems: nil)
                return
            }
            view.isUserInteractionEnabled = false
            Task { @MainActor in
                await ExtensionDelivery.attempt(library, ids: ids)
                extensionContext?.completeRequest(returningItems: nil)
            }
        } catch { status.text = error.localizedDescription }
    }
}
