#if os(macOS)
import AppKit
import Carbon
import LocalAuthentication
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

struct MacPairingPanel: View {
    @ObservedObject var model: Model
    var showInvitation = false
    var selectedNearbyService: String? = nil
    var onPaired: ((Peer) -> Void)? = nil

    var body: some View {
        Form {
            PairingSettings(model: model, onPaired: onPaired, separateDeviceList: true,
                            showInvitation: showInvitation, selectedNearbyService: selectedNearbyService)
        }
        .formStyle(.grouped)
        .frame(minWidth: 360, idealWidth: 440, minHeight: 380)
        .macFeedbackOverlay(model.macFeedback, copyConfirmation: model.macCopyConfirmation)
    }
}

struct MacDevicesPanel: View {
    private enum Device: Hashable { case local, paired(String), nearby(String) }
    private struct PairingSheet: Identifiable {
        let id = UUID()
        var invitation = false
        var service: String? = nil
    }

    @ObservedObject var model: Model
    @AppStorage("mac.deviceNotes") private var notesData = Data()
    @State private var selected = Device.local
    @State private var pairing: PairingSheet?
    @State private var pendingRevocation: Peer?
    @State private var note = ""

    private var notes: [String: String] { (try? JSONDecoder().decode([String: String].self, from: notesData)) ?? [:] }
    private var local: Peer? { model.transfer?.me.peer }
    private var paired: [Peer] { model.peers.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            let discovered = Set(model.transfer?.discovered() ?? [])
            let nearby = (model.transfer?.nearbyInvitations() ?? [:]).filter { service, _ in
                !paired.contains { $0.service == service }
            }
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Button { pairing = PairingSheet(invitation: true) } label: {
                            Label("显示配对码", systemImage: "qrcode")
                        }.buttonStyle(.borderedProminent)
                        Button("输入配对码") { pairing = PairingSheet() }
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    Divider()
                    ScrollView {
                        LazyVStack(spacing: 5) {
                            if let local {
                                deviceRow(.local, name: local.name, subtitle: "本机 · macOS", symbol: "laptopcomputer",
                                          badge: "本机", tint: .green, noteKey: local.service)
                            }
                            ForEach(paired) { peer in
                                deviceRow(.paired(peer.id), name: peer.name, subtitle: "已信任设备", symbol: "laptopcomputer.and.iphone",
                                          badge: discovered.contains(peer.service) ? "已配对 · 在线" : "已配对",
                                          tint: .green, noteKey: peer.service)
                            }
                            ForEach(nearby.keys.sorted(), id: \.self) { service in
                                deviceRow(.nearby(service), name: nearby[service] ?? service, subtitle: "附近发现",
                                          symbol: "bonjour", badge: "未配对", tint: .orange, noteKey: service)
                            }
                            Text("配对时核对两边的设备指纹。备注仅保存在这台 Mac。")
                                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 9).padding(.top, 5)
                        }.padding(8)
                    }
                }
                .frame(minWidth: 270, maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        switch selected {
                        case .local:
                            if let local {
                                deviceDetail(local, status: "本机 · macOS", isLocal: true)
                            }
                        case .paired(let id):
                            if let peer = paired.first(where: { $0.id == id }) {
                                deviceDetail(peer, status: discovered.contains(peer.service) ? "已配对 · 在线" : "已配对 · 未在局域网发现")
                            }
                        case .nearby(let service):
                            if let name = nearby[service] {
                                Text(name).font(.title3.bold())
                                Text("附近发现 · 未配对").foregroundStyle(.secondary)
                                noteEditor(key: service)
                                Button { pairing = PairingSheet(service: service) } label: {
                                    Label("核对指纹并配对", systemImage: "bonjour")
                                }.buttonStyle(.borderedProminent)
                                Text("也可以在另一台设备输入本机配对码，或扫描二维码。")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text("此设备已离开局域网").foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(width: 305)
                .background(Color(nsColor: .textBackgroundColor))
            }
        }
        .onAppear { note = local.flatMap { notes[$0.service] } ?? "" }
        .sheet(item: $pairing) { request in
            VStack(spacing: 0) {
                HStack {
                    Text("设备配对").font(.headline)
                    Spacer()
                    Button("完成") { pairing = nil }.keyboardShortcut(.cancelAction)
                }.padding(14)
                Divider()
                MacPairingPanel(model: model, showInvitation: request.invitation, selectedNearbyService: request.service) { peer in
                    select(.paired(peer.id), noteKey: peer.service)
                }
            }
        }
        .alert("撤销设备信任？", isPresented: Binding(get: { pendingRevocation != nil }, set: { if !$0 { pendingRevocation = nil } }),
               presenting: pendingRevocation) { peer in
            Button("取消", role: .cancel) { pendingRevocation = nil }
            Button("撤销信任", role: .destructive) {
                let revoked = model.macOperation(at: "device.revoke.\(peer.id)") { try model.library?.unpair(peer) }
                if revoked, let local { select(.local, noteKey: local.service) }
            }
        } message: { peer in
            Text("\(peer.name) 需要重新配对后才能同步。")
        }
    }

    private func select(_ device: Device, noteKey: String) {
        selected = device
        note = notes[noteKey] ?? ""
    }

    private func deviceRow(_ device: Device, name: String, subtitle: LocalizedStringKey, symbol: String,
                           badge: LocalizedStringKey, tint: Color, noteKey: String) -> some View {
        Button { select(device, noteKey: noteKey) } label: {
            HStack(spacing: 9) {
                Image(systemName: symbol).foregroundStyle(.tint).frame(width: 32, height: 32)
                    .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 3) {
                    Text(name).fontWeight(.semibold).lineLimit(1)
                    HStack(spacing: 5) {
                        Text(subtitle).foregroundStyle(.secondary)
                        Text(badge).foregroundStyle(tint).padding(.horizontal, 5).padding(.vertical, 2)
                            .background(tint.opacity(0.11), in: Capsule())
                        if let remark = notes[noteKey] { Text("备注：\(remark)").foregroundStyle(.secondary).lineLimit(1) }
                    }.font(.caption)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }
            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
            .background(selected == device ? Color.accentColor.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 9))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected == device ? .isSelected : [])
    }

    private func deviceDetail(_ peer: Peer, status: LocalizedStringKey, isLocal: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(peer.name).font(.title3.bold())
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("状态") { Text(status) }
                if !isLocal {
                    LabeledContent("配对时间", value: (try? model.library?.pairingDate(peer))?.formatted(.dateTime.year().month().day().hour().minute()) ?? "—")
                }
                Text("设备指纹").foregroundStyle(.secondary)
                Text(peer.fingerprint).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }.font(.callout).panelCard()
            noteEditor(key: peer.service)

            if isLocal {
                if let port = model.transfer?.listeningPort { LabeledContent("TCP 端口", value: String(port)) }
                Button { pairing = PairingSheet(invitation: true) } label: {
                    Label("显示配对码", systemImage: "qrcode")
                }
                .buttonStyle(.borderedProminent)
            } else {
                PeerAddress(model: model, peer: peer).id(peer.id)
                HStack {
                    MacPairingTest(model: model, peer: peer).id(peer.id)
                    Button {
                        model.macCopy(at: "device.fingerprint.\(peer.id)") {
                            try systemCopy(.text(peer.fingerprint))
                        }
                    } label: { Label("复制指纹", systemImage: "document.on.document") }
                    .macFeedbackTarget("device.fingerprint.\(peer.id)")
                }
                if ((try? model.library?.directPeers()) ?? []).contains(peer) {
                    Button("撤销信任", role: .destructive) { pendingRevocation = peer }
                        .foregroundStyle(.red)
                        .macFeedbackTarget("device.revoke.\(peer.id)")
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private func noteEditor(key: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("备注").font(.callout.weight(.semibold))
            HStack(spacing: 8) {
                TextField("例如：书房、爸妈用", text: $note)
                    .modifier(SettingsInputFocus())
                    .onSubmit { saveNote(key: key) }
                Button("保存") { saveNote(key: key) }.macFeedbackTarget("device.note.\(key)")
            }
        }
    }

    private func saveNote(key: String) {
        var updated = notes
        let value = String(note.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        updated[key] = value.isEmpty ? nil : value
        if let encoded = try? JSONEncoder().encode(updated) {
            notesData = encoded
            note = value
            model.showMacFeedback(ClipRelayPreferences.localized(value.isEmpty ? "备注已清空" : "备注已保存"),
                                  at: "device.note.\(key)")
        }
    }

}

struct MacPairingTest: View {
    @ObservedObject var model: Model
    let peer: Peer
    @State private var testID: String?
    private var target: String { "device.test.\(peer.id)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                Task { await sendTest() }
            } label: {
                Label("发送测试文字", systemImage: "paperplane")
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.busy || model.macPauseUntil != nil)
            .macFeedbackTarget(target)
            if let testID, let state = model.deliveryStates(for: testID)[peer.id] {
                Text(status(state))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func status(_ state: DeliveryState) -> LocalizedStringKey {
        switch state {
        case .pending: "等待设备接收"
        case .received: "对方设备已接收"
        case .relayed: "已交给中继，等待设备接收"
        }
    }

    private func sendTest() async {
        guard !model.busy, model.macPauseUntil == nil else { return }
        do {
            guard let library = model.library else { throw RelayFailure.storage }
            let clip = Clip.text("随贴同步测试")
            try library.save(clip, source: "Local", privateToDevice: true)
            let id = clip.id.uuidString
            testID = id
            await model.sendStoredClip(id, to: peer, feedback: { message in
                if model.deliveryStates(for: id)[peer.id] == nil {
                    model.showMacFeedback(message, at: target)
                }
            })
        } catch {
            model.showMacFeedback(error.localizedDescription, at: target)
        }
    }
}

private extension View {
    func panelCard() -> some View {
        padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.secondary.opacity(0.18)) }
    }
}

