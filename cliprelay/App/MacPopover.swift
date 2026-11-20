#if os(macOS)
import AppKit
import Carbon
import SwiftUI

enum MacMenuShortcut {
    static let defaultKeyCode = kVK_ANSI_V
    static let defaultModifiers = cmdKey | shiftKey
}

struct MenuContent: View {
    private enum Filter: Hashable {
        case all, kind(MacClipKind), pinned
    }

    @ObservedObject var model: Model
    var openMain: () -> Void = {}
    var close: () -> Void = {}
    var showCopyConfirmation: () -> Void = {}
    @State private var filter: Filter = .all
    @State private var search = ""
    @State private var pairing = false
    @State private var selectedID: String?
    @State private var session = MacHistorySession()
    @FocusState private var searching: Bool
    @AppStorage("mac.maskSensitive") private var maskSensitive = true
    @AppStorage("mac.maskCodes") private var maskCodes = false
    @Environment(\.colorScheme) private var scheme
    private var palette: MacPalette { MacPalette(scheme) }

    var body: some View {
        let detail = session.rows.first { $0.id == selectedID }
        return VStack(spacing: 0) {
            if pairing {
                HStack(spacing: 9) {
                    icon("chevron.left", "Back") { pairing = false }
                    Text("Scan pairing QR code").font(.system(size: 17, weight: .bold))
                    Spacer()
                    icon("xmark", "Close", action: close)
                }
                .padding(14)
                ScrollView {
                    MacPairingPanel(model: model, showInvitation: true)
                }
            } else {
                if detail != nil {
                    HStack(spacing: 9) {
                        icon("chevron.left", "Back") { selectedID = nil }
                        Text("Details").font(.system(size: 17, weight: .bold))
                        Spacer()
                        icon("xmark", "Close", action: close)
                    }
                    .padding(14)
                    Rectangle().fill(palette.divider).frame(height: 1)
                } else {
                    header
                }
                MacHistoryGate {
                    if let detail { MacClipDetail(model: model, row: detail) { copyAndClose(detail) } }
                    else { history }
                }
            }
        }
        .frame(width: 374, height: 568)
        .background(palette.surface)
        .foregroundStyle(palette.text)
        .macFeedbackOverlay(pairing ? nil : model.macFeedback)
        .onReceive(model.$rows) { _ in
            session.update((try? model.library?.macHistory()) ?? model.menuRows)
        }
        .onExitCommand {
            if searching { searching = false }
            else if pairing { pairing = false }
            else if detail != nil { selectedID = nil }
            else { close() }
        }
        .accessibilityIdentifier("mac.menu.popover")
    }

    private var header: some View {
        HStack(spacing: 7) {
            VStack(alignment: .leading, spacing: 3) {
                Text("History").font(.system(size: 19, weight: .heavy))
                HStack(spacing: 4) {
                    Circle()
                        .fill(model.macLANConnected ? Color.green : Color.red)
                        .frame(width: 6, height: 6)
                    Text(model.macLANConnected ? "Connected · Local Network" : "Offline")
                        .font(.system(size: 10))
                        .foregroundStyle(palette.secondary)
                        .lineLimit(1)
                }
            }
            .fixedSize()
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(palette.muted)
                TextField("Search history…", text: $search)
                    .textFieldStyle(.plain)
                    .focused($searching)
                    .font(.system(size: 13))
                    .accessibilityIdentifier("mac.menu.search")
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(palette.raised, in: Capsule())
            .overlay { Capsule().strokeBorder(palette.line) }
            icon("qrcode.viewfinder", "Scan pairing QR code") { pairing = true }
            icon("arrow.up.right.square", "Open ClipRelay", action: openMain)
            icon("xmark", "Close", action: close)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 9)
    }

    private var history: some View {
        let rows = records
        return VStack(spacing: 0) {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    chip(Text("All"), .all)
                    ForEach([MacClipKind.text, .link, .code, .image, .document, .pdf, .archive], id: \.self) { kind in
                        chip(Text(verbatim: kind.title), .kind(kind))
                    }
                    chip(Text("Pinned"), .pinned)
                }
                .padding(.horizontal, 14)
            }
            .scrollIndicators(.never)
            .padding(.bottom, 9)
            Rectangle().fill(palette.divider).frame(height: 1)

