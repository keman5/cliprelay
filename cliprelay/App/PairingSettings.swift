import SwiftUI
import Combine
#if os(iOS)
import VisionKit
#endif

private struct PeerAddress: View {
    @ObservedObject var model: Model
    let peer: Peer
    @State private var value = ""
    var body: some View {
        DisclosureGroup("Local address") {
            TextField("192.168.1.2:52000", text: $value)
            Button("Save") {
                model.operation {
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard trimmed.isEmpty || Exchange.localEndpoint(trimmed) != nil else { throw RelayFailure.invalid }
                    try model.library?.setLANAddress(trimmed, peer: peer)
                }
            }
        }.onAppear { value = (try? model.library?.lanAddress(peer)) ?? "" }
    }
}

struct PairingSettings: View {
    private struct PendingPairing {
        let card: PairingCard
        let request: PairingRequest
        let code: String
    }

    private enum Review {
        case invitation(Peer, PairingCard)
        case request(Peer, String)

        var peer: Peer {
            switch self {
            case .invitation(let peer, _), .request(let peer, _): peer
            }
        }
    }

    @ObservedObject var model: Model
    @AppStorage("relay.lanForwarding") private var forwarding = false
    @AppStorage("relay.publishDirectory") private var publishDirectory = false
    @State private var card: PairingCard?
    @State private var waiting: PendingPairing?
    @State private var approvalCode: String?
    @State private var invitationStatus: LocalizedStringKey?
    @State private var pairingStatus: LocalizedStringKey?
    @State private var fetching = false
    @State private var code = ""
    @State private var candidate: Review?
    @State private var scanning = false
    @State private var now = Date.now
    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            Section("This device") {
                if let port = model.transfer?.listeningPort {
                    LabeledContent("TCP port", value: String(port))
                }
                if let me = model.transfer?.me.peer {
                    Text(me.name)
                    fingerprint(me)
                    Button("Show pairing card") {
                        model.operation {
                            guard let transfer = model.transfer else { throw RelayFailure.unavailable }
                            let invitation = try transfer.makePairingCard()
                            transfer.offerPairing(invitation)
                            card = invitation
                            approvalCode = nil
                            invitationStatus = nil
                        }
                    }
                    if approvalCode == nil, let card, card.expires > now, let value = try? card.code() {
                        if let peer = model.transfer?.pendingPairing() {
                            Text("Pairing request from \(peer.name)")
                            fingerprint(peer)
                            Button("Trust device") { approveRequest(from: peer) }
                        }
                        let seconds = Int(card.expires.timeIntervalSince(now).rounded(.up))
                        QR(content: value).accessibilityLabel(Text("Device pairing card"))
                        Text("Expires in \(seconds) s")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Copy pairing code") { copy(value) }
                        Button("Cancel invitation") {
                            self.card = nil
                            model.transfer?.offerPairing(nil)
                            invitationStatus = nil
                        }
                    } else if approvalCode == nil, card != nil {
                        Text("Pairing invitation expired").foregroundStyle(.secondary)
                    }
                    if let invitationStatus { Text(invitationStatus) }
                    if let approvalCode, now < (card?.expires ?? .distantPast) {
                        DisclosureGroup("Manual pairing") {
                            codeRow(approvalCode, caption: "Return this approval to the other device")
                        }
                    }
                }
            }
            Section("Pair device") {
                let nearby = model.transfer?.nearbyInvitations() ?? [:]
                ForEach(nearby.keys.sorted(), id: \.self) { service in
                    Button { Task { await reviewNearby(service) } } label: {
                        Label(nearby[service] ?? service, systemImage: "bonjour")
                    }
                    .disabled(fetching || waiting != nil)
                }
                TextField("Pairing code", text: $code)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .onSubmit { review(code) }
                #if os(iOS)
                if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                    Button("Scan QR code") { code = ""; scanning = true }.disabled(fetching)
                }
                #endif
                Button("Review device") { review(code) }.disabled(code.isEmpty || fetching)
                if let pairingStatus {
                    if waiting != nil || fetching { ProgressView { Text(pairingStatus) } }
                    else { Text(pairingStatus) }
                }
                if let waiting {
                    Button("Cancel pairing", role: .cancel) {
                        self.waiting = nil
                        pairingStatus = nil
                    }
                    DisclosureGroup("Manual pairing") {
                        codeRow(waiting.code, caption: "Enter this request on the inviting device")
                    }
                }
            }
            Section("Paired devices") {
                let discovered = Set(model.transfer?.discovered() ?? [])
                let direct = (try? model.library?.directPeers()) ?? []
                ForEach(model.peers) { peer in
                    let address = try? model.library?.lanAddress(peer)
                    HStack {
                        VStack(alignment: .leading) {
                            Text(peer.name)
                            Group {
                                if discovered.contains(peer.service) { Text("Found on local network") }
                                else if address?.isEmpty == false { Text("Local address configured") }
                                else { Text("Not found on local network") }
                            }.font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if direct.contains(peer) {
                            Button(role: .destructive) {
                                model.operation { try model.library?.unpair(peer) }
                            } label: { Image(systemName: "minus.circle") }
                                .accessibilityLabel(Text("Remove device"))
                        }
                    }
                    PeerAddress(model: model, peer: peer)
                }
                #if os(macOS)
                Toggle("Allow this Mac to relay on the local network", isOn: $forwarding)
                #endif
            }
            directoryControls
        }
        .onReceive(clock) { now = $0 }
        .task(id: waiting?.code) { await completeNearbyPairing() }
        .alert("Compare fingerprints on both devices", isPresented: Binding(
            get: { candidate != nil },
            set: { if !$0 { candidate = nil } }
        ), presenting: candidate) { review in
            Button("Trust device") {
                approve(review)
            }
            Button("Cancel", role: .cancel) {}
        } message: { review in
            Text("\(review.peer.name)\n\(review.peer.fingerprint)")
        }
        #if os(iOS)
        .sheet(isPresented: $scanning, onDismiss: reviewScan) {
            Scanner { value in
                code = value
                scanning = false
            }
        }
        #endif
    }

    private var directoryControls: some View {
        Section("Member directory") {
            #if os(macOS)
            Toggle("Publish paired devices", isOn: $publishDirectory)
            #endif
            let direct = (try? model.library?.directPeers()) ?? []
            Picker("Trusted directory", selection: Binding(
                get: { (try? model.library?.directoryOwner()) ?? "" },
                set: { id in
                    model.operation { try model.library?.chooseDirectory(id) }
                    Task { try? await model.transfer?.refreshDirectory(); model.reload() }
                }
            )) {
                Text("None").tag("")
                ForEach(direct) { peer in Text(peer.name).tag(peer.id) }
            }
        }
    }

    private func reviewScan() {
        if !code.isEmpty { review(code) }
    }

    private func reviewNearby(_ service: String) async {
        guard !fetching, waiting == nil else { return }
        fetching = true
        pairingStatus = "Connecting to the other device…"
        defer { fetching = false }
        do {
            guard let transfer = model.transfer else { throw RelayFailure.unavailable }
            review(try await transfer.fetchPairing(service))
        } catch {
            pairingStatus = "Could not open the nearby invitation. Scan its QR code or paste its pairing code."
        }
    }

    private func review(_ input: String) {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        do {
            guard let me = model.transfer?.me else { throw RelayFailure.unavailable }
            if value.hasPrefix("CLIPOK.") {
                guard let waiting else { throw RelayFailure.invalid }
                try finishPairing(waiting, receipt: value)
            } else if value.hasPrefix("CLIPREQ.") {
                guard let card else { throw RelayFailure.invalid }
                let request = try PairingRequest.parse(value)
                candidate = .request(try request.verify(at: me, card: card), value)
            } else {
                let invitation = try PairingCard.parse(value)
                let peer = try Peer.parse(invitation.device)
                guard peer.id != me.peer.id else { throw RelayFailure.invalid }
                candidate = .invitation(peer, invitation)
            }
            if candidate != nil && waiting == nil { pairingStatus = nil }
        } catch {
            pairingStatus = "Invalid or expired pairing code"
        }
    }

    private func approve(_ review: Review) {
        switch review {
        case .request(let peer, let value):
            approveRequest(from: peer, code: value)
        case .invitation(_, let invitation):
            do {
                guard let me = model.transfer?.me else { throw RelayFailure.unavailable }
                try invitation.validate()
                let request = try PairingRequest(from: me, card: invitation)
                waiting = try PendingPairing(card: invitation, request: request, code: request.code())
                pairingStatus = "Connecting to the other device…"
                code = ""
            } catch {
                pairingStatus = "Invalid or expired pairing code"
            }
        }
    }

    private func approveRequest(from peer: Peer, code requestCode: String? = nil) {
        do {
            guard let transfer = model.transfer else { throw RelayFailure.unavailable }
            approvalCode = try transfer.approvePairing(peer, requestCode: requestCode)
            invitationStatus = "Approved \(peer.name)"
            code = ""
            pairingStatus = nil
            model.reload()
        } catch {
            invitationStatus = "Could not approve this request. Start a new invitation."
        }
    }

    private func finishPairing(_ waiting: PendingPairing, receipt: String, address: String? = nil) throws {
        guard let transfer = model.transfer else { throw RelayFailure.unavailable }
        let peer = try waiting.request.accept(receipt, at: transfer.me, card: waiting.card)
        try transfer.library.pair(peer, address: address)
        self.waiting = nil
        code = ""
        pairingStatus = "Paired with \(peer.name)"
        model.reload()
    }

    private func completeNearbyPairing() async {
        guard let pending = waiting, let transfer = model.transfer else { return }
        while !Task.isCancelled && pending.card.expires > .now {
            let reply = try? await transfer.sendPairingRequest(pending.code, card: pending.card)
            guard !Task.isCancelled, waiting?.code == pending.code else { return }
            if let reply {
                if reply.code == "pending" {
                    pairingStatus = "Waiting for the other device to confirm"
                } else {
                    do {
                        try finishPairing(pending, receipt: reply.code, address: reply.address)
                        return
                    } catch {
                        pairingStatus = "Could not verify or save the pairing. Retrying…"
                    }
                }
            } else {
                pairingStatus = "Could not reach the other device. Check Wi-Fi and Local Network access."
            }
            do { try await Task.sleep(for: .seconds(2)) }
            catch { return }
        }
        guard !Task.isCancelled, waiting?.code == pending.code else { return }
        waiting = nil
        pairingStatus = "Pairing invitation expired"
    }

    private func codeRow(_ value: String, caption: LocalizedStringKey) -> some View {
        Group {
            Text(caption)
            QR(content: value).accessibilityLabel(Text(caption))
            Button("Copy pairing code") { copy(value) }
        }
    }

    private func copy(_ value: String) {
        model.operation { try systemCopy(.text(value)) }
    }

    private func fingerprint(_ peer: Peer) -> some View {
        Text(peer.fingerprint)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
    }
}
