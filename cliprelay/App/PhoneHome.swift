#if os(iOS)
import SwiftUI

private final class HistorySnapshotCover: UIView {
    static func setHidden(_ hidden: Bool, in scene: UIWindowScene) {
        for window in scene.windows where window.windowLevel == .normal && !window.isHidden {
            if let cover = window.subviews.first(where: { $0 is HistorySnapshotCover }) {
                if hidden { cover.removeFromSuperview() }
            } else if !hidden {
                let cover = HistorySnapshotCover(frame: window.bounds)
                cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                cover.backgroundColor = .systemBackground
                window.addSubview(cover)
            }
        }
    }
}

struct Home: View {
    @ObservedObject var model: Model
    @Environment(\.scenePhase) private var phase
    @AppStorage("phone.historyLock", store: ClipRelayPreferences.defaults) private var locked = false
    @AppStorage("phone.retry", store: ClipRelayPreferences.defaults) private var retry = true
    @State private var unlocked = false
    @State private var authenticating = false
    @State private var lockGeneration = 0
    @State private var tab = 0
    @State private var language = ClipRelayPreferences.language
    @State private var theme = ClipRelayPreferences.theme
    @AppStorage("setupGuide.dismissed") private var guideDismissed = false
    @State private var showingGuide = false
    @AppStorage("keyboard.capturesClipboard", store: ClipRelayPreferences.defaults) private var keyboardCapture = false
    @AppStorage("keyboard.sendsClipboard", store: ClipRelayPreferences.defaults) private var keyboardSend = false
    @AppStorage("relay.url", store: ClipRelayPreferences.defaults) private var address = "https://cliprelay-test.macseek.cc"
    @AppStorage("relay.enabled", store: ClipRelayPreferences.defaults) private var enabled = false
    @State private var credential = ""
    @AppStorage("phone.lastUpdateCheck") private var lastCheck = 0.0
    @State private var confirmCredentialRemoval = false