struct MacSettingsCard<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.headline).padding(.bottom, 10)
            Divider()
            content
        }
        .panelCard()
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

enum MacHistoryAuthentication {
    static let preference = "mac.requireBiometrics"

    @MainActor static func verify(
        _ reason: String,
        required: Bool = UserDefaults.standard.bool(forKey: preference),
        evaluate: (String) async throws -> Bool = { reason in
            try await LAContext().evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)
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

struct MacHistoryGate<Content: View>: View {
    @AppStorage(MacHistoryAuthentication.preference) private var required = false
    @State private var unlocked = false
    @State private var authenticating = false
    @State private var error = ""
    @ViewBuilder let content: () -> Content

    var body: some View {
        Group {
            if !required || unlocked { content() }
            else {
                VStack(spacing: 12) {
                    Image(systemName: "touchid").font(.largeTitle).foregroundStyle(.tint)
                    Text("剪贴板历史已锁定").font(.headline)
                    Button("使用 Touch ID 解锁") { Task { await unlock() } }
                        .buttonStyle(.borderedProminent).disabled(authenticating)
                    if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: required) { _, _ in unlocked = false }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in unlocked = false }
    }

    private func unlock() async {
        guard !authenticating else { return }
        authenticating = true
        defer { authenticating = false }
        do {
            unlocked = try await MacHistoryAuthentication.verify("解锁剪贴板历史", required: required)
            error = ""
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct MacSettingsPanel: View {
    enum Group {
        case general, sync, privacy, storage

        var title: LocalizedStringKey {
            switch self {
            case .general: "通用"
            case .sync: "同步"
            case .privacy: "隐私与安全"
            case .storage: "存储"
            }
        }

        var subtitle: LocalizedStringKey {
            switch self {
            case .general: "启动、菜单栏与提示"
            case .sync: "局域网发现与同步方式"
            case .privacy: "打码与生物识别"
            case .storage: "保留时长、缓存与数据"
            }
        }
    }

    @ObservedObject var model: Model
    let group: Group
    @AppStorage("ui.language") private var language = "system"
    @AppStorage("ui.theme") private var theme = "system"
    @AppStorage("mac.showMenuBarIcon") private var menuBarIcon = true
    @AppStorage("mac.playSyncSound") private var sound = false
    @AppStorage("mac.shortcutKeyCode") private var keyCode = MacMenuShortcut.defaultKeyCode
    @AppStorage("mac.shortcutModifiers") private var modifiers = MacMenuShortcut.defaultModifiers
    @AppStorage("clipboard.captureAutomatically") private var capture = true
    @AppStorage("clipboard.sendAutomatically") private var send = true
    @AppStorage("clipboard.flushOnReconnect") private var flush = true
    @AppStorage("mac.lanDiscovery") private var discover = true
    @AppStorage("relay.enabled") private var relay = false
    @AppStorage("relay.url") private var address = "https://cliprelay-test.macseek.cc"
    @AppStorage("mac.maskSensitive") private var maskSensitive = true
    @AppStorage("mac.maskCodes") private var maskCodes = false
    @AppStorage(MacHistoryAuthentication.preference) private var biometrics = false
    @AppStorage("mac.historyRetentionHours") private var retentionHours = 0
    @State private var credential = ""
    @State private var testing = false
    @State private var confirmRemove = false
    @State private var launches = false
    @State private var shortcutRecording = false
    @State private var shortcutMonitor: Any?
    @State private var confirmClear = false
    @State private var confirmCacheClear = false
    @State private var confirmRetention = false
    @State private var pendingRetention = 0
    @State private var exporting = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(group.title).font(.title2.bold())
                    Text(group.subtitle).font(.callout).foregroundStyle(.secondary)
                }
                switch group {
                case .general: general
                case .sync: sync
                case .privacy: privacy
                case .storage: storage
                }
            }
            .frame(maxWidth: 780, alignment: .leading).padding(22)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { launches = SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval }
        .onDisappear { stopRecording() }
    }

    private var general: some View {
        VStack(alignment: .leading, spacing: 0) {
            row("开机时启动", "登录后自动运行菜单栏应用") {
                Toggle("开机时启动", isOn: Binding(get: { launches }, set: setLaunch))
                    .labelsHidden().toggleStyle(.switch).macFeedbackTarget("settings.launch")
            }
            Divider()
            toggle("菜单栏图标", "在菜单栏常驻随贴图标", $menuBarIcon)
            Divider()
            toggle("同步提示音", "收到新剪贴板内容时播放提示音", $sound)
            Divider()
            row("唤起快捷键", "打开菜单栏弹窗") {
                Text(shortcutTitle).font(.system(.callout, design: .monospaced))
                Button(shortcutRecording ? "取消录制" : "录制新快捷键") {
                    if shortcutRecording { stopRecording() } else { recordShortcut() }
                }
                Button("Restore default shortcut") {
                    stopRecording()
                    keyCode = MacMenuShortcut.defaultKeyCode
                    modifiers = MacMenuShortcut.defaultModifiers
                }
                .disabled(!shortcutRecording && keyCode == MacMenuShortcut.defaultKeyCode && modifiers == MacMenuShortcut.defaultModifiers)
                .macFeedbackTarget("settings.shortcut")
            }
            Divider()
            row("语言", "设置界面语言") {
                Picker("Language", selection: $language) {
                    Text("System").tag("system")
                    ForEach(ClipRelayPreferences.locales, id: \.self) { tag in
                        Text(Locale(identifier: tag).localizedString(forIdentifier: tag) ?? tag).tag(tag)
                    }
                }.labelsHidden().fixedSize()
            }
            Divider()
            row("外观", "选择浅色、深色或跟随系统") {
                Picker("Appearance", selection: $theme) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }.labelsHidden().fixedSize()
            }
        }.panelCard()
    }

    private var sync: some View {
        VStack(alignment: .leading, spacing: 0) {
            toggle("自动发送新复制的内容", "发送给所有已配对设备。关闭后，仍可在历史中选择设备手动发送。", $send)
            Divider()
            toggle("局域网发现", "通过 Bonjour 发现同一 Wi-Fi 下的设备", $discover)
            Divider()
            toggle("云端中继（测试）", "局域网不可达时转发加密内容", $relay)
            Divider()
            row("中继地址", "HTTPS") {
                TextField("HTTPS address", text: $address).modifier(SettingsInputFocus()).frame(maxWidth: 235)
                Button(testing ? "测试中…" : "测试连接") { Task { await testRelay() } }
                    .disabled(testing)
                    .macFeedbackTarget("settings.testRelay")
            }
            Divider()
            row("中继凭证", "凭证保存在钥匙串") {
                SecureField("Relay credential", text: $credential).modifier(SettingsInputFocus()).frame(maxWidth: 165)
                Button("保存") {
                    model.macOperation(at: "settings.saveRelay", success: ClipRelayPreferences.localized("Saved")) {
                        _ = try Cloud(address, credential)
                        try RelayCredential.save(credential, address: address)
                        credential = ""
                    }
                }.disabled(credential.isEmpty)
                    .macFeedbackTarget("settings.saveRelay")
                Button("移除", role: .destructive) { confirmRemove = true }
                    .foregroundStyle(.red)
                    .macFeedbackTarget("settings.removeRelay")
            }
            Divider()
            toggle("断线自动同步", "连接恢复后重试待同步内容", $flush)
            Divider()
            row("手动同步", "重试待发内容并接收各已配对设备发来的内容") {
                Button("立即同步") {
                    Task { await model.syncConfigured(feedback: { model.showMacFeedback($0, at: "settings.syncNow") }) }
                }
                .disabled(model.busy || model.peers.isEmpty || model.macPauseUntil != nil)
                .macFeedbackTarget("settings.syncNow")
            }
        }
        .panelCard()
        .onChange(of: discover) { _, active in model.transfer?.setLANDiscovery(active) }
        .alert("Remove relay credential?", isPresented: $confirmRemove) {
            Button("Cancel", role: .cancel) {}
            Button("Remove relay credential", role: .destructive) {
                model.macOperation(at: "settings.removeRelay") { try RelayCredential.remove(); relay = false; credential = "" }
            }
        }
    }

    private var privacy: some View {
        VStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 0) {
                toggle("在历史列表中打码", "遮蔽可识别的密码、验证码与访问令牌预览。打码仅影响本机显示。", $maskSensitive)
                Divider()
                toggle("验证码列表和详情打码", "在历史列表及详情中遮蔽可识别的验证码。复制时仍使用原文。", $maskCodes)
                Divider()
                row("生物识别解锁", "使用 Touch ID 解锁剪贴板历史") {
                    Toggle("生物识别解锁", isOn: Binding(get: { biometrics }, set: setBiometrics))
                        .toggleStyle(.switch).labelsHidden()
                        .macFeedbackTarget("settings.biometrics")
                }
                Text("设备间使用 HPKE 加密。开启测试中继时，中继仅转发加密数据。")
                    .font(.callout).foregroundStyle(.secondary).padding(.top, 12)
            }.panelCard()
            MacSettingsCard(title: "History") {
                toggle("自动记录剪贴板", "将这台 Mac 上新复制的内容加入历史", $capture)
                Divider()
                ClipboardExclusionSettings(model: model).padding(.top, 9)
            }
        }
    }