            ScrollView {
                if rows.isEmpty {
                    Text("No clipboard history")
                        .font(.system(size: 13))
                        .foregroundStyle(palette.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 28)
                        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(palette.line, style: StrokeStyle(dash: [4, 4])) }
                        .padding(14)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { row in
                            Button { copyAndClose(row) } label: { label(for: row) }
                                .buttonStyle(MacMenuRowStyle())
                                .accessibilityIdentifier("mac.menu.copy.\(row.id)")
                                .macFeedbackTarget("menu.row.\(row.id)")
                                .contextMenu {
                                    Button("Copy") { copyAndClose(row) }
                                    Button("Details") { selectedID = row.id }
                                    Button("Send to devices") {
                                        Task {
                                            await model.sendStoredClip(row.id) { model.showMacFeedback($0, at: "menu.row.\(row.id)") }
                                        }
                                    }
                                        .disabled(model.peers.isEmpty)
                                }
                            Rectangle().fill(palette.divider).frame(height: 1)
                        }
                    }
                }
            }
            .scrollIndicators(.never)
            MacClipComposer(model: model, compact: true)
        }
    }

    func copyAndClose(_ row: Summary) {
        if model.copy(row, showConfirmation: false) { showCopyConfirmation() }
        else { model.showMacFeedback(model.notice, at: selectedID == row.id ? "detail.copy" : "menu.row.\(row.id)") }
    }

    private var records: [Summary] {
        let rows = search.isEmpty ? session.rows : session.ordered((try? model.library?.macHistory(search: search)) ?? [])
        return rows.filter {
            switch filter {
            case .all: true
            case .pinned: $0.pinned
            case .kind(let kind): $0.macKind == kind
            }
        }
    }

    private func label(for row: Summary) -> some View {
        let masked = MacHistoryPrivacy.isMasked(row.name, sensitive: maskSensitive, codes: maskCodes, forDetail: false)
        return HStack(spacing: 9) {
            MacClipTile(row: row)
            Text(masked ? "••••••••" : row.name)
                .font(.system(size: row.macKind == .code ? 12 : 13, design: row.macKind == .code ? .monospaced : .default))
                .lineLimit(1)
            Spacer(minLength: 4)
            MacClipStatus(row: row)
            if let date = row.macDisplayDate {
                Text(date, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                    .font(.system(size: 10))
                    .foregroundStyle(palette.muted)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
    }

    private func chip(_ title: Text, _ value: Filter) -> some View {
        let selected = filter == value
        return Button { filter = value } label: {
            title.font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 11)
                .frame(height: 30)
                .foregroundStyle(selected ? palette.surface : palette.text)
                .background(selected ? palette.text : palette.surface, in: Capsule())
                .overlay { Capsule().strokeBorder(selected ? .clear : palette.line) }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func icon(_ symbol: String, _ label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 34, height: 34)
                .background(palette.surface, in: Circle())
                .overlay { Circle().strokeBorder(palette.line) }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
        .help(Text(label))
    }
}

private struct MacMenuRowStyle: ButtonStyle {
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed || hovering ? MacPalette(scheme).raised : .clear)
            .onHover { hovering = $0 }
    }
}

@MainActor final class MacMenuController: NSObject, ObservableObject, NSWindowDelegate {
    private var status: NSStatusItem?
    private let popover = NSPopover()
    private var panel: NSPanel?
    private var copyToast: MacCopyToastPanel?
    private var copyToastTask: Task<Void, Never>?
    private var hotKey: EventHotKeyRef?
    private var registeredShortcut: (key: Int, modifiers: Int)?
    private var handler: EventHandlerRef?
    private var model: Model?
    private var openMain: () -> Void = {}

