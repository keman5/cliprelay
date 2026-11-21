#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers

// AppKit delivers Edit > Paste, Command-V and the text context menu to the
// first responder. Keep the native text editor and handle attachments there.
struct MacComposerEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    let paste: (NSPasteboard) -> Void
    let submit: (String) -> Void

    private let font = NSFont.systemFont(ofSize: 13)

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay

        let editor = Editor()
        editor.drawsBackground = false
        editor.isRichText = false
        editor.allowsUndo = true
        editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.lineFragmentPadding = 0
        editor.font = font
        editor.textColor = .labelColor
        editor.insertionPointColor = .labelColor
        editor.setAccessibilityIdentifier("mac.history.composer")
        editor.setAccessibilityLabel(ClipRelayPreferences.localized("Type or paste content and press Return…"))
        editor.delegate = editor
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? Editor else { return }
        if editor.string != text { editor.string = text }
        editor.textChanged = { text = $0 }
        editor.focusChanged = { focused = $0 }
        editor.stagePaste = paste
        editor.submit = submit
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let lineHeight = ceil(NSLayoutManager().defaultLineHeight(for: font))
        let height = ((text + " ") as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font]
        ).height
        return CGSize(width: width, height: min(lineHeight * 3, max(lineHeight, ceil(height))) + 2)
    }

    private final class Editor: NSTextView, NSTextViewDelegate {
        var textChanged: ((String) -> Void)?
        var focusChanged: ((Bool) -> Void)?
        var stagePaste: ((NSPasteboard) -> Void)?
        var submit: ((String) -> Void)?

        private static let clipTypes: [NSPasteboard.PasteboardType] = [.fileURL, .rtf, .html, .png, .tiff]

        override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
            Self.clipTypes + super.readablePasteboardTypes.filter { !Self.clipTypes.contains($0) }
        }

        override func preferredPasteboardType(from availableTypes: [NSPasteboard.PasteboardType],
                                              restrictedToTypesFrom allowedTypes: [NSPasteboard.PasteboardType]?) -> NSPasteboard.PasteboardType? {
            if let type = availableTypes.first(where: { type in
                Self.isClipType(type) && (allowedTypes?.contains(type) ?? true)
            }) { return type }
            return super.preferredPasteboardType(from: availableTypes, restrictedToTypesFrom: allowedTypes)
        }

        override func paste(_ sender: Any?) {
            let pasteboard = NSPasteboard.general
            if isEditable, shouldStage(pasteboard), let stagePaste {
                stagePaste(pasteboard)
                return
            }
            guard isEditable, let type = pasteboard.types?.first(where: Self.isClipType) else {
                super.paste(sender)
                return
            }
            _ = readSelection(from: pasteboard, type: type)
        }

        override func readSelection(from pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
            guard Self.isClipType(type) || shouldStage(pasteboard), let stagePaste else {
                return super.readSelection(from: pasteboard, type: type)
            }
            stagePaste(pasteboard)
            return true
        }

        private func shouldStage(_ pasteboard: NSPasteboard) -> Bool {
            (pasteboard.pasteboardItems?.count ?? 0) > 1 || isPrivateClipboard(pasteboard)
        }

        private static func isClipType(_ type: NSPasteboard.PasteboardType) -> Bool {
            clipTypes.contains(type) || UTType(type.rawValue)?.conforms(to: .image) == true
        }

        func textDidChange(_ notification: Notification) {
            textChanged?(string)
        }

        override func becomeFirstResponder() -> Bool {
            guard super.becomeFirstResponder() else { return false }
            updateFocus()
            return true
        }

        override func resignFirstResponder() -> Bool {
            guard super.resignFirstResponder() else { return false }
            updateFocus()
            return true
        }

        private func updateFocus() {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                focusChanged?(window?.firstResponder === self)
            }
        }

        override func doCommand(by selector: Selector) {
            guard !hasMarkedText() else { return super.doCommand(by: selector) }
            switch selector {
            case #selector(insertNewline(_:)):
                if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                    super.doCommand(by: selector)
                } else {
                    submit?(string)
                }
            case #selector(insertTab(_:)): window?.selectNextKeyView(self)
            case #selector(insertBacktab(_:)): window?.selectPreviousKeyView(self)
            case #selector(cancelOperation(_:)): window?.makeFirstResponder(window)
            default: super.doCommand(by: selector)
            }
        }
    }
}
#endif
