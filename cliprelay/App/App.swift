import SwiftUI
import UniformTypeIdentifiers
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
#if os(macOS)
import AppKit
import Carbon
#else
import UIKit
import VisionKit
#endif

@MainActor final class Model: ObservableObject {
    @Published var rows: [Summary] = []
    @Published var peers: [Peer] = []
    @Published var notice = ""
    @Published var filter = ""
    @Published var search = ""
    @Published var page = 0
    @Published private(set) var hasNextPage = false
    @Published var ready = false
    @Published var busy = false
    var transfer:Exchange?
    var library:Library? {transfer?.library}
    #if os(macOS)
    @Published private(set) var menuRows: [Summary] = []
    @Published private(set) var copyToast: UUID?
    private var copyToastTask: Task<Void, Never>?
    private var captureTimer: Timer?
    private var changeCount = NSPasteboard.general.changeCount
    private var nextAutomaticSync = Date.distantPast
    #endif
    init() {
        #if DEBUG
        if QA.active {return}
        #if targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--history-ui-qa") {
            do {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                transfer = Exchange(try Library(root), try Identity(secret: Data(repeating: 42, count: 32), name: "QA"))
                reload()
            } catch { notice = error.localizedDescription }
            return
        }
        #endif
        #endif
        do {
            #if os(macOS)
            let name=Host.current().localizedName ?? "Mac"
            #else
            let name=UIDevice.current.name
            #endif
            let x=Exchange(try Library(Library.directory()),try Identity.load(name:name));transfer=x
            x.didReceive = { [weak self] in
                Task { @MainActor in
                    self?.reload()
                    #if os(macOS)
                    if UserDefaults.standard.bool(forKey: "mac.playSyncSound") {
                        NSSound(named: NSSound.Name("Pop"))?.play()
                    }
                    #endif
                }
            }
            #if os(iOS)
            reload()
            if !peers.isEmpty { startNetworking() }
            #else
            try x.start();ready=true;reload()
            #endif
            #if os(macOS)
            let timer = Timer(timeInterval: 0.7, repeats: true) { [weak self] timer in
                MainActor.assumeIsolated {
                    guard let self else { timer.invalidate(); return }
                    self.pollClipboard()
                    self.syncIfDue()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            captureTimer = timer
            #endif
        } catch {notice=error.localizedDescription}
    }
    func reload() {
        guard let library else { return }
        do {
            let count = try library.recordCount(kind: filter, search: search)
            let lastPage = max(0, count - 1) / 30
            if page > lastPage { page = lastPage }
            rows = try library.page(kind: filter, search: search, offset: page * 30, pinnedFirst: true)
            hasNextPage = page < lastPage
            peers = try library.peers()
            #if os(macOS)
            menuRows = Array(try library.page(pinnedFirst: true).prefix(10))
            #endif
        } catch { notice = error.localizedDescription }
    }
    #if os(iOS)
    func startNetworking() {
        guard !ready, let transfer else { return }
        do { try transfer.start(); ready = true }
        catch { notice = error.localizedDescription }
    }
    #endif
    func operation(_ body:()throws->Void) {do{try body();notice="";reload()}catch{notice=error.localizedDescription}}
    func save(_ clips: [Clip]) throws {
        guard let library else { throw RelayFailure.storage }
        #if os(macOS)
        let send = UserDefaults.standard.object(forKey: "clipboard.sendAutomatically") as? Bool ?? true
        try library.saveCopies(clips, source: "Local", sendToPeers: send)
        if send { nextAutomaticSync = .distantPast }
        #else
        try library.saveCopies(clips, source: "Local")
        #endif
        page = 0
    }

    func storedClip(_ id: String) throws -> Clip {
        guard let library else { throw RelayFailure.storage }
        return try library.clip(id)
    }

    func copy(_ row: Summary) {
        operation {
            guard let library else { throw RelayFailure.storage }
            try library.useClip(row.id) { try systemCopy($0) }
        }
        guard notice.isEmpty else { return }
        #if os(macOS)
        copyToastTask?.cancel()
        copyToast = UUID()
        copyToastTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1.6)) } catch { return }
            self?.copyToast = nil
        }
        #else
        notice = ClipRelayPreferences.localized("Copied")
        #endif
    }
    #if os(macOS)
    private func pollClipboard() {
        let clipboard = NSPasteboard.general
        let version = clipboard.changeCount
        guard changeCount != version else { return }
        changeCount = version
        let settings = UserDefaults.standard
        guard (settings.object(forKey: "clipboard.captureAutomatically") as? Bool ?? true),
              version != lastWrittenClipboard, !IsSecureEventInputEnabled() else { return }
        let source = NSWorkspace.shared.frontmostApplication
        if let bundle = source?.bundleIdentifier {
            guard !ClipboardExclusions.excludes(bundle, settings: settings) else { return }
        }
        let sendToPeers = settings.object(forKey: "clipboard.sendAutomatically") as? Bool ?? true
        do {
            try recordClipboardCopies(in: clipboard, source: source?.localizedName ?? "Local", sendToPeers: sendToPeers)
        } catch RelayFailure.invalid {
        } catch RelayFailure.unauthorized {
        } catch { notice = error.localizedDescription }
    }

    func recordClipboardCopies(in clipboard: NSPasteboard, source: String, sendToPeers: Bool) throws {
        guard let library else { throw RelayFailure.storage }
        let version = clipboard.changeCount
        let clips = try clipboardClips(in: clipboard)
        guard clipboard.changeCount == version else { return }
        var saved = false
        var failure: Error?
        for clip in clips {
            do {
                try library.saveCopies([clip], source: source, sendToPeers: sendToPeers)
                saved = true
            } catch { failure = error }
        }
        if saved {
            reload()
            if sendToPeers { nextAutomaticSync = .distantPast }
        }
        if let failure { throw failure }
    }

    private func syncIfDue() {
        guard UserDefaults.standard.object(forKey: "clipboard.flushOnReconnect") as? Bool ?? true,
              !busy, !peers.isEmpty, nextAutomaticSync <= .now else { return }
        nextAutomaticSync = .now.addingTimeInterval(12)
        Task { await syncConfigured(quietly: true) }
    }
    #endif
    func syncConfigured(_ clip: Clip? = nil, quietly: Bool = false) async {
        let settings = ClipRelayPreferences.defaults
        let address = settings.string(forKey: "relay.url") ?? "https://cliprelay-test.macseek.cc"
        let cloud: Cloud?
        do {
            cloud = try settings.bool(forKey: "relay.enabled") ? Cloud(address, RelayCredential.read(address: address)) : nil
        } catch {
            await sync(nil, clip: clip, quietly: quietly)
            if !quietly { notice = error.localizedDescription }
            return
        }
        await sync(cloud, clip: clip, quietly: quietly)
    }
    func sync(_ cloud:Cloud?, clip:Clip?=nil, quietly:Bool=false) async {
        guard let transfer else {
            if !quietly { notice = RelayFailure.storage.localizedDescription }
            return
        }
        if let clip {
            do {guard !peers.isEmpty else{throw RelayFailure.unauthorized};try transfer.queue(clip)}
            catch {notice=error.localizedDescription;return}
        }
        guard !busy else {
            if clip != nil && !quietly {
                notice = ClipRelayPreferences.localized("Pending")
                #if os(macOS)
                nextAutomaticSync = .distantPast
                #endif
            }
            return
        }
        busy=true;defer{busy=false;reload()}
        do {
            if clip == nil { try? await transfer.refreshDirectory() }
            peers = try transfer.library.peers()
            var routes:[String]=[], failures:[String]=[], unavailable:[String]=[]
            var received = 0
            for peer in peers {
                if let clip {
                    do { routes += try await transfer.flush(to: peer, cloud: cloud, only: clip.id.uuidString) }
                    catch { failures.append(peer.name) }
                    continue
                }
                do {
                    for id in try transfer.library.sharedSends(peer) {
                        _ = try transfer.library.prepareSharedSend(id, from: transfer.me, to: peer)
                    }
                } catch {failures.append(peer.name)}
                do {routes += try await transfer.flush(to:peer,cloud:cloud)}
                catch {if !failures.contains(peer.name) {failures.append(peer.name)}}
                do {routes += try await transfer.flushForwarded(to:peer,cloud:cloud)}
                catch {if !failures.contains(peer.name) {failures.append(peer.name)}}
                #if os(iOS)
                let shouldPullLAN = clip == nil
                #else
                let shouldPullLAN = clip == nil && !quietly
                #endif
                if shouldPullLAN {
                    do { received += try await transfer.pullLAN(from: peer) }
                    catch { if cloud == nil { unavailable.append(peer.name) } }
                }
            }
            if clip == nil { received += try await cloud.mapAsync {try await transfer.pull($0)} ?? 0 }
            if !quietly || !routes.isEmpty || received > 0 || !failures.isEmpty {
                if !failures.isEmpty {
                    notice = ClipRelayPreferences.localized("Pending") + " · " + failures.joined(separator: ", ")
                } else if !quietly && !unavailable.isEmpty && routes.isEmpty && received == 0 {
                    notice = ClipRelayPreferences.localized("Device or relay unavailable") + " · " + unavailable.joined(separator: ", ")
                } else {
                    #if os(iOS)
                    if !quietly { notice = "" }
                    #else
                    notice = "↑ \(routes.count)  ↓ \(received)  \(Set(routes).sorted().joined(separator:", "))"
                    #endif
                }
            }
        } catch {if !quietly {notice=error.localizedDescription}}
    }
}
extension Optional {
    fileprivate func mapAsync<T>(_ body:(Wrapped) async throws->T) async rethrows->T? {
        guard let self else{return nil};return try await body(self)
    }
}
struct ClipRelayApp:App {
    @StateObject private var model=Model()
    #if os(macOS)
    @StateObject private var menu = MacMenuController()
    #endif
    init(){
        #if DEBUG && os(iOS)
        if QA.active {Task {await QA.run()}}
        #endif
    }
    var body:some Scene {
        #if os(macOS)
        Window(ClipRelayPreferences.localized("ClipRelay"), id: "history") { MacWorkspaceWindow(model: model, menu: menu) }
            .defaultSize(width: 980, height: 638)
            .windowResizability(.contentMinSize)
        #else
        WindowGroup { Home(model: model) }
        #endif
    }
}
@MainActor func systemCopy(_ clip:Clip)throws {
    #if os(macOS)
    let p=NSPasteboard.general
    if clip.kind=="File" {
        let url = try materialize(clip)
        p.clearContents();guard p.writeObjects([url as NSURL]) else {throw RelayFailure.storage}
    } else {
        let item=NSPasteboardItem(); item.setData(clip.bytes,forType:.init(clip.type))
        if let text=clip.text{item.setString(text,forType:.string)}
        p.clearContents();guard p.writeObjects([item]) else {throw RelayFailure.storage}
    }
    lastWrittenClipboard = p.changeCount
    #else
    var items:[String:Any]=[clip.type:clip.bytes];if let plain=clip.text{items[UTType.utf8PlainText.identifier]=plain}
    UIPasteboard.general.setItems([items],options:[.localOnly:true])
    #endif
}
#if os(macOS)
@MainActor private var lastWrittenClipboard: Int?
#endif
struct SettingsInputFocus: ViewModifier {
    #if os(iOS)
    @FocusState private var focused: Bool
    #endif

    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .focused($focused)
            .submitLabel(.done)
            .onSubmit { focused = false }
        #else
        content
        #endif
    }
}