    func configure(model: Model, openMain: @escaping () -> Void) {
        self.model = model
        self.openMain = openMain
        guard status == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "list.clipboard", accessibilityDescription: "ClipRelay")
        item.button?.target = self
        item.button?.action = #selector(statusPressed)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        status = item
        popover.behavior = .transient
        popover.animates = false
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            let controller = Unmanaged<MacMenuController>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in controller.toggle() }
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    func preferences(visible: Bool, key: Int, modifiers: Int) {
        status?.isVisible = visible
        guard handler != nil,
              registeredShortcut?.key != key || registeredShortcut?.modifiers != modifiers,
              let keyCode = UInt32(exactly: key), let modifierFlags = UInt32(exactly: modifiers)
        else { return }
        let identifier = EventHotKeyID(signature: 0x436C6950, id: 1)
        var replacement: EventHotKeyRef?
        let result = RegisterEventHotKey(keyCode, modifierFlags, identifier, GetApplicationEventTarget(), 0, &replacement)
        guard result == noErr else {
            model?.showMacFeedback(ClipRelayPreferences.localized("Menu shortcut is unavailable"), at: "settings.shortcut")
            return
        }
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = replacement
        registeredShortcut = (key, modifiers)
    }

    @objc private func statusPressed() {
        guard NSApp.currentEvent?.type == .rightMouseUp, let status else {
            toggle()
            return
        }
        close()
        let menu = NSMenu()
        let open = NSMenuItem(
            title: ClipRelayPreferences.localized("Open ClipRelay"),
            action: #selector(showMain), keyEquivalent: ""
        )
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        menu.addItem(withTitle: ClipRelayPreferences.localized("Quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        status.menu = menu
        status.button?.performClick(nil)
        status.menu = nil
    }

    @objc private func showMain() {
        close()
        openMain()
        NSApp.activate()
    }

    private func toggle() {
        if popover.isShown || panel != nil {
            close()
            return
        }
        guard let model else { return }
        let content = MenuContent(model: model, openMain: showMain, close: close, showCopyConfirmation: showCopied)
            .modifier(MacAppearance())
        if let status, status.isVisible, let button = status.button, button.window?.isVisible == true {
            popover.contentViewController = NSHostingController(rootView: content)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        } else if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main {
            let frame = screen.visibleFrame
            let rect = NSRect(x: frame.maxX - 386, y: frame.maxY - 580, width: 374, height: 568)
            let floating = MacMenuPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            floating.level = .popUpMenu
            floating.hasShadow = true
            floating.isOpaque = false
            floating.backgroundColor = .clear
            floating.delegate = self
            floating.contentViewController = NSHostingController(rootView: content.clipShape(RoundedRectangle(cornerRadius: 20)))
            floating.makeKeyAndOrderFront(nil)
            panel = floating
        }
    }

    private func close() {
        popover.close()
        let floating = panel
        panel = nil
        floating?.close()
    }

    private func showCopied() {
        let statusButton = status?.isVisible == true ? status?.button : nil
        let statusWindow = statusButton?.window
        let menuWindow = popover.contentViewController?.view.window ?? panel
        let screen = menuWindow?.screen ?? statusWindow?.screen ?? NSScreen.main
        let anchor = statusWindow.flatMap { window in
            statusButton.map { window.convertToScreen($0.convert($0.bounds, to: nil)) }
        } ?? menuWindow?.frame
        close()
        guard let screen else { return }
        showCopyToast(on: screen, centeredOn: anchor)
    }

    private func showCopyToast(on screen: NSScreen, centeredOn anchor: NSRect?) {
        copyToastTask?.cancel()
        copyToast?.orderOut(nil)
        let toast = MacCopyToastPanel()
        let frame = screen.visibleFrame
        let size = toast.frame.size
        let x = (anchor?.midX ?? frame.maxX - size.width / 2 - 12) - size.width / 2
        toast.setFrameTopLeftPoint(NSPoint(x: max(frame.minX + 8, min(x, frame.maxX - size.width - 8)),
                                           y: frame.maxY - 8))
        copyToast = toast
        toast.orderFrontRegardless()
        copyToastTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1.5)) } catch { return }
            self?.copyToast?.orderOut(nil)
            self?.copyToast = nil
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === panel { close() }
    }
}

@MainActor final class MacCopyToastPanel: NSPanel {
    init() {
        let host = NSHostingView(rootView: MacCopyToast(animateCheck: true).padding(12).fixedSize().modifier(MacAppearance()))
        super.init(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .popUpMenu
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        contentView = host
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class MacMenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

struct MacWorkspaceWindow: View {
    @ObservedObject var model: Model
    let menu: MacMenuController
    @Environment(\.openWindow) private var openWindow
    @AppStorage("mac.showMenuBarIcon") private var showMenuBarIcon = true
    @AppStorage("mac.shortcutKeyCode") private var shortcutKey = MacMenuShortcut.defaultKeyCode
    @AppStorage("mac.shortcutModifiers") private var shortcutModifiers = MacMenuShortcut.defaultModifiers

    var body: some View {
        MacWorkspace(model: model)
            .modifier(MacAppearance())
            .onAppear {
                let open = openWindow
                menu.configure(model: model) { open(id: "history") }
                menu.preferences(visible: showMenuBarIcon, key: shortcutKey, modifiers: shortcutModifiers)
            }
            .onChange(of: [showMenuBarIcon ? 1 : 0, shortcutKey, shortcutModifiers]) {
                menu.preferences(visible: showMenuBarIcon, key: shortcutKey, modifiers: shortcutModifiers)
            }
    }
}
#endif