    private var storage: some View {
        VStack(spacing: 14) {
            MacSettingsCard(title: "History") {
                row("历史保留时长", "超过期限的本机历史会自动删除，置顶条目会保留。") {
                    Picker("历史保留时长", selection: Binding(get: { retentionHours }, set: changeRetention)) {
                        Text("24 小时").tag(24)
                        Text("7 天").tag(168)
                        Text("30 天").tag(720)
                        Text("永久").tag(0)
                    }.pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                Divider()
                let bytes = (try? model.library?.usage().historyBytes) ?? 0
                row("History storage", "本地历史占用 · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .decimal)) / 160 MB") {
                    ProgressView(value: Double(bytes), total: 160_000_000).labelsHidden().frame(width: 160)
                }
                Divider()
                row("History", "Manage local clipboard data") {
                    Button("清理缓存", role: .destructive) { confirmCacheClear = true }
                        .foregroundStyle(.red).macFeedbackTarget("settings.clearCache")
                    Button("导出全部历史", action: exportHistory)
                        .disabled(exporting || model.library == nil).macFeedbackTarget("settings.export")
                    Button("清空全部历史", role: .destructive) { confirmClear = true }
                        .foregroundStyle(.red).macFeedbackTarget("settings.clearHistory")
                }
            }
            ArchiveSettings(model: model)
            DiagnosticsSection(model: model)
        }
        .alert("Clear cache?", isPresented: $confirmCacheClear) {
            Button("取消", role: .cancel) {}
            Button("清理缓存", role: .destructive) {
                model.library?.clearReadCache()
                model.showMacFeedback(ClipRelayPreferences.localized("已清理读取缓存"), at: "settings.clearCache")
            }
        }
        .alert("清空全部历史？", isPresented: $confirmClear) {
            Button("取消", role: .cancel) {}
            Button("清空全部历史", role: .destructive) {
                model.macOperation(at: "settings.clearHistory") { try model.library?.clearHistory() }
            }
        } message: {
            Text("这会删除这台 Mac 的全部剪贴板历史和待发送条目，操作不可撤销。")
        }
        .alert("缩短历史保留时长？", isPresented: $confirmRetention) {
            Button("取消", role: .cancel) {}
            Button("应用", role: .destructive) {
                retentionHours = pendingRetention
                model.reload()
            }
        } message: {
            Text("超过新期限的本机历史会自动删除，置顶条目会保留。")
        }
    }

    private func changeRetention(_ hours: Int) {
        if hours > 0 && (retentionHours == 0 || hours < retentionHours) {
            pendingRetention = hours
            confirmRetention = true
        } else {
            retentionHours = hours
        }
    }

    private func toggle(_ title: LocalizedStringKey, _ subtitle: LocalizedStringKey, _ value: Binding<Bool>) -> some View {
        row(title, subtitle) {
            Toggle(isOn: value) { Text(title) }.toggleStyle(.switch).labelsHidden()
        }
    }

    private func row<Trailing: View>(_ title: LocalizedStringKey, _ subtitle: LocalizedStringKey,
                                     @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.semibold))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            trailing()
        }.padding(.vertical, 9)
    }

    private func setLaunch(_ value: Bool) {
        do {
            if value { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            launches = value
            if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        } catch { model.showMacFeedback(error.localizedDescription, at: "settings.launch") }
    }

    private func setBiometrics(_ value: Bool) {
        if !value {
            Task {
                do {
                    if try await LAContext().evaluatePolicy(.deviceOwnerAuthentication,
                        localizedReason: String(localized: "关闭剪贴板历史锁")) { biometrics = false }
                } catch { model.showMacFeedback(error.localizedDescription, at: "settings.biometrics") }
            }
            return
        }
        var error: NSError?
        guard LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            model.showMacFeedback(error?.localizedDescription ?? ClipRelayPreferences.localized("Touch ID 不可用"),
                                  at: "settings.biometrics")
            return
        }
        biometrics = true
    }

    private var shortcutTitle: String {
        let flags = [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")]
        let glyphs = flags.filter { modifiers & $0.0 != 0 }.map(\.1).joined()
        let ansiKeys = [0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
                         11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2",
                         20: "3", 21: "4", 22: "6", 23: "5", 25: "9", 26: "7", 28: "8", 29: "0", 31: "O",
                         32: "U", 34: "I", 35: "P", 37: "L", 38: "J", 40: "K", 45: "N", 46: "M", 49: "Space"]
        return glyphs + (ansiKeys[keyCode] ?? " [\(keyCode)]")
    }

    private func recordShortcut() {
        shortcutRecording = true
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stopRecording(); return nil }
            if event.keyCode == 48 { stopRecording(); return event }
            let flags = event.modifierFlags
            var carbon = 0
            if flags.contains(.command) { carbon |= cmdKey }
            if flags.contains(.option) { carbon |= optionKey }
            if flags.contains(.control) { carbon |= controlKey }
            if flags.contains(.shift) { carbon |= shiftKey }
            guard carbon & (cmdKey | optionKey | controlKey) != 0 else { return nil }
            keyCode = Int(event.keyCode)
            modifiers = carbon
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let shortcutMonitor { NSEvent.removeMonitor(shortcutMonitor) }
        shortcutMonitor = nil
        shortcutRecording = false
    }

    private func testRelay() async {
        testing = true
        model.showMacFeedback("", at: "settings.testRelay")
        defer { testing = false }
        do {
            guard let identity = model.transfer?.me else { throw RelayFailure.storage }
            let cloud = try Cloud(address, RelayCredential.read(address: address))
            let start = ContinuousClock.now
            _ = try await cloud.list(identity, nil)
            let elapsed = start.duration(to: .now).components
            let milliseconds = elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000
            model.showMacFeedback(String(localized: "中继连接正常 · \(milliseconds) 毫秒"), at: "settings.testRelay")
        } catch { model.showMacFeedback(error.localizedDescription, at: "settings.testRelay") }
    }

    private func exportHistory() {
        guard let library = model.library else { return }
        exporting = true
        Task { @MainActor in
            defer { exporting = false }
            do {
                guard try await MacHistoryAuthentication.verify("Verify to export clipboard history") else { return }
                let panel = NSSavePanel()
                panel.nameFieldStringValue = "cliprelay-history.txt"
                panel.allowedContentTypes = [.plainText]
                guard await panel.begin() == .OK, let url = panel.url else { return }
                let sensitive = maskSensitive
                let codes = maskCodes
                try await Task.detached {
                    let data = try library.archiveIDs().map { record in
                        let clip = try library.clip(record.id)
                        let value = clip.text ?? clip.name
                        let protected = MacHistoryPrivacy.isMasked(value, sensitive: sensitive, codes: codes, forDetail: false)
                        return "[\(record.captured.ISO8601Format())] \(record.source) · \(protected ? "******" : value)"
                    }.joined(separator: "\n")
                    try Data(data.utf8).write(to: url, options: .atomic)
                }.value
                model.showMacFeedback(ClipRelayPreferences.localized("已导出历史"), at: "settings.export")
            } catch { model.showMacFeedback(error.localizedDescription, at: "settings.export") }
        }
    }
}