struct Home:View {
    #if os(iOS)
    private enum HistoryField { case draft, search }
    @FocusState private var historyField: HistoryField?
    #endif
    @ObservedObject var model:Model
    @State private var language = ClipRelayPreferences.language
    @State private var theme = ClipRelayPreferences.theme
    #if os(iOS)
    @AppStorage("setupGuide.dismissed") private var guideDismissed = false
    @State private var showingGuide = false
    @State private var keyboardCapture = ClipRelayPreferences.keyboardCapturesClipboard
    @State private var keyboardSend = ClipRelayPreferences.keyboardSendsClipboard
    #endif
    @State private var draft = ""
    @State private var tab: Int
    @State private var importing = false
    @AppStorage("relay.url", store: ClipRelayPreferences.defaults) private var address="https://cliprelay-test.macseek.cc"
    @AppStorage("relay.enabled", store: ClipRelayPreferences.defaults) private var enabled=false
    @State private var credential=""
    @State private var confirmCredentialRemoval = false
    @State private var sharedFile: URL?
    @State private var preview: Clip?
    @State private var pendingDeletion: Summary?
    #if os(macOS)
    @AppStorage("clipboard.captureAutomatically") private var automaticCapture = true
    @AppStorage("clipboard.sendAutomatically") private var automaticSend = true
    #endif
    @Environment(\.scenePhase) private var phase
    init(model: Model, initialTab: Int = 0) {
        self.model = model
        _tab = State(initialValue: initialTab)
    }
    private func sync(_ clip:Clip?=nil) {
        Task { await model.syncConfigured(clip) }
    }