    var body: some View {
        Group {
            if locked && !unlocked {
                ContentUnavailableView {
                    Label("Clipboard history locked", systemImage: "lock.shield")
                } description: {
                    if !model.notice.isEmpty { Text(model.notice) }
                } actions: {
                    Button("Unlock history") {
                        Task { @MainActor in
                            authenticating = true
                            defer { authenticating = false }
                            do {
                                let generation = lockGeneration
                                let allowed = try await MacHistoryAuthentication.verify("Unlock history")
                                unlocked = allowed && generation == lockGeneration
                                model.notice = ""
                            } catch { model.notice = error.localizedDescription }
                        }
                    }.buttonStyle(.borderedProminent).disabled(authenticating)
                }
            } else {
                workspace
                    .onAppear { if !guideDismissed { showingGuide = true } }
                    .sheet(isPresented: $showingGuide, onDismiss: { guideDismissed = true }) {
                        SetupGuide(model: model, theme: $theme)
                    }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIScene.willDeactivateNotification)) { event in
            if locked, let scene = event.object as? UIWindowScene { HistorySnapshotCover.setHidden(false, in: scene) }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIScene.didActivateNotification)) { event in
            if let scene = event.object as? UIWindowScene { HistorySnapshotCover.setHidden(true, in: scene) }
        }
        .onAppear { openRequestedHistory() }
        .onReceive(NotificationCenter.default.publisher(for: OpenClipHistory.request)) { _ in openRequestedHistory() }
        .tint(.indigo)
        .environment(\.locale, Locale(identifier: language == "system" ? ClipRelayPreferences.match(Locale.preferredLanguages) : language))
        .preferredColorScheme(theme == "light" ? .light : theme == "dark" ? .dark : nil)
        .onChange(of: language) { _, value in ClipRelayPreferences.language = value }
        .onChange(of: theme) { _, value in ClipRelayPreferences.theme = value }
        .onChange(of: phase) { _, value in if value == .background { lockGeneration += 1; unlocked = false; model.notice = "" } }
        .onChange(of: locked) { _, _ in unlocked = false }
        // The system paste permission alert may make this scene temporarily inactive.
        .task(id: phase != .background && (!locked || unlocked)) {
            guard phase != .background, !locked || unlocked else { return }
            while !Task.isCancelled {
                await model.capturePhoneClipboard()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
        .task(id: phase) {
            guard phase == .active else { return }
            while !Task.isCancelled {
                model.reload()
                if retry && !model.peers.isEmpty && !ClipRelayPreferences.paused { await model.syncConfigured(quietly: true) }
                do { try await Task.sleep(for: .seconds(12)) } catch { return }
            }
        }
    }

    private func openRequestedHistory() {
        if UserDefaults.standard.bool(forKey: "phone.openHistory") {
            tab = 0
            UserDefaults.standard.removeObject(forKey: "phone.openHistory")
        }
    }

    private var workspace: some View {
        TabView(selection: $tab) {
            NavigationStack { PhoneHistory(model: model) }
                .tabItem { Label("History", systemImage: "list.clipboard") }.tag(0)
            NavigationStack {
                Form {
                    if !model.peers.isEmpty { PhoneConnection(model: model) }
                    PairingSettings(model: model)
                    if model.peers.isEmpty { PhoneConnection(model: model) }
                }
                .navigationTitle("Devices")
                .task { model.startNetworking() }
            }.tabItem { Label("Devices", systemImage: "laptopcomputer.and.iphone") }.tag(1)
            NavigationStack {
                Form {
                    Section {
                        Button { showingGuide = true } label: { Label("Setup guide", systemImage: "keyboard.badge.ellipsis") }
                        settingsLink("Keyboard preferences", "keyboard") { keyboardSettings }
                        settingsLink("Appearance", "circle.lefthalf.filled") { appearanceSettings }
                    }
                    Section {
                        settingsLink("Sync", "arrow.triangle.2.circlepath") { PhonePrivacyStorage(model: model, group: .sync); cloudSettings }
                        settingsLink("Privacy & Security", "lock.shield") { PhonePrivacyStorage(model: model, group: .privacy) }
                        settingsLink("Storage", "externaldrive") {
                            PhonePrivacyStorage(model: model, group: .storage)
                            ArchiveSettings(model: model)
                            DiagnosticsSection(model: model)
                        }
                        settingsLink("About", "info.circle") { aboutSettings }
                    }
                }.navigationTitle("Settings")
            }.tabItem { Label("Settings", systemImage: "gearshape") }.tag(2)
        }
        .safeAreaInset(edge: .bottom) {
            if !model.notice.isEmpty {
                HStack {
                    Text(model.notice).font(.footnote)
                    Spacer()
                    Button { model.notice = "" } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("Close")
                }.padding(.horizontal).padding(.vertical, 6).background(.thinMaterial)
            }
        }
    }
    private func settingsLink<Content: View>(_ title: LocalizedStringKey, _ symbol: String, @ViewBuilder content: () -> Content) -> some View {
        NavigationLink {
            Form { content() }.navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        } label: {
            Label { Text(title) } icon: { Image(systemName: symbol).foregroundStyle(.indigo) }
        }
    }

    private var appearanceSettings: some View {
        Section("Appearance") {
            Picker("Language", selection:$language) {
                Text("System").tag("system")
                ForEach(ClipRelayPreferences.locales, id:\.self) { tag in
                    Text(Locale(identifier:tag).localizedString(forIdentifier:tag) ?? tag).tag(tag)
                }
            }
            Picker("Appearance", selection:$theme) {
                Text("System").tag("system")
                Text("Light").tag("light")
                Text("Dark").tag("dark")
            }
        }
    }

    private var keyboardSettings: some View {
        Section("Keyboard preferences") {
            KeyboardStartupOptions()
            Toggle("Automatically save copied text and links", isOn:$keyboardCapture)
            Toggle("Send keyboard imports to paired devices", isOn:$keyboardSend)
                .disabled(!keyboardCapture)
            Text("Keyboard imports can contain sensitive text. Sending uses paired devices and the cloud relay if enabled.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var cloudSettings: some View {
        Section("Cloud relay"){
            Toggle("Enable cloud",isOn:$enabled)
            TextField("HTTPS address",text:$address)
                .modifier(SettingsInputFocus())
            SecureField("Relay credential",text:$credential)
                .modifier(SettingsInputFocus())
            Button("Save relay credential"){
                model.operation{_ = try Cloud(address,credential);try RelayCredential.save(credential,address:address);credential=""}
                if model.notice.isEmpty { model.notice = ClipRelayPreferences.localized("Saved") }
            }.disabled(credential.isEmpty)
            Button("测试连接") {
                Task {
                    do {
                        guard let identity = model.transfer?.me else { throw RelayFailure.storage }
                        _ = try await Cloud(address, RelayCredential.read(address: address)).list(identity, nil)
                        model.notice = ClipRelayPreferences.localized("Relay connected")
                    } catch { model.notice = error.localizedDescription }
                }
            }
            Button("Remove relay credential",role:.destructive){
                confirmCredentialRemoval = true
            }
            .alert("Remove relay credential?", isPresented: $confirmCredentialRemoval) {
                Button("Cancel", role: .cancel) {}
                Button("Remove relay credential", role: .destructive) {
                    model.operation { try RelayCredential.remove(); enabled = false; credential = "" }
                }
            }
        }
    }

    private var aboutSettings: some View {
            Section("About") {
                LabeledContent("版本", value: (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") + " (" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") + ")")
                Button("检查更新") {
                    Task { do { model.notice = try await ReleaseCheck.message(); lastCheck = Date.now.timeIntervalSince1970 }
                           catch { model.notice = error.localizedDescription } }
                }
                if lastCheck > 0 { LabeledContent("上次检查更新", value: Date(timeIntervalSince1970: lastCheck).formatted()) }
                Link("项目主页", destination: URL(string: "https://github.com/keman5/cliprelay")!)
            }
    }

}
#endif