struct MacAboutPanel: View {
    @ObservedObject var model: Model
    @AppStorage("mac.lastUpdateCheck") private var lastCheck: Double = 0
    @State private var checking = false
    private let project = URL(string: "https://github.com/keman5/cliprelay")!
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—" }
    private var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—" }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                VStack(spacing: 8) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable().aspectRatio(contentMode: .fit).frame(width: 76, height: 76)
                    Text("随贴 ClipRelay").font(.title2.bold())
                    Text("版本 \(version) · 局域网剪贴板历史").foregroundStyle(.secondary)
                    Text("无需注册 · HPKE 端到端加密").foregroundStyle(.secondary)
                    HStack {
                        Button { Task { await checkForUpdate() } } label: {
                            Label(checking ? "正在检查…" : "检查更新", systemImage: "arrow.clockwise")
                        }.disabled(checking).macFeedbackTarget("about.update")
                        Link(destination: project) { Label("项目主页", systemImage: "link") }
                            .buttonStyle(.bordered)
                    }.padding(.top, 4)
                }.padding(.bottom, 6)
                HStack(alignment: .top, spacing: 12) {
                    aboutCard("它做什么", "让自己的设备共用剪贴板历史。支持文本、链接、代码、图片、文档、PDF 与压缩包。")
                    aboutCard("隐私", "设备之间使用 HPKE 加密。开启测试中继时，服务器只转发加密数据。")
                }
                VStack(spacing: 8) {
                    LabeledContent("版本", value: "\(version) (\(build))")
                    LabeledContent("上次检查更新", value: lastCheck == 0 ? "—" : Date(timeIntervalSince1970: lastCheck).formatted())
                    LabeledContent("项目主页") { Link("github.com/keman5/cliprelay", destination: project) }
                    LabeledContent("平台", value: "macOS · iOS")
                }.panelCard()
            }.frame(maxWidth: 780).padding(22).frame(maxWidth: .infinity)
        }
    }

    private func aboutCard(_ title: LocalizedStringKey, _ text: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text(text).font(.callout).foregroundStyle(.secondary)
        }.panelCard()
    }

    private func checkForUpdate() async {
        struct Release: Decodable { let tag_name: String }
        checking = true
        defer { checking = false }
        do {
            let api = URL(string: "https://api.github.com/repos/keman5/cliprelay/releases/latest")!
            let (data, response) = try await URLSession.shared.data(from: api)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw RelayFailure.unavailable }
            let release = try JSONDecoder().decode(Release.self, from: data)
            lastCheck = Date.now.timeIntervalSince1970
            let latest = release.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            let message = latest.compare(version, options: .numeric) == .orderedDescending
                ? String(localized: "发现新版本 \(latest)。请在项目主页查看。")
                : String(localized: "已是最新版本")
            model.showMacFeedback(message, at: "about.update")
        } catch { model.showMacFeedback(error.localizedDescription, at: "about.update") }
    }
}
#endif
