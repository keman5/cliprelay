#if os(macOS) && DEBUG
import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum MacViewCheck {
    private final class HiddenFocusWindow: NSWindow {
        override var isKeyWindow: Bool { true }
        var presentedSheet: NSWindow?

        override func beginSheet(_ sheetWindow: NSWindow, completionHandler handler: ((NSApplication.ModalResponse) -> Void)? = nil) {
            // Record the confirmation without showing a window during QA.
            presentedSheet = sheetWindow
        }
    }
    @MainActor static func run() throws {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        let model = Model()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try checkClipboard(model, in: root)
        try checkComposerPaste(in: root.appendingPathComponent("composer"))
        try checkAutomaticSync(model)
        let toast = MacCopyToastPanel()
        guard !toast.canBecomeKey, !toast.canBecomeMain, toast.ignoresMouseEvents,
              !toast.isVisible, toast.frame.width > 0, toast.frame.height > 0 else { throw RelayFailure.invalid }
        try checkCopyConfirmation(model)
        try checkItemActions(in: root.appendingPathComponent("actions"))
        try checkCopyOrder(in: root.appendingPathComponent("copy-order"))
        try checkExclusions()
        try checkSettings(in: root.appendingPathComponent("settings"))
        let size = NSSize(width: 980, height: 600)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -4000, y: -4000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        try checkCopyToastPlacement(model, in: window)
        try checkOperationNoticeLayout(model, in: window)
        for page in MacWorkspace.Page.allCases {
            try render(MacWorkspace(model: model, initialPage: page), size: size, in: window, name: String(describing: page))
        }
        try render(MacCopyToast(), size: NSSize(width: 180, height: 60), in: window, name: "copy-toast-dark")
        try render(MacCopyToast().environment(\.colorScheme, .light), size: NSSize(width: 180, height: 60), in: window, name: "copy-toast-light")
        try render(MenuContent(model: model), size: NSSize(width: 480, height: 540), in: window, name: "menu")
        let long = Clip.text(String(repeating: "A long clipboard entry for checking the preview scroll area.\n", count: 36))
        try model.library?.save(long, source: "TextEdit")
        model.reload()
        try render(MacWorkspace(model: model), size: NSSize(width: 860, height: 520), in: window, name: "history-long")
        try checkDetailHover(model, in: window)
        if let detail = try model.library?.macHistory().first {
            try render(MacClipDetail(model: model, row: detail), size: NSSize(width: 374, height: 510), in: window, name: "menu-detail-long")
        }
        print("PASS hidden Mac workspace pages and menu layout")
        try checkWorkspaceFocus(model, size: size)
        try checkDeleteShortcut(model, size: size)
    }

    @MainActor private static func checkDetailHover(_ model: Model, in window: NSWindow) throws {
        let size = NSSize(width: 860, height: 520)
        window.setContentSize(size)
        window.acceptsMouseMovedEvents = true
        let host = NSHostingView(rootView: MacWorkspace(model: model))
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.15))
        host.layoutSubtreeIfNeeded()

        func scrollViews(in view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
        }

        let detail = scrollViews(in: host).first { $0.convert($0.bounds, to: host).minX > 540 }
        guard let detail else {
            print("FAIL detail scroll view not found")
            throw RelayFailure.invalid
        }
        detail.scrollerStyle = .overlay
        host.layoutSubtreeIfNeeded()
        let initialFrame = detail.convert(detail.bounds, to: host)
        let previewWidth = detail.contentView.bounds.width
        detail.scrollerStyle = .legacy
        host.layoutSubtreeIfNeeded()
        guard detail.contentView.bounds.width == previewWidth,
              let document = detail.documentView, document.frame.height > initialFrame.height else {
            print("FAIL long detail text should keep its width with either scrollbar style")
            throw RelayFailure.invalid
        }
        detail.contentView.scroll(to: CGPoint(x: 0, y: 100))
        detail.reflectScrolledClipView(detail.contentView)
        let initialContent = detail.contentView.bounds
        guard initialContent.minY > 0 else {
            print("FAIL long detail text should still scroll")
            throw RelayFailure.invalid
        }
        model.reload()
        let positions = [(320, 400), (570, 420), (795, 350), (845, 300), (686, 80), (215, 240)]
        for (x, y) in positions + positions {
            guard let event = NSEvent.mouseEvent(with: .mouseMoved, location: CGPoint(x: x, y: y), modifierFlags: [],
                                                 timestamp: 0, windowNumber: window.windowNumber,
                                                 context: nil, eventNumber: 0, clickCount: 0, pressure: 0) else {
                throw RelayFailure.invalid
            }
            window.sendEvent(event)
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
            host.layoutSubtreeIfNeeded()
            guard detail.convert(detail.bounds, to: host) == initialFrame,
                  detail.contentView.bounds == initialContent, !window.isVisible else {
                print("FAIL detail preview changed its position while moving the pointer")
                throw RelayFailure.invalid
            }
        }
        print("PASS Mac detail preview keeps its width and scroll position during pointer movement and history refresh")
    }

    @MainActor private static func checkComposerPaste(in root: URL) throws {
        let model = Model()
        let library = try Library(root)
        model.transfer = Exchange(library, try Identity(secret: Data(repeating: 9, count: 32), name: "QA"))
        let size = NSSize(width: 500, height: 140)
        let window = HiddenFocusWindow(contentRect: NSRect(origin: NSPoint(x: -4000, y: -4000), size: size),
                                       styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: MacClipComposer(model: model))
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))

        func textView(in view: NSView) -> NSTextView? {
            (view as? NSTextView) ?? view.subviews.lazy.compactMap { textView(in: $0) }.first
        }
        guard let editor = textView(in: host), window.makeFirstResponder(editor) else {
            print("FAIL composer editor unavailable for paste")
            throw RelayFailure.invalid
        }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let image = NSPasteboardItem()
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                                            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let png = bitmap.representation(using: .png, properties: [:]),
              let jpeg = bitmap.representation(using: .jpeg, properties: [:]) else { throw RelayFailure.invalid }
        image.setData(png, forType: .png)
        guard pasteboard.writeObjects([image]), editor.readSelection(from: pasteboard) else {
            print("FAIL composer rejects image-only paste")
            throw RelayFailure.invalid
        }
        let photo = NSPasteboardItem()
        photo.setData(jpeg, forType: .init(UTType.jpeg.identifier))
        pasteboard.clearContents()
        guard pasteboard.writeObjects([photo]), editor.readSelection(from: pasteboard) else {
            print("FAIL composer rejects a JPEG with no plain text fallback")
            throw RelayFailure.invalid
        }

        let file = root.appendingPathComponent("composer-file.pdf")
        let fileData = Data("%PDF-composer".utf8)
        try fileData.write(to: file)
        pasteboard.clearContents()
        guard pasteboard.writeObjects([file as NSURL]), editor.readSelection(from: pasteboard) else {
            print("FAIL composer rejects a Finder file")
            throw RelayFailure.invalid
        }
        let rich = NSPasteboardItem()
        let rtf = Data("{\\rtf1\\ansi \\b Composer rich text}".utf8)
        rich.setData(rtf, forType: .rtf)
        rich.setString("Composer rich text", forType: .string)
        pasteboard.clearContents()
        guard pasteboard.writeObjects([rich]), editor.readSelection(from: pasteboard) else { throw RelayFailure.invalid }
        pasteboard.clearContents()
        guard pasteboard.setString("Composer plain text", forType: .string), editor.readSelection(from: pasteboard),
              editor.string == "Composer plain text", try library.macHistory(search: "composer-file").isEmpty else {
            print("FAIL paste should preserve the editable text and wait for submission")
            throw RelayFailure.invalid
        }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        let previousRows = Set(try library.macHistory().map(\.id))
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        let submitted = try library.macHistory().filter { !previousRows.contains($0.id) }.map { try library.clip($0.id) }
        guard submitted.count == 5,
              submitted.contains(where: { $0.kind == "Image" && $0.bytes == png }),
              submitted.contains(where: { $0.kind == "Image" && $0.bytes == jpeg }),
              submitted.contains(where: { $0.kind == "File" && $0.bytes == fileData }),
              submitted.contains(where: { $0.kind == "Rich text" && $0.bytes == rtf }),
              submitted.contains(where: { $0.kind == "Text" && $0.text == "Composer plain text" }) else {
            print("FAIL Return should save the original image, file, rich text and plain text")
            throw RelayFailure.invalid
        }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        guard editor.string.isEmpty, window.firstResponder === window, !window.isVisible else {
            print("FAIL submission should clear the draft and Escape should release composer focus")
            throw RelayFailure.invalid
        }
        print("PASS Mac composer pastes and saves images, Finder files, rich text and editable plain text")
    }

    @MainActor private static func checkCopyToastPlacement(_ model: Model, in window: NSWindow) throws {
        let target = "device.fingerprint.test"
        let size = NSSize(width: 400, height: 300)
        let host = NSHostingView(rootView: Color.clear
            .overlay(alignment: .topLeading) {
                Color.clear.frame(width: 160, height: 30)
                    .macFeedbackTarget(target)
                    .padding(.leading, 100)
                    .padding(.top, 80)
            }
            .macFeedbackOverlay(model.macFeedback, copyConfirmation: model.macCopyConfirmation))
        window.setContentSize(size)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        let nearItem = NSRect(x: 100, y: 135, width: 170, height: 53)
        let windowTop = NSRect(x: 0, y: 250, width: 400, height: 50)

        func snapshot(_ rect: NSRect) throws -> Data {
            guard let image = host.bitmapImageRepForCachingDisplay(in: rect) else { throw RelayFailure.invalid }
            host.cacheDisplay(in: rect, to: image)
            guard let data = image.representation(using: .png, properties: [:]) else { throw RelayFailure.invalid }
            return data
        }

        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        let before = try snapshot(nearItem)
        let topBefore = try snapshot(windowTop)
        model.macCopy(at: target) {}
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        guard try snapshot(nearItem) != before, try snapshot(windowTop) == topBefore, !window.isVisible else {
            print("FAIL copy toast should appear next to its target")
            throw RelayFailure.invalid
        }
        print("PASS copy toast renders next to its target")
    }

    @MainActor private static func checkCopyConfirmation(_ model: Model) throws {
        let target = "detail.copy"
        defer { model.showMacFeedback("", at: target) }
        var confirmations: [String] = []
        let subscription = model.macCopyConfirmation.sink { confirmations.append($0) }
        defer { subscription.cancel() }
        model.macCopy(at: target) {}
        guard confirmations == [target], model.macFeedback == nil else { throw RelayFailure.invalid }
        model.macCopy(at: target) {}
        model.macCopy(at: target) { throw RelayFailure.unavailable }
        guard confirmations == [target, target], model.macFeedback?.target == target,
              model.macFeedback?.message == RelayFailure.unavailable.localizedDescription else { throw RelayFailure.invalid }
        print("PASS Mac copy success requests the shared toast and failure stays by its button")
    }

    @MainActor private static func checkOperationNoticeLayout(_ model: Model, in window: NSWindow) throws {
        let target = "settings.testRelay"
        defer { model.showMacFeedback("", at: target) }
        let size = NSSize(width: 860, height: 520)
        let host = NSHostingView(rootView: MacWorkspace(model: model, initialPage: .sync)
            .environment(\.colorScheme, .dark))
        window.appearance = NSAppearance(named: .darkAqua)
        window.setContentSize(size)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)

        func snapshot(_ name: String) throws -> (image: Data, bottom: Data) {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
            host.layoutSubtreeIfNeeded()
            func capture(_ rect: NSRect) throws -> Data {
                guard let image = host.bitmapImageRepForCachingDisplay(in: rect) else { throw RelayFailure.invalid }
                host.cacheDisplay(in: rect, to: image)
                guard let data = image.representation(using: .png, properties: [:]) else { throw RelayFailure.invalid }
                return data
            }
            let image = try capture(host.bounds)
            if let directory = ProcessInfo.processInfo.environment["CLIPRELAY_QA_IMAGES"] {
                try image.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
            }
            let bottom = try capture(NSRect(x: 0, y: 0, width: size.width, height: 20))
            return (image, bottom)
        }

        let before = try snapshot("relay-before")
        model.showMacFeedback("Relay connection is healthy · 20 ms", at: target)
        let success = try snapshot("relay-success")
        model.macOperation(at: target) { throw RelayFailure.unavailable }
        let failure = try snapshot("relay-failure")
        guard model.macFeedback?.target == target, model.macFeedback?.message == RelayFailure.unavailable.localizedDescription,
              before.image != success.image, success.image != failure.image,
              before.bottom == success.bottom, before.bottom == failure.bottom, window.contentView?.frame.size == size else {
            print("FAIL relay feedback should appear by its button without changing the bottom of the workspace")
            throw RelayFailure.invalid
        }
        print("PASS relay success and failure render without moving the workspace")
    }

    @MainActor private static func checkAutomaticSync(_ model: Model) throws {
        guard let library = model.library, let peer = model.peers.first else { throw RelayFailure.invalid }
        let defaults = UserDefaults.standard
        let domain = UserDefaults.argumentDomain
        let previous = defaults.volatileDomain(forName: domain)
        defer { defaults.setVolatileDomain(previous, forName: domain) }
        var overrides = previous
        overrides["clipboard.sendAutomatically"] = false
        defaults.setVolatileDomain(overrides, forName: domain)
        try model.save([.text("Local only")])
        guard try library.sharedSends(peer).isEmpty else { throw RelayFailure.invalid }

        overrides["clipboard.sendAutomatically"] = true
        defaults.setVolatileDomain(overrides, forName: domain)
        let outgoing = Clip.text("Sync to paired devices")
        try model.save([outgoing])
        guard try library.sharedSends(peer) == [outgoing.id.uuidString] else { throw RelayFailure.invalid }
        print("PASS Mac automatic sync queues items only when enabled")
    }

    @MainActor private static func checkWorkspaceFocus(_ model: Model, size: NSSize) throws {
        let window = HiddenFocusWindow(contentRect: NSRect(origin: NSPoint(x: -4000, y: -4000), size: size),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: MacWorkspace(model: model))
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        // Simulate AppKit selecting a key view while the window opens, without
        // making the test window visible or activating the app.
        let control = NSButton(title: "Focus probe", target: nil, action: nil)
        host.addSubview(control)
        window.initialFirstResponder = control
        guard window.makeFirstResponder(control), window.firstResponder === control else {
            throw RelayFailure.invalid
        }
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.15))
        guard !window.isVisible, window.firstResponder === window else {
            print("FAIL workspace should open without a focused control")
            throw RelayFailure.invalid
        }

        func press(_ key: String, code: UInt16, modifiers: NSEvent.ModifierFlags = []) throws {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: key,
                charactersIgnoringModifiers: key, isARepeat: false, keyCode: code) else { throw RelayFailure.invalid }
            NSApp.sendEvent(event)
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        }

        // Verify forward navigation both on opening and after Escape.
        for _ in 0..<2 {
            try press("\t", code: 48)
            guard window.firstResponder === control else {
                print("FAIL Tab should enter the window's key-view loop")
                throw RelayFailure.invalid
            }
            try press("\u{1b}", code: 53)
            guard window.firstResponder === window else {
                print("FAIL Escape should release keyboard focus")
                throw RelayFailure.invalid
            }
        }
        print("PASS Mac workspace opens without focus, Tab enters focus, and Escape clears it")
    }

    @MainActor private static func checkDeleteShortcut(_ model: Model, size: NSSize) throws {
        let window = HiddenFocusWindow(contentRect: NSRect(origin: NSPoint(x: -4000, y: -4000), size: size),
                                       styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: MacWorkspace(model: model))
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        guard let library = model.library, let row = try library.macHistory().first,
              let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                           timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                           characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}",
                                           isARepeat: false, keyCode: 51) else { throw RelayFailure.invalid }
        let editor = NSTextView()
        host.addSubview(editor)
        guard window.makeFirstResponder(editor) else { throw RelayFailure.invalid }
        NSApp.sendEvent(event)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        guard window.presentedSheet == nil else {
            print("FAIL Delete should leave the history alone while editing text")
            throw RelayFailure.invalid
        }
        guard window.makeFirstResponder(window) else { throw RelayFailure.invalid }
        NSApp.sendEvent(event)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        guard window.presentedSheet != nil, try library.clip(row.id).id.uuidString == row.id else {
            print("FAIL Delete should request confirmation for the selected item before deleting it")
            throw RelayFailure.invalid
        }
        print("PASS Delete opens history confirmation without deleting and leaves text editing alone")
    }

    @MainActor private static func render<V: View>(_ view: V, size: NSSize, in window: NSWindow, name: String) throws {
        let host = NSHostingView(rootView: view.environment(\.locale, Locale(identifier: "zh-Hans"))
            .environment(\.colorScheme, .dark))
        window.appearance = NSAppearance(named: .darkAqua)
        window.setContentSize(size)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        guard !window.isVisible, host.fittingSize.width > 0, host.fittingSize.height > 0 else {
            throw RelayFailure.invalid
        }
        if let directory = ProcessInfo.processInfo.environment["CLIPRELAY_QA_IMAGES"] {
            let target = URL(fileURLWithPath: directory).appendingPathComponent(name + ".png")
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw RelayFailure.invalid }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw RelayFailure.invalid }
            try png.write(to: target)
        }
    }

    private static func checkItemActions(in root: URL) throws {
        let library = try Library(root)
        let first = Clip.text(String(repeating: "a", count: 85) + " full text match")
        let second = Clip.text("Keep me")
        let ids = try library.saveCopies([first, second], source: "Local")
        guard try library.macHistory(search: "full text match").map(\.id) == [first.id.uuidString] else {
            throw RelayFailure.invalid
        }
        try library.setPinned(ids)
        try library.setBurn(first.id.uuidString, true)
        do {
            try library.useClip(first.id.uuidString) { _ in throw RelayFailure.unavailable }
            throw RelayFailure.invalid
        } catch RelayFailure.unavailable {}
        guard try library.macHistory().allSatisfy(\.pinned) else { throw RelayFailure.invalid }
        try library.useClip(first.id.uuidString) { clip in
            guard clip.bytes == first.bytes else { throw RelayFailure.invalid }
        }
        guard try library.macHistory().map(\.id) == [second.id.uuidString] else { throw RelayFailure.invalid }
        try library.setExpiry(second.id.uuidString, after: 300, now: Date.now.addingTimeInterval(-600))
        guard try library.macHistory().isEmpty else { throw RelayFailure.invalid }
        print("PASS full-text search, bulk pin, burn after successful copy, and local expiry")
    }

    private static func checkCopyOrder(in root: URL) throws {
        let library = try Library(root)
        let first = Clip.text("First")
        let second = Clip.text("Second")
        let third = Clip.text("Third")
        let png = Summary(id: "image", name: "Screenshot", kind: "Image", source: "Local", pinned: false,
                          type: UTType.png.identifier)
        let rtf = Summary(id: "rich", name: "Formatted text", kind: "Rich text", source: "Local", pinned: false,
                          type: UTType.rtf.identifier)
        guard png.macFormat == "PNG", rtf.macFormat == "RTF" else { throw RelayFailure.invalid }
        _ = try library.saveCopies([first, second], source: "Local")
        var history = MacHistorySession()
        history.update(try library.macHistory())
        let initialDate = history.rows.last?.macDisplayDate
        try library.useClip(first.id.uuidString) { _ in }
        history.update(try library.macHistory())
        let stored = try Library(root).macHistory()
        guard history.rows.map(\.id) == [second, first].map({ $0.id.uuidString }),
              history.rows.last?.macDisplayDate == initialDate,
              history.rows.last?.lastCopied == nil,
              stored.first?.id == first.id.uuidString, stored.first?.lastCopied != nil else {
            print("FAIL copying changed the visible history order or timestamp")
            throw RelayFailure.invalid
        }
        var reopened = MacHistorySession()
        reopened.update(stored)
        guard reopened.rows.first?.id == first.id.uuidString,
              reopened.rows.first?.lastCopied == stored.first?.lastCopied else { throw RelayFailure.invalid }
        _ = try library.saveCopies([third], source: "Local")
        try library.useClip(first.id.uuidString) { _ in }
        history.update(try library.macHistory())
        guard history.rows.map(\.id) == [third, second, first].map({ $0.id.uuidString }) else { throw RelayFailure.invalid }
        _ = try library.saveCopies([first], source: "TextEdit")
        history.update(try library.macHistory())
        guard history.rows.map(\.id) == [third, second, first].map({ $0.id.uuidString }),
              try history.ordered(library.macHistory(search: "First")).first?.macDisplayDate == initialDate else {
            throw RelayFailure.invalid
        }
        try library.pin(first.id.uuidString)
        history.update(try library.macHistory())
        guard history.rows.first?.id == first.id.uuidString, history.rows.first?.pinned == true else { throw RelayFailure.invalid }
        print("PASS copy order and timestamps stay stable until reopening, including search results")
    }

    private static func checkExclusions() throws {
        let defaults = ClipboardExclusions.ids(saved: nil, legacy: "org.example.notes, org.example.notes")
        let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        let withTextEdit = ClipboardExclusions.adding([textEdit, textEdit], to: defaults)
        guard ClipboardExclusions.contains("com.apple.keychainaccess", in: defaults),
              ClipboardExclusions.contains("com.lunabee.sg.onesafemac", in: defaults),
              ClipboardExclusions.contains("com.agilebits.onepassword7", in: defaults),
              withTextEdit.count == defaults.count + 1,
              ClipboardExclusions.contains("com.apple.TextEdit", in: withTextEdit),
              defaults.filter({ $0 == "org.example.notes" }).count == 1,
              ClipboardExclusions.ids(saved: "", legacy: "org.example.notes").isEmpty,
              ClipboardExclusions.ids(saved: "com.apple.passwords", legacy: nil) == ["com.apple.passwords"] else {
            throw RelayFailure.invalid
        }
        print("PASS clipboard exclusion defaults, migration and removal")
    }

    @MainActor private static func checkClipboard(_ model: Model, in root: URL) throws {
        let library = try Library(root)
        let peer = try Identity(secret: Data(repeating: 2, count: 32), name: "Peer").peer
        try library.pair(peer)
        model.transfer = Exchange(library, try Identity(secret: Data(repeating: 1, count: 32), name: "QA"))
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let file = root.appendingPathComponent("notes.txt")
        let pdf = root.appendingPathComponent("example.pdf")
        let text = Data("Text fixture".utf8)
        try text.write(to: file)
        try Data("%PDF-fixture".utf8).write(to: pdf)
        guard pasteboard.writeObjects([file as NSURL, pdf as NSURL]) else { throw RelayFailure.invalid }
        try model.recordClipboardCopies(in: pasteboard, source: "QA")
        guard model.rows.count == 2, model.rows.allSatisfy({ $0.kind == "File" }),
              let note = model.rows.first(where: { $0.name == "notes.txt" }),
              let document = model.rows.first(where: { $0.name == "example.pdf" }),
              ClipAttachment(try library.clip(note.id)).byteCount == text.count,
              ClipAttachment(try library.clip(document.id)).symbol == "doc.richtext"
        else { throw RelayFailure.invalid }

        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 2, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0)!
        image.setColor(.systemBlue, atX: 0, y: 0)
        guard let png = image.representation(using: .png, properties: [:]) else { throw RelayFailure.invalid }
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        item.setString("Image source", forType: .string)
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else { throw RelayFailure.invalid }
        try model.recordClipboardCopies(in: pasteboard, source: "QA")
        guard let imageRow = model.rows.first, imageRow.kind == "Image" else { throw RelayFailure.invalid }
        let attachment = ClipAttachment(try library.clip(imageRow.id))
        guard attachment.thumbnail?.width == 4, attachment.byteCount == png.count,
              try library.sharedSends(peer).isEmpty else { throw RelayFailure.invalid }

        let privateItem = NSPasteboardItem()
        privateItem.setString("Private", forType: .string)
        privateItem.setString("", forType: .init("org.nspasteboard.ConcealedType"))
        pasteboard.clearContents()
        guard pasteboard.writeObjects([privateItem]),
              (try? model.recordClipboardCopies(in: pasteboard, source: "QA")) == nil,
              model.rows.count == 3 else { throw RelayFailure.invalid }

        func captureText(_ value: String) throws {
            pasteboard.clearContents()
            guard pasteboard.setString(value, forType: .string) else { throw RelayFailure.invalid }
            try model.recordClipboardCopies(in: pasteboard, source: "QA")
        }
        try captureText("Keep one copy")
        guard let original = model.rows.first else { throw RelayFailure.invalid }
        try captureText("Newer copy")
        try library.pin(original.id)
        model.reload()
        let movesWhenPinned = model.rows.first?.id == original.id && model.rows.first?.pinned == true
        try captureText("Keep one copy")
        let matches = model.rows.filter { $0.name == "Keep one copy" }
        guard matches.map(\.id) == [original.id], matches.first?.pinned == true,
              try library.sharedSends(peer).isEmpty else {
            print("FAIL copying identical content must reuse its pinned history entry without queuing a delivery")
            throw RelayFailure.invalid
        }
        guard movesWhenPinned else {
            print("FAIL pinned items must appear before newer unpinned items")
            throw RelayFailure.invalid
        }
        try library.pin(original.id)
        model.reload()
        guard model.rows.first?.id == original.id, model.rows.first?.pinned == false else {
            print("FAIL recopying must refresh the item's recency after unpinning")
            throw RelayFailure.invalid
        }
        print("PASS duplicate clipboard copies, pin ordering and local capture without a send queue")
    }
    private static func checkSettings(in root: URL) throws {
        let library = try Library(root)
        let peer = try Identity(secret: Data(repeating: 8, count: 32), name: "Settings peer").peer
        try library.pair(peer)
        guard let paired = try library.pairingDate(peer),
              abs(paired.timeIntervalSinceNow) < 5 else { throw RelayFailure.invalid }

        let defaults = UserDefaults.standard
        let key = "mac.historyRetentionHours"
        let domain = UserDefaults.argumentDomain
        let previous = defaults.volatileDomain(forName: domain)
        defer { defaults.setVolatileDomain(previous, forName: domain) }
        var overrides = previous
        overrides[key] = 0
        defaults.setVolatileDomain(overrides, forName: domain)
        var old = Clip.text("Old item")
        old.date = Date.now.addingTimeInterval(-172_800)
        var pinned = Clip.text("Old pinned item")
        pinned.date = old.date
        let fresh = Clip.text("Fresh item")
        _ = try library.importArchive([(old, "QA", false), (pinned, "QA", true), (fresh, "QA", false)], sendToPeers: true)
        overrides[key] = 24
        defaults.setVolatileDomain(overrides, forName: domain)
        let ids = try Set(library.page().map(\.id))
        guard ids == [pinned.id.uuidString, fresh.id.uuidString] else { throw RelayFailure.invalid }

        try library.clearHistory()
        guard try library.page().isEmpty, try library.sharedSends(peer).isEmpty,
              try library.pairingDate(peer) == paired else { throw RelayFailure.invalid }
        try library.unpair(peer)
        guard try library.pairingDate(peer) == nil,
              MacHistoryPrivacy.isMasked("验证码：432198", sensitive: false, codes: true, forDetail: true),
              !MacHistoryPrivacy.isMasked("密码：example", sensitive: true, codes: false, forDetail: true),
              !MacHistoryPrivacy.isMasked("ordinary clipboard text", sensitive: true, codes: true, forDetail: false)
        else { throw RelayFailure.invalid }
        print("PASS Mac pairing dates, history retention, wipe and masking")
    }

}
#endif
