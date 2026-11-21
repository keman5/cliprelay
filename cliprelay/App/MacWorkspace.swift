#if os(macOS)
import AppKit
import SwiftUI

struct MacPalette {
    let scheme: ColorScheme

    init(_ scheme: ColorScheme) { self.scheme = scheme }

    private func color(_ light: UInt32, _ dark: UInt32) -> Color {
        let value = scheme == .dark ? dark : light
        return Color(red: Double(value >> 16) / 255, green: Double(value >> 8 & 255) / 255, blue: Double(value & 255) / 255)
    }

    var surface: Color { color(0xFFFFFF, 0x171A20) }
    var raised: Color { color(0xF8F8FA, 0x1E222B) }
    var selection: Color { color(0xEEF3FF, 0x1A2333) }
    var line: Color { color(0xE5E7EB, 0x2A2E37) }
    var divider: Color { color(0xEFEFEF, 0x23262E) }
    var text: Color { color(0x171717, 0xF5F5F7) }
    var secondary: Color { color(0x6B7280, 0x9AA0AA) }
    var muted: Color { color(0x9CA3AF, 0x6B7280) }
    var accent: Color { color(0x0066FF, 0x2E9BFF) }
    var accentSoft: Color { color(0xEAF2FF, 0x162A4A) }
    var toast: Color { color(0xFFFFFF, 0x454C58) }
}

struct MacWorkspace: View {
    enum Page: CaseIterable {
        case history, devices, general, sync, privacy, storage, about

        var title: LocalizedStringKey {
            switch self {
            case .history: "Clipboard workspace"
            case .devices: "Devices & Pairing"
            case .general: "General"
            case .sync: "Sync"
            case .privacy: "Privacy & Security"
            case .storage: "Storage"
            case .about: "About"
            }
        }

        var icon: String {
            switch self {
            case .history: "doc.on.doc"
            case .devices: "laptopcomputer.and.iphone"
            case .general: "gearshape"
            case .sync: "arrow.clockwise"
            case .privacy: "shield"
            case .storage: "arrow.down.to.line"
            case .about: "info.circle"
            }
        }
    }

    @ObservedObject var model: Model
    @State private var page: Page
    @Binding private var requestedPage: Page?
    @State private var keyboardNavigation = false
    @AppStorage("clipboard.sendAutomatically") private var automaticSend = true
    @Environment(\.colorScheme) private var scheme
    private var palette: MacPalette { MacPalette(scheme) }