    private func addDraft() {
        guard !draft.isEmpty else { return }
        model.operation {
            try model.save([.text(draft)])
            draft = ""
            #if os(iOS)
            historyField = nil
            #endif
        }
    }

    private func historyIcon(_ name: String) -> some View {
        Image(systemName: name)
            .frame(minWidth: 34, minHeight: 36)
            .contentShape(Rectangle())
    }

    var body:some View {
        TabView(selection:$tab) {
            VStack(alignment:.leading){
                HStack {
                    TextField("New text", text: $draft)
                        #if os(iOS)
                        .focused($historyField, equals: .draft)
                        .submitLabel(.done)
                        #endif
                        .onSubmit(addDraft)
                    Button(action: addDraft) { historyIcon("plus") }
                    .accessibilityLabel(Text("Add item"))
                    .disabled(draft.isEmpty)
                }
                HStack {
                    TextField("Search", text: $model.search)
                        #if os(iOS)
                        .focused($historyField, equals: .search)
                        .submitLabel(.search)
                        .onSubmit { historyField = nil }
                        #endif
                    Picker("Filter",selection:$model.filter){ForEach(["","Pinned","Text","Rich text","Image","File"],id:\.self){v in Text(LocalizedStringKey(v.isEmpty ? "All":v)).tag(v)}}
                }
                List(model.rows){row in
                    HStack{
                        HistoryItemLabel(row: row, library: model.library)
                        Spacer()
                        Button { model.copy(row) } label: { historyIcon("doc.on.doc") }
                            .accessibilityLabel(Text("Copy"))
                            .accessibilityIdentifier("history.copy.\(row.id)")
                            .help("Copy")
                        Button {
                            model.operation { sync(try model.storedClip(row.id)) }
                        } label: { historyIcon("paperplane") }
                            .accessibilityLabel(Text("Send to devices"))
                            .accessibilityIdentifier("history.send.\(row.id)")
                            .help(model.peers.isEmpty ? Text("No paired devices") : Text("Send to devices"))
                            .disabled(model.peers.isEmpty)
                        Menu {
                            Button("Preview") { model.operation { preview = try model.storedClip(row.id) } }
                            Button("Share item") { model.operation { sharedFile = try materialize(model.storedClip(row.id)) } }
                            Button { model.operation { try model.library?.pin(row.id) } } label: {
                                Label(LocalizedStringKey(row.pinned ? "Unpin" : "Pin"), systemImage: row.pinned ? "pin.slash" : "pin")
                            }
                            Button("Delete", role: .destructive) { pendingDeletion = row }
                        } label: { historyIcon("ellipsis.circle") }
                            .accessibilityLabel(Text("Item actions"))
                            .accessibilityIdentifier("history.actions.\(row.id)")
                            .help("Item actions")
                    }.buttonStyle(.borderless)
                }
                #if os(iOS)
                .scrollDismissesKeyboard(.immediately)
                #endif
                HStack {
                    #if os(iOS)
                    PasteButton(supportedContentTypes: ClipboardPaste.types) { providers in
                        Task { @MainActor in
                            do {
                                guard !providers.isEmpty else { throw RelayFailure.invalid }
                                var clips: [Clip] = []
                                for provider in providers { clips.append(try await ClipboardPaste.load(provider)) }
                                model.operation { try model.save(clips) }
                            } catch {model.notice=error.localizedDescription}
                        }
                    }.buttonBorderShape(.capsule)
                    #else
                    Button("Paste") { model.operation { try model.save(clipboardClips(in: .general)) } }
                    #endif
                    Button("Import file"){importing=true}
                    Spacer()
                    Button("‹"){model.page-=1;model.reload()}.disabled(model.page==0).accessibilityLabel(Text("Previous page"))
                    Text("\(model.page+1)")
                    Button("›"){model.page+=1;model.reload()}.disabled(!model.hasNextPage).accessibilityLabel(Text("Next page"))
                }
            }.padding().tabItem{Label("History",systemImage:"list.clipboard")}.tag(0)
            Form {
                PairingSettings(model:model)
                Section("Sync"){
                    Button("Sync now"){sync()}.disabled(model.busy)
                    #if os(macOS)
                    Button("Send current clipboard") {
                        model.operation {
                            guard let library = model.library else { throw RelayFailure.storage }
                            try library.saveCopies(clipboardClips(in: .general), source: "Local", sendToPeers: true)
                            sync()
                        }
                    }.disabled(model.peers.isEmpty)
                    Toggle("Automatically save clipboard items",isOn:$automaticCapture)
                    Toggle("Automatically sync clipboard items",isOn:$automaticSend).disabled(!automaticCapture)
                    if automaticCapture && automaticSend {
                        LabeledContent("Paired devices",value:model.peers.map(\.name).joined(separator:", "))
                        LabeledContent("Cloud relay",value:ClipRelayPreferences.localized(enabled ? "On" : "Off"))
                    }
                    #endif
                }
            }.formStyle(.grouped)
            #if os(iOS)
            .scrollDismissesKeyboard(.immediately)
            .task(id: tab) { if tab == 1 { model.startNetworking() } }
            #endif
            .tabItem{Label("Devices",systemImage:"laptopcomputer.and.iphone")}.tag(1)
            Form {
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
                #if os(iOS)
                Section("Keyboard preferences") {
                    Button("Setup guide") { showingGuide = true }
                    KeyboardStartupOptions()
                    Toggle("Save copied text when keyboard appears", isOn:$keyboardCapture)
                    Toggle("Send keyboard imports to paired devices", isOn:$keyboardSend)
                        .disabled(!keyboardCapture)
                    Text("Keyboard imports can contain sensitive text. Sending uses paired devices and the cloud relay if enabled.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                #endif
                #if os(macOS)
                Section("History") {
                    ClipboardExclusionSettings(model: model)
                }
                #endif
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
                ArchiveSettings(model:model)
                DiagnosticsSection(model:model)
            }.formStyle(.grouped)
            #if os(iOS)
            .scrollDismissesKeyboard(.immediately)
            #endif
            .tabItem{Label("Settings",systemImage:"gearshape")}.tag(2)
        }.safeAreaInset(edge:.bottom){if !model.notice.isEmpty {Text(model.notice).font(.caption).padding(5)}}
        .environment(\.locale, Locale(identifier:language == "system" ? ClipRelayPreferences.match(Locale.preferredLanguages) : language))
        .preferredColorScheme(theme == "light" ? .light : theme == "dark" ? .dark : nil)
        .onChange(of:language){_, value in ClipRelayPreferences.language=value}
        .onChange(of:theme){_, value in ClipRelayPreferences.theme=value}
        #if os(iOS)
        .onAppear { if !guideDismissed { showingGuide = true } }
        .sheet(isPresented: $showingGuide, onDismiss: { guideDismissed = true }) {
            SetupGuide(model: model, theme: $theme)
        }
        .onChange(of:keyboardCapture){_, value in ClipRelayPreferences.keyboardCapturesClipboard=value}
        .onChange(of:keyboardSend){_, value in ClipRelayPreferences.keyboardSendsClipboard=value}
        #endif
        .onChange(of:model.filter){_,_ in model.page=0;model.reload()}.onChange(of:model.search){_,_ in model.page=0;model.reload()}
        #if os(iOS)
        .task(id:phase) {
            guard phase == .active else { return }
            keyboardCapture = ClipRelayPreferences.keyboardCapturesClipboard
            keyboardSend = ClipRelayPreferences.keyboardSendsClipboard
            while !Task.isCancelled {
                model.reload()
                if model.ready && !model.peers.isEmpty { await model.syncConfigured(quietly: true) }
                do {try await Task.sleep(for:.seconds(12))} catch {break}
            }
        }
        #endif
        .sheet(item:$preview) { clip in
            ClipboardPreview(clip:clip)
        }
        .sheet(isPresented:Binding(get:{sharedFile != nil},set:{if !$0 {sharedFile=nil}})){
            if let sharedFile {
                VStack(spacing:16) {
                    Text(sharedFile.lastPathComponent).lineLimit(2)
                    ShareLink(item:sharedFile)
                    Button("Done"){self.sharedFile=nil}.keyboardShortcut(.cancelAction)
                }.padding(24)
            }
        }
        .alert("Delete clipboard item?", isPresented: Binding(
            get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }
        ), presenting: pendingDeletion) { row in
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
            Button("Delete", role: .destructive) {
                pendingDeletion = nil
                model.operation { try model.library?.delete(row.id) }
            }
        } message: { row in
            Text(row.name)
        }
        .fileImporter(isPresented:$importing,allowedContentTypes:[.item]){result in model.operation{try model.save([fileClip(result.get())])}}
        #if os(macOS)
        .frame(minWidth:520,minHeight:420)
        #endif
    }
}
struct ClipboardPreview: View {
    let clip: Clip
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Label("Preview",systemImage:"doc.text.magnifyingglass").font(.headline)
                Spacer()
                Button("Done"){dismiss()}.keyboardShortcut(.cancelAction)
            }
            ScrollView {
                if let text=clip.text {
                    Text(text).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)
                } else if clip.kind == "Image", let input=CGImageSourceCreateWithData(clip.bytes as CFData,nil),
                          let thumbnail=CGImageSourceCreateThumbnailAtIndex(input,0,[
                            kCGImageSourceCreateThumbnailFromImageAlways:true,
                            kCGImageSourceCreateThumbnailWithTransform:true,
                            kCGImageSourceThumbnailMaxPixelSize:1200
                          ] as CFDictionary) {
                    Image(decorative:thumbnail,scale:1).resizable().scaledToFit().accessibilityLabel(clip.name)
                } else {
                    Text(clip.name).textSelection(.enabled)
                }
            }
            Text(clip.date.formatted()+" · "+ByteCountFormatter.string(fromByteCount:Int64(clip.bytes.count),countStyle:.file))
                .font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(idealWidth:460,idealHeight:360)
    }
}
struct QR:View {
    let content:String
    var body:some View {
        let filter=CIFilter.qrCodeGenerator();let _ = filter.setValue(Data(content.utf8),forKey:"inputMessage")
        if let ci=filter.outputImage,let cg=CIContext().createCGImage(ci,from:ci.extent) {
            Image(decorative:cg,scale:1).interpolation(.none).resizable().scaledToFit().frame(width:190,height:190).padding(8).background(.white)
        }
    }
}
#if os(iOS)
struct Scanner:UIViewControllerRepresentable {
    let found:(String)->Void
    func makeCoordinator()->Coordinator { Coordinator(found) }
    func makeUIViewController(context:Context)->DataScannerViewController {
        let vc=DataScannerViewController(recognizedDataTypes:[.barcode(symbologies:[.qr])]);vc.delegate=context.coordinator;try? vc.startScanning();return vc
    }
    func updateUIViewController(_ uiViewController:DataScannerViewController,context:Context){}
    final class Coordinator:NSObject,DataScannerViewControllerDelegate {
        let found:(String)->Void
        init(_ found:@escaping(String)->Void){self.found=found}
        func dataScanner(_ dataScanner:DataScannerViewController,didAdd addedItems:[RecognizedItem],allItems:[RecognizedItem]){
            for item in addedItems {if case .barcode(let b)=item,let value=b.payloadStringValue {dataScanner.stopScanning();found(value);return}}
        }
    }
}
#endif
