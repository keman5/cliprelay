#if os(iOS)
import Foundation

enum ExtensionDelivery {
    static func attempt(_ library: Library, ids: Set<String>) async {
        guard !ClipRelayPreferences.paused, !ids.isEmpty, let peers = try? library.peers(), !peers.isEmpty,
              let identity = try? Identity.load(name: "iPhone", createIfMissing: false) else { return }
        let exchange = Exchange(library, identity, transferAllowed: { !ClipRelayPreferences.paused })
        if ClipRelayPreferences.discoveryEnabled { exchange.startBrowsing() }
        let settings = ClipRelayPreferences.defaults
        let url = settings.string(forKey: "relay.url") ?? "https://cliprelay-test.macseek.cc"
        let cloud = settings.bool(forKey: "relay.enabled") ? try? Cloud(url, RelayCredential.read(address: url)) : nil
        try? await Task.sleep(nanoseconds: 650_000_000)
        for peer in peers {
            for id in ids {
                guard !Task.isCancelled else { return }
                // Keep large attachments in the durable queue for the containing app.
                guard (try? library.prepareSharedSend(id, from: identity, to: peer, maxBytes: 1_000_000)) == true else { continue }
                _ = try? await exchange.flush(to: peer, cloud: cloud, only: id)
            }
        }
    }
}
#endif
