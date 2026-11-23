#if os(iOS)
import SwiftUI

struct PhoneConnection: View {
    @ObservedObject var model: Model
    @AppStorage("clipboard.pauseUntil", store: ClipRelayPreferences.defaults) private var pauseUntil: Double = 0
    var body: some View {
        Section("Sync") {
            TimelineView(.periodic(from: .now, by: 2)) { context in
                let paused = pauseUntil > context.date.timeIntervalSince1970
                let nearby = Set(model.transfer?.discovered() ?? [])
                VStack(alignment: .leading, spacing: 12) {
                    Label {
                        Text("\(model.peers.filter { nearby.contains($0.service) }.count) nearby devices")
                    } icon: { Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(.indigo) }
                    if let route = model.phoneRoute {
                        Text("Last transfer: \(ClipRelayPreferences.localized(route))").font(.footnote).foregroundStyle(.secondary)
                    }
                    if paused {
                        Text("Paused until \(Date(timeIntervalSince1970: pauseUntil), format: .dateTime.hour().minute())").font(.footnote)
                    }
                    Divider()
                    HStack {
                        Button("Sync now") { Task { await model.syncConfigured() } }
                            .disabled(model.busy || model.peers.isEmpty || paused)
                        Spacer()
                        Button(paused ? "Resume clipboard capture and sync" : "Pause for 15 minutes") {
                            ClipRelayPreferences.updateCaptureBaselines(version: UIPasteboard.general.changeCount, pausing: !paused)
                            pauseUntil = paused ? 0 : Date.now.addingTimeInterval(900).timeIntervalSince1970
                        }
                    }.buttonStyle(.borderless)
                }.padding(.vertical, 4)
            }
        }
    }
}

struct PhonePeerInfo: View {
    @ObservedObject var model: Model
    let peer: Peer
    var local = false
    @State private var note = ""
    @State private var testID: String?
    var body: some View {
        LabeledContent("Fingerprint") { Text(peer.fingerprint).font(.caption.monospaced()).textSelection(.enabled) }
        Button("复制指纹") { model.operation { try systemCopy(.text(peer.fingerprint)) } }
        if local, let port = model.transfer?.listeningPort { LabeledContent("TCP 端口", value: String(port)) }
        if let date = try? model.library?.pairingDate(peer) { LabeledContent("Paired", value: date.formatted()) }
        TextField("备注", text: $note).onAppear { note = UserDefaults.standard.string(forKey: "device.note." + peer.id) ?? "" }
            .onChange(of: note) { _, value in UserDefaults.standard.set(value, forKey: "device.note." + peer.id) }
        if !local {
            Button {
                Task {
                    let clip = Clip.text("随贴同步测试")
                    testID = clip.id.uuidString
                    await model.syncConfigured(clip, to: peer)
                }
            } label: { Label("发送测试文字", systemImage: "paperplane") }
            .disabled(model.busy || ClipRelayPreferences.paused)
            if let testID, let state = model.deliveryStates(for: testID)[peer.id] {
                Text(state.phoneTitle).font(.footnote)
            }
        }
    }
}

