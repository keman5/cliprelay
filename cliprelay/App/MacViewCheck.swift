#if os(macOS) && DEBUG
import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum MacViewCheck {
    private final class HiddenFocusWindow: NSWindow {
        override var isKeyWindow: Bool { true }
    }
    @MainActor static func run() throws {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        let model = Model()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try checkClipboard(model, in: root)
        try checkItemActions(in: root.appendingPathComponent("actions"))
        try checkCopyOrder(in: root.appendingPathComponent("copy-order"))
        try checkExclusions()
        try checkSettings(in: root.appendingPathComponent("settings"))
        let size = NSSize(width: 980, height: 600)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -4000, y: -4000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        for page in MacWorkspace.Page.allCases {
            try render(MacWorkspace(model: model, initialPage: page), size: size, in: window, name: String(describing: page))
        }
        try render(MenuContent(model: model), size: NSSize(width: 480, height: 540), in: window, name: "menu")
        let long = Clip.text(String(repeating: "A long clipboard entry for checking the preview scroll area.\n", count: 36))
        try model.library?.save(long, source: "TextEdit")
        model.reload()
        try render(MacWorkspace(model: model), size: NSSize(width: 860, height: 520), in: window, name: "history-long")
        if let detail = try model.library?.macHistory().first {
            try render(MacClipDetail(model: model, row: detail), size: NSSize(width: 374, height: 510), in: window, name: "menu-detail-long")
        }
        print("PASS hidden Mac workspace pages and menu layout")
        try checkWorkspaceFocus(model, size: size)
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
        try model.recordClipboardCopies(in: pasteboard, source: "QA", sendToPeers: true)
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
        try model.recordClipboardCopies(in: pasteboard, source: "QA", sendToPeers: true)
        guard let imageRow = model.rows.first, imageRow.kind == "Image" else { throw RelayFailure.invalid }
        let attachment = ClipAttachment(try library.clip(imageRow.id))
        guard attachment.thumbnail?.width == 4, attachment.byteCount == png.count,
              Set(try library.sharedSends(peer)) == Set(model.rows.map(\.id)) else { throw RelayFailure.invalid }

        let privateItem = NSPasteboardItem()
        privateItem.setString("Private", forType: .string)
        privateItem.setString("", forType: .init("org.nspasteboard.ConcealedType"))
        pasteboard.clearContents()
        guard pasteboard.writeObjects([privateItem]),
              (try? model.recordClipboardCopies(in: pasteboard, source: "QA", sendToPeers: true)) == nil,
              model.rows.count == 3 else { throw RelayFailure.invalid }

        func captureText(_ value: String) throws {
            pasteboard.clearContents()
            guard pasteboard.setString(value, forType: .string) else { throw RelayFailure.invalid }
            try model.recordClipboardCopies(in: pasteboard, source: "QA", sendToPeers: true)
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
              try Set(library.sharedSends(peer)) == Set(model.rows.map(\.id)) else {
            print("FAIL copying identical content must reuse its pinned history entry and pending job")
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
        print("PASS duplicate clipboard copies, pin ordering and queued item identity")
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
