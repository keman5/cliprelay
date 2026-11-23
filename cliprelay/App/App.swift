import SwiftUI
import UniformTypeIdentifiers
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
#if os(macOS)
import AppKit
import Carbon
import Combine
#else
import UIKit
import AudioToolbox
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
    #if os(iOS)
    @Published private(set) var phoneRevision = 0
    private var phoneVersion: (Int64, Int64) = (-1, -1)
    private var phoneSendRequested = false
    @Published var phoneRoute = ClipRelayPreferences.defaults.string(forKey: "phone.lastRoute")
    #endif
    var transfer:Exchange?
    var library:Library? {transfer?.library}
    #if os(macOS)
    @Published private(set) var menuRows: [Summary] = []
    @Published private(set) var macFeedback: MacActionFeedback?
    @Published var macClipboardReport = ""
    @Published private(set) var macPauseUntil: Date?
    weak var menuController: MacMenuController?
    @Published var shortcutAvailable = false
    @Published var listenerIssue: String?
    @Published private(set) var lastTransferRoute: String?
    private let clipboardSettings: UserDefaults
    let macCopyConfirmation = PassthroughSubject<String, Never>()
    private var macFeedbackTask: Task<Void, Never>?
    private var nextAutomaticSync = Date.distantPast
    private var syncRequested = false
    private var captureTimer: Timer?
    private var changeCount = 0
    #endif
    init(clipboardSettings: UserDefaults = .standard) {
        #if os(macOS)
        self.clipboardSettings = clipboardSettings
        lastTransferRoute = clipboardSettings.string(forKey: "mac.lastTransferRoute")
        macPauseUntil = clipboardSettings.object(forKey: "clipboard.pauseUntil") as? Date
        #endif
        #if DEBUG
        if QA.active {return}
        #if targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--history-ui-qa") {
            do {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                transfer = Exchange(try Library(root), try Identity(secret: Data(repeating: 42, count: 32), name: "iPhone"))
                if ProcessInfo.processInfo.arguments.contains("--fixture-history"), let library {
                    let remote = try Identity(secret: Data(repeating: 43, count: 32), name: "Studio Mac").peer
                    try library.pair(remote)
                    let note = Clip.text("项目会议纪要 · 周三确认交付时间")
                    try library.save(note, source: "Studio Mac", received: true)
                    try library.pin(note.id.uuidString)
                    try library.save(.text("下周购物清单：咖啡豆、燕麦和柑橘。出门前再看一下冰箱里的牛奶，还要记得带上购物袋。提醒自己去熟悉的那家水果店，如果还有熟透的柑橘就带几个回家，放在餐桌上。清单里最后一项的英文是 tangerine。"), source: "Local")
                    try library.save(.text("https://developer.apple.com/design"), source: "Studio Mac", received: true)
                    try library.save(.text("let accent = Color.indigo"), source: "Local")
                }
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
            #if os(macOS)
            changeCount = NSPasteboard.general.changeCount
            let x = Exchange(try Library(Library.directory()), try Identity.load(name: name), transferAllowed: {
                guard let until = clipboardSettings.object(forKey: "clipboard.pauseUntil") as? Date else { return true }
                return until <= .now
            })
            #else
            let x = Exchange(try Library(Library.directory()), try Identity.load(name: name), transferAllowed: { !ClipRelayPreferences.paused })
            #endif
            transfer = x
            x.didReceive = { [weak self] route in
                Task { @MainActor in
                    self?.reload()
                    #if os(macOS)
                    self?.recordTransfer(route)
                    if UserDefaults.standard.bool(forKey: "mac.playSyncSound") {
                        NSSound(named: NSSound.Name("Pop"))?.play()
                    }
                    #else
                    self?.recordPhoneRoute(route)
                    if ClipRelayPreferences.defaults.bool(forKey: "phone.syncSound") { AudioServicesPlaySystemSound(1057) }
                    #endif
                }
            }
            x.didUpdateDelivery = { [weak self] in
                Task { @MainActor in self?.reload() }
            }
            #if os(iOS)
            reload()
            x.didSend = { [weak self] route in Task { @MainActor in self?.recordPhoneRoute(route) } }
            if !peers.isEmpty { startNetworking() }
            #else
            reload()
            x.didSend = { [weak self] route in
                Task { @MainActor in self?.recordTransfer(route) }
            }
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
            startMacListener()
            #endif
        } catch {
            #if os(macOS)
            showMacFeedback(error.localizedDescription, at: "workspace.history")
            #else
            notice = error.localizedDescription
            #endif
        }
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
            #else
            let version = try library.changeVersion()
            if version != phoneVersion { phoneVersion = version; phoneRevision += 1 }
            #endif
        } catch { notice = error.localizedDescription }
    }
    #if os(iOS)
    func capturePhoneClipboard() async {
        let settings = ClipRelayPreferences.defaults
        guard settings.bool(forKey: "phone.foregroundCapture") else { return }
        let board = UIPasteboard.general
        let version = board.changeCount
        guard !ClipRelayPreferences.skipPausedCopy(version: version, key: ClipRelayPreferences.phoneCaptureKey) else { return }
        guard settings.object(forKey: "phone.captureVersion") as? Int != version else { return }
        settings.set(version, forKey: "phone.captureVersion")
        guard !ClipRelayPreferences.paused, !board.types.isEmpty, ClipboardPaste.privateTypes.isDisjoint(with: board.types) else { return }
        let providers = board.itemProviders
        guard !providers.isEmpty else { return }
        guard !ClipboardPaste.isPrivate(providers) else { return }
        var failures: [String] = []
        var count = 0
        for provider in providers {
            do {
                let clip = try await ClipboardPaste.load(provider)
                guard !Task.isCancelled, board.changeCount == version, !ClipRelayPreferences.paused,
                      settings.bool(forKey: "phone.foregroundCapture") else { return }
                try save([clip])
                count += 1
            } catch { failures.append((provider.suggestedName ?? ClipRelayPreferences.localized("Clipboard")) + " · " + ClipRelayPreferences.localized(error.localizedDescription)) }
        }
        if count > 0 { reload() }
        if !failures.isEmpty { notice = ([String(format: ClipRelayPreferences.localized("Saved %lld items"), count)] + failures).joined(separator: "\n") }
    }

    private func recordPhoneRoute(_ route: String) {
        phoneRoute = route
        ClipRelayPreferences.defaults.set(route, forKey: "phone.lastRoute")
    }

    func startNetworking() {
        guard !ready, let transfer else { return }
        transfer.listenerChanged = { [weak self] error in
            if let error { self?.ready = false; self?.notice = error.localizedDescription }
        }
        do { try transfer.start(); ready = true }
        catch { notice = error.localizedDescription }
    }
    #endif
    func operation(_ body:()throws->Void) {do{try body();notice="";reload()}catch{notice=error.localizedDescription}}
    func save(_ clips: [Clip]) throws {
        guard let library else { throw RelayFailure.storage }
        #if os(macOS)
        let send = macPauseUntil == nil && (clipboardSettings.object(forKey: "clipboard.sendAutomatically") as? Bool ?? true)
        try library.saveCopies(clips, source: "Local", sendToPeers: send, privateToDevice: !send)
        if send { syncRequested = true }
        #else
        let send = ClipRelayPreferences.defaults.bool(forKey: "phone.autoSend") && !ClipRelayPreferences.paused
        try library.saveCopies(clips, source: "Local", sendToPeers: send, privateToDevice: !send)
        if send {
            if busy { phoneSendRequested = true }
            else { Task { await syncConfigured(quietly: true) } }
        }
        #endif
        page = 0
    }

    func storedClip(_ id: String) throws -> Clip {
        guard let library else { throw RelayFailure.storage }
        return try library.clip(id)
    }

    @discardableResult func copy(_ row: Summary, showConfirmation: Bool = true) -> Bool {
        operation {
            guard let library else { throw RelayFailure.storage }
            if row.fromHub {
                try systemCopy(library.clip(row.id))
            } else {
                try library.useClip(row.id) { try systemCopy($0) }
            }
        }
        guard notice.isEmpty else { return false }
        guard showConfirmation else { return true }
        #if os(iOS)
        notice = ClipRelayPreferences.localized("Copied")
        #endif
        return true
    }
    #if os(macOS)
    func recordTransfer(_ route: String) {
        guard route != lastTransferRoute else { return }
        lastTransferRoute = route
        clipboardSettings.set(route, forKey: "mac.lastTransferRoute")
    }

    func startMacListener(port: UInt16 = 0) {
        guard let transfer else { return }
        listenerIssue = nil
        transfer.listenerChanged = { [weak self] error in
            self?.ready = error == nil
            self?.listenerIssue = error?.localizedDescription
        }
        do { try transfer.start(port: port) }
        catch { ready = false; listenerIssue = error.localizedDescription }
    }

    func showMacFeedback(_ message: String, at target: String) {
        macFeedbackTask?.cancel()
        macFeedback = message.isEmpty ? nil : MacActionFeedback(target: target, message: message)
        guard macFeedback != nil else { return }
        macFeedbackTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            self?.macFeedback = nil
        }
    }

    @discardableResult func macOperation(at target: String, success: String = "", _ body: () throws -> Void) -> Bool {
        operation(body)
        showMacFeedback(notice.isEmpty ? success : notice, at: target)
        return notice.isEmpty
    }

    func macCopy(_ row: Summary, at target: String) {
        let copied = copy(row, showConfirmation: false)
        showMacCopyResult(copied, at: target)
    }

    func macCopy(at target: String, _ body: () throws -> Void) {
        operation(body)
        showMacCopyResult(notice.isEmpty, at: target)
    }

    private func showMacCopyResult(_ copied: Bool, at target: String) {
        showMacFeedback(copied ? "" : notice, at: target)
        if copied { macCopyConfirmation.send(target) }
    }

    func setMacPaused(_ paused: Bool, in clipboard: NSPasteboard = .general, at now: Date = .now) {
        let until = paused ? now.addingTimeInterval(15 * 60) : nil
        changeCount = clipboard.changeCount
        clipboardSettings.set(until, forKey: "clipboard.pauseUntil")
        macPauseUntil = until
    }

    func newClipboardVersion(in clipboard: NSPasteboard, at now: Date = .now) -> Int? {
        let version = clipboard.changeCount
        if let until = macPauseUntil {
            if until <= now { setMacPaused(false, in: clipboard, at: now) }
            else { changeCount = version }
            return nil
        }
        guard changeCount != version else { return nil }
        changeCount = version
        return version
    }

    private func pollClipboard() {
        let clipboard = NSPasteboard.general
        guard let version = newClipboardVersion(in: clipboard) else { return }
        let settings = clipboardSettings
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
        } catch { showMacFeedback(error.localizedDescription, at: "workspace.history") }
    }

    func recordClipboardCopies(in clipboard: NSPasteboard, source: String, sendToPeers: Bool = false) throws {
        guard macPauseUntil == nil else { return }
        guard let library else { throw RelayFailure.storage }
        let version = clipboard.changeCount
        let clips = try clipboardClips(in: clipboard)
        guard clipboard.changeCount == version else { return }
        let saved = clips.save { clip in
            try library.saveCopies([clip], source: source, sendToPeers: sendToPeers, privateToDevice: !sendToPeers)
        }
        if !saved.clips.isEmpty {
            reload()
            if sendToPeers { syncRequested = true }
        }
        if !saved.failures.isEmpty {
            macClipboardReport = saved.report("Saved %lld items")
        }
    }

    private func syncIfDue() {
        let retry = UserDefaults.standard.object(forKey: "clipboard.flushOnReconnect") as? Bool ?? true
        guard macPauseUntil == nil, !busy, !peers.isEmpty, syncRequested || (retry && nextAutomaticSync <= .now) else { return }
        syncRequested = false
        nextAutomaticSync = .now.addingTimeInterval(12)
        Task { await syncConfigured(quietly: true) }
    }
    #endif
    func deliveryStates(for id: String) -> [String: DeliveryState] {
        (try? library?.deliveryStates(id)) ?? [:]
    }

    func cancelDelivery(_ id: String, to peer: Peer) {
        #if os(macOS)
        let target = "history.delivery.\(id).\(peer.id)"
        var cancelled = false
        if macOperation(at: target, { cancelled = try library?.cancelPendingDelivery(id, to: peer) ?? false }),
           !cancelled {
            showMacFeedback(ClipRelayPreferences.localized("此发送已开始或已完成"), at: target)
        }
        #else
        var cancelled = false
        operation { cancelled = try library?.cancelPendingDelivery(id, to: peer) ?? false }
        if !cancelled && notice.isEmpty { notice = ClipRelayPreferences.localized("此发送已开始或已完成") }
        #endif
    }

    func sendStoredClip(_ id: String, to peer: Peer?, feedback: ((String) -> Void)? = nil) async {
        do { await syncConfigured(try storedClip(id), to: peer, feedback: feedback) }
        catch { (feedback ?? { self.notice = $0 })(error.localizedDescription) }
    }

    func syncConfigured(_ clip: Clip? = nil, to peer: Peer? = nil, quietly: Bool = false, feedback: ((String) -> Void)? = nil) async {
        #if os(macOS)
        if macPauseUntil != nil {
            await sync(nil, clip: clip, to: peer, quietly: quietly, feedback: feedback)
            return
        }
        #endif
        let settings = ClipRelayPreferences.defaults
        let address = settings.string(forKey: "relay.url") ?? "https://cliprelay-test.macseek.cc"
        let cloud: Cloud?
        do {
            cloud = try settings.bool(forKey: "relay.enabled") ? Cloud(address, RelayCredential.read(address: address)) : nil
        } catch {
            let report = feedback ?? { self.notice = $0 }
            await sync(nil, clip: clip, to: peer, quietly: quietly) { result in
                guard !quietly else { return }
                let warning = ClipRelayPreferences.localized("Cloud relay") + " · " + error.localizedDescription
                report(result.isEmpty ? warning : result + "\n" + warning)
            }
            return
        }
        await sync(cloud, clip: clip, to: peer, quietly: quietly, feedback: feedback)
    }
    func sync(_ cloud:Cloud?, clip:Clip?=nil, to destination: Peer? = nil, quietly:Bool=false, feedback: ((String) -> Void)? = nil) async {
        let report = feedback ?? { self.notice = $0 }
        #if os(macOS)
        guard macPauseUntil == nil else {
            if !quietly { report(ClipRelayPreferences.localized("已暂停记录与同步")) }
            return
        }
        #endif
        #if os(iOS)
        guard !ClipRelayPreferences.paused else {
            if !quietly { report(ClipRelayPreferences.localized("已暂停记录与同步")) }
            return
        }
        #endif
        guard let transfer else {
            if !quietly { report(RelayFailure.storage.localizedDescription) }
            return
        }
        if let clip {
            do {
                let recipients = try transfer.library.peers().filter { destination == nil || destination?.id == $0.id }
                guard !recipients.isEmpty else { throw RelayFailure.unauthorized }
                try transfer.queue(clip, to: recipients)
            }
            catch {report(error.localizedDescription);return}
        }
        guard !busy else {
            #if os(iOS)
            if clip != nil { phoneSendRequested = true }
            #endif
            if clip != nil && !quietly {
                report(ClipRelayPreferences.localized("Pending"))
                #if os(macOS)
                syncRequested = true
                #endif
            }
            return
        }
        #if os(iOS)
        startNetworking()
        #endif
        busy = true
        defer {
            busy = false
            reload()
            #if os(iOS)
            if phoneSendRequested {
                phoneSendRequested = false
                Task { await syncConfigured(quietly: true) }
            }
            #endif
        }
        do {
            if clip == nil { try? await transfer.refreshDirectory() }
            peers = try transfer.library.peers()
            var routes:[String]=[], failures:[String]=[], unavailable:[String]=[]
            var received = 0
            for peer in peers where destination == nil || destination?.id == peer.id {
                try Task.checkCancellation()
                #if os(macOS)
                guard macPauseUntil == nil else { return }
                #endif
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
            if clip == nil {
                var pullError: Error?
                if let cloud {
                    do { received += try await transfer.pull(cloud) }
                    catch { pullError = error }
                }
                for peer in peers where destination == nil || destination?.id == peer.id {
                    try Task.checkCancellation()
                    try? await transfer.flushTerminalReceipts(to: peer, cloud: cloud)
                }
                if let pullError { throw pullError }
            }
            if !quietly || !routes.isEmpty || received > 0 || !failures.isEmpty {
                if !failures.isEmpty {
                    report(ClipRelayPreferences.localized("Pending") + " · " + failures.joined(separator: ", "))
                } else if !quietly && !unavailable.isEmpty && routes.isEmpty && received == 0 {
                    report(ClipRelayPreferences.localized("Device or relay unavailable") + " · " + unavailable.joined(separator: ", "))
                } else {
                    #if os(iOS)
                    let showResult = !quietly
                    #else
                    let showResult = true
                    #endif
                    if showResult {
                        report("↑ \(routes.count)  ↓ \(received)  \(Set(routes).sorted().map(ClipRelayPreferences.localized).joined(separator: ", "))")
                    }
                }
            }
        } catch {if !quietly {report(error.localizedDescription)}}
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
    if clip.kind == "File" { items[UTType.fileURL.identifier] = try materialize(clip) as NSURL }
    UIPasteboard.general.setItems([items],options:[.localOnly:true])
    ClipRelayPreferences.keyboardPasteboardVersion = UIPasteboard.general.changeCount
    ClipRelayPreferences.defaults.set(UIPasteboard.general.changeCount, forKey: "phone.captureVersion")
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
