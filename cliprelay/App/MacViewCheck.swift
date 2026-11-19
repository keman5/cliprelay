#if os(macOS) && DEBUG
import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum MacViewCheck {
    @MainActor static func run() throws {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        let model = Model()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try checkClipboard(model, in: root)
        try checkExclusions()
        let rect = NSRect(x: -4000, y: -4000, width: 640, height: 540)
        let window = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: true)
        for tab in 0..<3 {
            let home = NSHostingView(rootView: Home(model: model, initialTab: tab))
            window.contentView = home
            home.layoutSubtreeIfNeeded()
            guard home.fittingSize.width >= 520, home.fittingSize.height >= 420, !window.isVisible else {
                throw RelayFailure.invalid
            }
        }
        let menu = NSHostingView(rootView: MenuContent(model: model))
        window.contentView = menu
        menu.layoutSubtreeIfNeeded()
        guard menu.fittingSize.width > 0, menu.fittingSize.height > 0, !window.isVisible else {
            throw RelayFailure.invalid
        }
        print("PASS hidden Mac history, devices, settings and menu layout")
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
}
#endif