    init(model: Model, initialPage: Page = .history, requestedPage: Binding<Page?> = .constant(nil)) {
        self.model = model
        _page = State(initialValue: initialPage)
        _requestedPage = requestedPage
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(palette.divider).frame(width: 1)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(palette.surface)
        }
        .frame(minWidth: 860, minHeight: 520)
        .macFeedbackOverlay(model.macFeedback, copyConfirmation: model.macCopyConfirmation)
        .tint(palette.accent)
        .focusEffectDisabled(!keyboardNavigation)
        .background(MacWorkspaceFocus(keyboardNavigation: $keyboardNavigation))
        .onChange(of: requestedPage, initial: true) {
            guard let requestedPage else { return }
            page = requestedPage
            self.requestedPage = nil
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    heading("Menu")
                    item(.history, count: (try? model.library?.recordCount(kind: "")) ?? model.rows.count)
                        .macFeedbackTarget("workspace.history")
                    heading("Manage")
                    item(.devices, count: model.peers.count)
                    heading("Settings")
                    ForEach([Page.general, .sync, .privacy, .storage, .about], id: \.self) { item($0) }
                }
            }
            .scrollIndicators(.hidden)
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Auto Sync", isOn: $automaticSend)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(.system(size: 12, weight: .semibold))
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.macLANConnected ? "Connected · Local Network Bonjour" : "Offline · On This Mac")
                    Text("HPKE end-to-end encryption")
                }
                .font(.system(size: 11))
                .foregroundStyle(palette.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.top, 10)
            .padding(.bottom, 2)
            .overlay(alignment: .top) { Rectangle().fill(palette.divider).frame(height: 1) }
        }
        .padding(10)
        .frame(width: 184)
        .background(palette.raised)
    }

    private func heading(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .bold))
            .tracking(0.6)
            .foregroundStyle(palette.muted)
            .padding(.horizontal, 8)
            .padding(.top, 12)
            .padding(.bottom, 4)
    }

    private func item(_ destination: Page, count: Int? = nil) -> some View {
        let selected = page == destination
        return Button { page = destination } label: {
            HStack(spacing: 9) {
                Image(systemName: destination.icon)
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 17)
                    .foregroundStyle(selected ? palette.accent : palette.secondary)
                Text(destination.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(selected ? palette.accent : palette.text)
                    .lineLimit(1)
                Spacer(minLength: 3)
                if let count {
                    Text(count, format: .number)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(selected ? palette.accent : palette.muted)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 34)
            .contentShape(Rectangle())
            .background(selected ? palette.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var content: some View {
        switch page {
        case .history:
            VStack(spacing: 0) {
                if model.peers.isEmpty {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Connect your first device").font(.system(size: 13, weight: .semibold))
                            Text("Pair a device to send clips. You can keep using history on this Mac.")
                                .font(.system(size: 12)).foregroundStyle(palette.secondary)
                        }
                        Spacer()
                        Button("Connect a device") { page = .devices }
                    }
                    .padding(12)
                    .background(palette.raised)
                    Divider()
                }
                MacHistoryGate { MacHistory(model: model) }
            }
        case .devices: MacDevicesPanel(model: model)
        case .general: MacSettingsPanel(model: model, group: .general)
        case .sync: MacSettingsPanel(model: model, group: .sync)
        case .privacy: MacSettingsPanel(model: model, group: .privacy)
        case .storage: MacSettingsPanel(model: model, group: .storage)
        case .about: MacAboutPanel(model: model)
        }
    }
}

/// Keeps AppKit from assigning a control on presentation while leaving its key
/// view loop and SwiftUI's own key handlers in charge of navigation.
struct MacWorkspaceFocus: NSViewRepresentable {
    @Binding var keyboardNavigation: Bool

    func makeNSView(context: Context) -> FocusView {
        FocusView(keyboardNavigation: $keyboardNavigation)
    }

    func updateNSView(_ view: FocusView, context: Context) {
        view.keyboardNavigation = $keyboardNavigation
    }

    static func dismantleNSView(_ view: FocusView, coordinator: ()) {
        view.stopObserving()
    }

    final class FocusView: NSView {
        var keyboardNavigation: Binding<Bool>
        private var hasInteracted = false
        private var keyObserver: NSObjectProtocol?
        private var eventMonitor: Any?

        init(keyboardNavigation: Binding<Bool>) {
            self.keyboardNavigation = keyboardNavigation
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObserving()
            hasInteracted = false
            guard let window else { return }
            keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification,
                object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.clearInitialFocus() }
                }
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                self?.handle(event) == true ? nil : event
            }
            clearInitialFocus()
        }

        private func clearInitialFocus() {
            // The hosting view can register its key views as the window opens.
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.window === window,
                      !self.hasInteracted, window.attachedSheet == nil else { return }
                window.makeFirstResponder(window)
            }
        }

        private func handle(_ event: NSEvent) -> Bool {
            guard let window, event.window === window, window.attachedSheet == nil else { return false }
            hasInteracted = true
            guard event.type == .keyDown else {
                keyboardNavigation.wrappedValue = false
                return false
            }
            let modifiers = event.modifierFlags.intersection([.shift, .control, .option, .command])
            if event.keyCode == 48, modifiers.subtracting(.shift).isEmpty {
                keyboardNavigation.wrappedValue = true
                if window.firstResponder === window {
                    if modifiers.contains(.shift) { window.selectPreviousKeyView(nil) }
                    else { window.selectNextKeyView(nil) }
                    return window.firstResponder !== window
                }
            } else if event.keyCode == 53, modifiers.isEmpty {
                if let editor = window.firstResponder as? NSTextView, editor.hasMarkedText() { return false }
                keyboardNavigation.wrappedValue = false
                // Let the focused control handle Escape before releasing focus.
                let responder = window.firstResponder
                DispatchQueue.main.async { [weak self, weak window, weak responder] in
                    guard let self, let window, self.window === window,
                          window.attachedSheet == nil, window.firstResponder === responder else { return }
                    if window.makeFirstResponder(window) { self.hasInteracted = false }
                }
            }
            return false
        }

        func stopObserving() {
            if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
            if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
            keyObserver = nil
            eventMonitor = nil
        }
    }
}

struct MacAppearance: ViewModifier {
    @AppStorage("ui.language") private var language = "system"
    @AppStorage("ui.theme") private var theme = "system"
    @Environment(\.colorScheme) private var systemScheme

    func body(content: Content) -> some View {
        let locale = language == "system" ? ClipRelayPreferences.match(Locale.preferredLanguages) : language
        let scheme: ColorScheme? = theme == "light" ? .light : theme == "dark" ? .dark : nil
        content
            .environment(\.locale, Locale(identifier: locale))
            .environment(\.colorScheme, scheme ?? systemScheme)
            .preferredColorScheme(scheme)
    }
}

extension Model {
    var macNearbyPeers: [Peer] {
        guard ready else { return [] }
        let discovered = Set(transfer?.discovered() ?? [])
        return peers.filter { discovered.contains($0.service) }
    }

    var macLANConnected: Bool { !macNearbyPeers.isEmpty }
}
#endif