struct PhonePrivacyStorage: View {
    enum Group { case sync, privacy, storage }
    @ObservedObject var model: Model
    let group: Group
    @AppStorage("phone.historyLock", store: ClipRelayPreferences.defaults) private var locked = false
    @AppStorage("phone.maskSensitive", store: ClipRelayPreferences.defaults) private var sensitive = true
    @AppStorage("phone.maskCodes", store: ClipRelayPreferences.defaults) private var codes = false
    @AppStorage("phone.retentionHours", store: ClipRelayPreferences.defaults) private var retention = 0
    @AppStorage("phone.autoSend", store: ClipRelayPreferences.defaults) private var autoSend = false
    @AppStorage("phone.foregroundCapture", store: ClipRelayPreferences.defaults) private var capture = false
    @AppStorage("phone.discovery", store: ClipRelayPreferences.defaults) private var discovery = true
    @AppStorage("phone.retry", store: ClipRelayPreferences.defaults) private var retry = true
    @AppStorage("phone.syncSound", store: ClipRelayPreferences.defaults) private var sound = false
    @State private var confirmWipe = false
    @State private var proposedHours: Int?
    @State private var exporting = false
    @State private var file: URL?
    var body: some View {
        switch group {
        case .sync: syncSettings
        case .privacy: privacySettings
        case .storage: storageSettings
        }
    }
    private var syncSettings: some View {
        Section("Sync") {
            Toggle("自动发送新复制的内容", isOn: $autoSend)
            Toggle("断线自动同步", isOn: $retry)
            Toggle("局域网发现", isOn: $discovery).onChange(of: discovery) { _, value in model.transfer?.setLANDiscovery(value) }
            Toggle("同步提示音", isOn: $sound)
        }
    }
    private var privacySettings: some View {
        Section {
            Toggle("Save clipboard while app is open", isOn: $capture)
                .onChange(of: capture) { _, _ in ClipRelayPreferences.defaults.set(UIPasteboard.general.changeCount, forKey: "phone.captureVersion") }
            Toggle("在历史列表中打码", isOn: $sensitive)
            Toggle("验证码列表和详情打码", isOn: $codes)
            Toggle("Lock history", isOn: Binding(get: { locked }, set: { value in
                Task { @MainActor in
                    do {
                        guard try await MacHistoryAuthentication.verify("Unlock history", required: true) else { return }
                        locked = value
                    } catch { model.notice = error.localizedDescription }
                }
            }))
        } header: { Text("Privacy & Security") } footer: {
            Text("iOS can ask before pasting. When history lock is on, shared history is hidden in the keyboard.")
        }
    }
    private var storageSettings: some View {
        Section("Storage") {
            Picker("历史保留时长", selection: Binding(get: { retention }, set: { hours in
                if hours > 0 && (retention == 0 || hours < retention) { proposedHours = hours } else { retention = hours }
            })) {
                Text("24 小时").tag(24); Text("7 天").tag(168); Text("30 天").tag(720); Text("永久").tag(0)
            }
            Button("Clear list cache") { model.library?.clearReadCache(); model.notice = ClipRelayPreferences.localized("已清理读取缓存") }
            Button("导出全部历史") {
                guard let library = model.library else { return }
                exporting = true
                Task { @MainActor in
                    defer { exporting = false }
                    do {
                        guard try await MacHistoryAuthentication.verify("Verify to export clipboard history") else { return }
                        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("cliprelay-history.txt")
                        let mask = sensitive, maskCodes = codes
                        try await Task.detached {
                            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                            try library.exportText(to: url, sensitive: mask, codes: maskCodes)
                        }.value
                        if !Task.isCancelled { file = url }
                    } catch { model.notice = error.localizedDescription }
                }
            }.disabled(exporting || model.library == nil)
            Button("清空全部历史", role: .destructive) { confirmWipe = true }
        }
        .alert("清空全部历史？", isPresented: $confirmWipe) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { authorize { try model.library?.clearHistory() } }
        }
        .alert("缩短历史保留时长？", isPresented: Binding(get: { proposedHours != nil }, set: { if !$0 { proposedHours = nil } }), presenting: proposedHours) { hours in
            Button("Cancel", role: .cancel) {}
            Button("应用", role: .destructive) { authorize { retention = hours } }
        }
        .sheet(isPresented: Binding(get: { file != nil }, set: { if !$0 { file = nil } })) {
            if let file { PhoneShare(url: file, removeAfterSharing: true) }
        }
    }
    private func authorize(_ body: @escaping () throws -> Void) {
        Task { @MainActor in
            do {
                guard try await MacHistoryAuthentication.verify("Verify to delete clipboard history") else { return }
                model.operation(body)
            } catch { model.notice = error.localizedDescription }
        }
    }
}
#endif
