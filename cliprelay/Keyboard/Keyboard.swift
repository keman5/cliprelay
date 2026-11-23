import UIKit
import UniformTypeIdentifiers
import NaturalLanguage

final class Keyboard: UIInputViewController {
    private let stack = UIStackView()
    private var panelHeight: NSLayoutConstraint!
    private var expanded: String?
    private var pinnedOnly = false
    private var draft: SavedPhrase?
    private var editingExisting = false
    private enum DraftField { case body, code, folder }
    private var draftField = DraftField.body
    private var bodyOffset = 0
    private var splitText: String?
    private var listOffset: CGPoint = .zero
    private weak var listScroll: UIScrollView?
    private weak var openSwipe: SwipeRow?
    private var numbers = false
    private static func color(_ light: CGFloat, _ dark: CGFloat) -> UIColor {
        UIColor { UIColor(white: ($0.userInterfaceStyle == .dark ? dark : light) / 255, alpha: 1) }
    }
    private let board = Keyboard.color(214, 34)
    private let cap = Keyboard.color(255, 93)
    private let tool = Keyboard.color(187, 67)
    private let tile = Keyboard.color(248, 73)
    private let ink = Keyboard.color(30, 250)
    private let muted = Keyboard.color(104, 166)
    private let accent = UIColor(red: 1, green: 0.51, blue: 0.13, alpha: 1)
    private var clips=true, chinese=false, shifted=false, symbols=false
    private var query="", page=0, filter="", candidatePage=0
    private var hint=""
    private var library: Library?
    private var lastSetupResponse: String?
    private lazy var dictionary: [String:String] = {
        guard let url=Bundle.main.url(forResource:"pinyin",withExtension:"json"),let data=try? Data(contentsOf:url) else {return [:]}
        return (try? JSONDecoder().decode([String:String].self,from:data)) ?? [:]
    }()
    private let phrases=["nihao":["你好","您好"],"xiexie":["谢谢"],"zaijian":["再见"],"shurufa":["输入法"],"jiantieban":["剪贴板"],"tongbu":["同步"],"suitie":["随贴"],"zhongguo":["中国"],"women":["我们"],"meiyou":["没有"]]
    private let localize = ClipRelayPreferences.localized
    override func viewDidLoad() {
        super.viewDidLoad()
        stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        view.backgroundColor = board
        panelHeight = view.heightAnchor.constraint(equalToConstant: 270)
        panelHeight.priority = .defaultHigh
        NSLayoutConstraint.activate([panelHeight, stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor), stack.trailingAnchor.constraint(equalTo: view.trailingAnchor)])
        render()
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        clips = ClipRelayPreferences.keyboardStartsWithClipboard
        chinese = ClipRelayPreferences.defaults.string(forKey: "keyboard.inputLanguage") == "pinyin"
        numbers = false; shifted = false; symbols = false
        page = 0
        draft = nil; splitText = nil; expanded = nil; listOffset = .zero
        hint = ""
        library = hasFullAccess && !ClipRelayPreferences.historyLocked ? try? Library(Library.directory()) : nil
        if ClipRelayPreferences.historyLocked { hint = localize("Unlock history in ClipRelay") }
        switch ClipRelayPreferences.theme {
        case "light": overrideUserInterfaceStyle = .light
        case "dark": overrideUserInterfaceStyle = .dark
        default:
            switch textDocumentProxy.keyboardAppearance {
            case .dark: overrideUserInterfaceStyle = .dark
            case .light: overrideUserInterfaceStyle = .light
            default: overrideUserInterfaceStyle = .unspecified
            }
        }
        render()
    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        clearQuery()
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !answerSetupCheck() { captureClipboard() }
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        answerSetupCheck()
    }

    @discardableResult
    private func answerSetupCheck() -> Bool {
        guard let challenge = KeyboardSetupCheck.activeChallenge,
              let context = textDocumentProxy.documentContextBeforeInput,
              textDocumentProxy.documentContextAfterInput?.isEmpty != false else { return false }
        if KeyboardSetupCheck.result(from: context, for: challenge) != nil { return true }
        guard context == challenge else { return false }
        guard lastSetupResponse != challenge else { return true }
        lastSetupResponse = challenge
        // The probe is a field in ClipRelay seeded with the current App Group challenge.
        let response = KeyboardSetupCheck.response(to: challenge, fullAccess: hasFullAccess)
        textDocumentProxy.insertText(String(response.dropFirst(challenge.count)))
        return true
    }

    private func captureClipboard() {
        guard hasFullAccess, ClipRelayPreferences.keyboardCapturesClipboard, let library else { return }
        let pasteboard = UIPasteboard.general
        let version = pasteboard.changeCount
        guard !ClipRelayPreferences.skipPausedCopy(version: version, key: ClipRelayPreferences.keyboardCaptureKey) else { return }
        guard version != ClipRelayPreferences.keyboardPasteboardVersion, pasteboard.hasStrings else { return }
        guard ClipboardPaste.privateTypes.isDisjoint(with: pasteboard.types), !pasteboard.hasImages, !pasteboard.hasURLs else {
            ClipRelayPreferences.keyboardPasteboardVersion = version
            return
        }
        guard let text = pasteboard.string else {
            // UIKit does not expose whether a failed pasteboard read was denied.
            ClipRelayPreferences.keyboardCapturesClipboard = false
            hint = localize("Pasteboard capture paused")
            render()
            return
        }
        guard pasteboard.changeCount == version else { return }
        ClipRelayPreferences.keyboardPasteboardVersion = version
        guard !text.isEmpty, text.utf8.count <= Clip.limit else { return }
        do {
            let clip = Clip.text(text)
            let send = ClipRelayPreferences.keyboardSendsClipboard
            let ids = try library.saveCopies([clip], source: "Keyboard", sendToPeers: send, privateToDevice: !send)
            if send { Task { await ExtensionDelivery.attempt(library, ids: ids) } }
            page = 0
        } catch {
            hint = error.localizedDescription
        }
        render()
    }
    private enum IconRole: CGFloat { case toolbar = 16, circle = 13, action = 12, disclosure = 9 }
    private func glyph(_ name: String, role: IconRole) -> UIImage? {
        let side = role.rawValue
        guard let source = UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .regular)) else { return nil }
        let scale = side / max(source.size.width, source.size.height)
        let size = CGSize(width: source.size.width * scale, height: source.size.height * scale)
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
            source.draw(in: CGRect(x: (side - size.width)/2, y: (side - size.height)/2, width: size.width, height: size.height))
        }.withRenderingMode(.alwaysTemplate)
    }
    private func button(_ title: String = "", icon: String? = nil, name: String? = nil, size: CGFloat = 17, role: IconRole = .toolbar,
                        action: @escaping (Keyboard) -> Void) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(title, for: .normal)
        if let icon { b.setImage(glyph(icon, role: role), for: .normal) }
        b.setTitleColor(ink, for: .normal)
        b.tintColor = ink
        b.titleLabel?.font = .systemFont(ofSize: size)
        b.titleLabel?.adjustsFontSizeToFitWidth = true
        b.accessibilityLabel = name ?? title
        b.addAction(UIAction { [weak self] _ in if let self { action(self) } }, for: .touchUpInside)
        return b
    }

    private func key(_ title: String, hint: String = "", special: Bool = false,
                     icon: String? = nil, name: String? = nil, action: @escaping (Keyboard) -> Void) -> UIButton {
        let b = button(title, icon: icon, name: name, size: special ? 16 : 20, action: action)
        b.backgroundColor = special ? tool : cap
        b.layer.cornerRadius = 5
        b.layer.shadowOffset = CGSize(width: 0, height: 1)
        b.layer.shadowRadius = 0.45
        b.layer.shadowOpacity = 0.24
        if !hint.isEmpty {
            let legend = UILabel()
            legend.text = hint
            legend.font = .systemFont(ofSize: 8)
            legend.textColor = muted
            legend.isAccessibilityElement = false
            legend.translatesAutoresizingMaskIntoConstraints = false
            b.addSubview(legend)
            NSLayoutConstraint.activate([legend.centerXAnchor.constraint(equalTo: b.centerXAnchor), legend.topAnchor.constraint(equalTo: b.topAnchor, constant: 1)])
            b.contentEdgeInsets.top = 6
        }
        return b
    }

    private func horizontal(_ views: [UIView], gap: CGFloat = 0) -> UIStackView {
        let row = UIStackView(arrangedSubviews: views)
        row.spacing = gap
        return row
    }
    private func clearQuery() {query="";candidatePage=0}
    private func options()->[String] {
        var result = draft == nil && !query.isEmpty ? ((try? library?.phrases(limit: 4, code: query)) ?? []).map(\.text) : []
        result += phrases[query] ?? []
        result += (dictionary[query] ?? "").map(String.init)
        if result.isEmpty && !query.isEmpty {
            // shortcut: use the highest-ranked character per syllable until a phrase lexicon is available
            let letters = Array(query)
            var suffixes = Array<String?>(repeating: nil, count: letters.count + 1)
            suffixes[letters.count] = ""
            for start in letters.indices.reversed() {
                for end in ((start + 1)...min(start + 6, letters.count)).reversed() {
                    let syllable = String(letters[start..<end])
                    if let first = dictionary[syllable]?.first, let tail = suffixes[end] {
                        suffixes[start] = String(first) + tail
                        break
                    }
                }
            }
            if let phrase = suffixes.first ?? nil { result = [phrase] }
        }
        return result
    }
    private func writeText(_ value: String) {
        guard draft != nil else { textDocumentProxy.insertText(value); return }
        switch draftField {
        case .body:
            guard var text = draft?.text else { return }
            let addition = value.prefix(max(0, 500-text.count))
            text.insert(contentsOf: addition, at: text.index(text.startIndex, offsetBy: min(bodyOffset,text.count)))
            bodyOffset += addition.count; draft?.text = text
        case .code: let code = (draft?.code ?? "") + value.lowercased(); draft?.code = String(code.filter { $0.isASCII && $0.isLetter }.prefix(10))
        case .folder: let folder = (draft?.folder ?? "") + value; draft?.folder = String(folder.prefix(32))
        }
    }
    private func eraseText() {
        guard var value = draft else { textDocumentProxy.deleteBackward(); return }
        switch draftField {
        case .body:
            if bodyOffset > 0 { bodyOffset -= 1; value.text.remove(at: value.text.index(value.text.startIndex, offsetBy: bodyOffset)) }
        case .code: if !value.code.isEmpty { value.code.removeLast() }
        case .folder: if !value.folder.isEmpty { value.folder.removeLast() }
        }
        draft = value
    }
    private func insert(_ value:String) {writeText(value);clearQuery();render()}
    private func render() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        view.backgroundColor = clips ? Self.color(240, 37) : board
        panelHeight.constant = draft != nil ? (traitCollection.verticalSizeClass == .compact ? 275 : 423) : clips ? 270 : 244
        if draft != nil { editorPanel(); typingPanel() }
        else if let splitText { wordPanel(splitText) }
        else if clips { clipboardPanel() } else { typingPanel() }
    }

    private func typingPanel() {
        let bar: UIStackView
        if chinese && !query.isEmpty {
            let choices = options()
            let next = button(icon: "chevron.down", name: localize("Next candidates")) { k in
                k.candidatePage = (k.candidatePage + 1) % max(1, (choices.count + 3) / 4)
                k.render()
            }
            next.isEnabled = choices.count > 4
            var items: [UIView] = [button(query) { $0.insert($0.query) }]
            items += choices.dropFirst(candidatePage * 4).prefix(4).map { word in button(word) { $0.insert(word) } }
            items += [UIView(), next]
            bar = horizontal(items, gap: 12)
        } else {
            let home = button(icon: "paperclip", name: localize("Clipboard"), size: 22) { k in k.clips = true; k.render() }
            home.tintColor = accent
            let emoji = button(icon: "face.smiling", name: localize("Emoji"), size: 22) { _ in }
            emoji.menu = UIMenu(children: ["☺︎","♥","👍","🎉","🙂"].map { mark in UIAction(title: mark) { [weak self] _ in self?.insert(mark) } })
            emoji.showsMenuAsPrimaryAction = true
            let pin = button(icon: "pin", name: localize("Phrases"), size: 21) { k in k.pinnedOnly = true; k.clips = true; k.page = 0; k.render() }
            let globe = button(icon: "keyboard", name: localize("Next keyboard"), size: 21) { _ in }
            globe.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
            let clip = button(icon: "scissors", name: localize("Clipboard"), size: 22) { k in k.pinnedOnly = false; k.clips = true; k.render() }
            let hide = button(icon: "chevron.down", name: localize("Hide keyboard")) { $0.dismissKeyboard() }
            let tools = horizontal([home, emoji, pin, globe, clip])
            if draft != nil {
                for item in [home,pin,clip] { item.isEnabled = false }
            }
            tools.distribution = .fillEqually
            bar = horizontal([tools, UIView(), hide])
            tools.widthAnchor.constraint(equalTo: bar.widthAnchor, multiplier: 0.72).isActive = true
            hide.widthAnchor.constraint(equalTo: bar.widthAnchor, multiplier: 0.145).isActive = true
        }
        bar.heightAnchor.constraint(equalToConstant: 41).isActive = true
        stack.addArrangedSubview(bar)
        let rows = UIStackView()
        rows.axis = .vertical
        rows.distribution = .fillEqually
        rows.spacing = 10
        rows.isLayoutMarginsRelativeArrangement = true
        rows.directionalLayoutMargins = .init(top: 5, leading: 4, bottom: 4, trailing: 4)
        stack.addArrangedSubview(rows)
        let alphabet = ["QWERTYUIOP","ASDFGHJKL","ZXCVBNM"]
        let labels = numbers ? ["1234567890","+-×÷%=()/",".,:;?!#"] : symbols ? ["!@#$%^&*()","[]{}«»+=~","_—/:;?!"] : alphabet
        let legends = ["1234567890","~/:;()@“”","-—#?!，。"]
        for (i, letters) in labels.enumerated() {
            let rowKeys = letters.enumerated().map { j, letter in
                key(String(letter), hint: symbols || numbers ? "" : String(Array(legends[i])[j])) { k in
                    if k.chinese && !k.symbols && !k.numbers && (k.draft == nil || k.draftField != .code) {
                        k.query = String((k.query + letter.lowercased()).prefix(48))
                        k.candidatePage = 0
                    } else {
                        k.writeText(k.shifted ? String(letter) : letter.lowercased())
                        k.shifted = false
                    }
                    k.render()
                }
            }
            var keys = rowKeys
            if i == 2 {
                let shift = key("", special: true, icon: shifted ? "shift.fill" : "shift", name: localize("Shift")) { k in
                    if k.chinese { k.commit(); k.chinese = false }
                    k.shifted.toggle(); k.render()
                }
                let delete = key("", special: true, icon: "delete.left", name: localize("Delete")) { k in
                    if k.query.isEmpty { k.eraseText(); k.render() }
                    else { k.query.removeLast(); k.candidatePage = 0; k.render() }
                }
                keys = [shift] + keys + [delete]
            }
            let line = horizontal(keys, gap: 7)
            if i == 2, let shift = keys.first, let delete = keys.last {
                shift.widthAnchor.constraint(equalTo: rowKeys[0].widthAnchor, multiplier: 1.38).isActive = true
                delete.widthAnchor.constraint(equalTo: shift.widthAnchor).isActive = true
            }
            for b in rowKeys.dropFirst() { b.widthAnchor.constraint(equalTo: rowKeys[0].widthAnchor).isActive = true }
            if i == 1 {
                line.isLayoutMarginsRelativeArrangement = true
                line.directionalLayoutMargins = .init(top: 0, leading: 20, bottom: 0, trailing: 20)
            }
            rows.addArrangedSubview(line)
        }
        let punctuation = key(symbols ? "ABC" : localize("Symbol key"), special: true) { k in
            k.commit(); k.numbers = false; k.symbols.toggle(); k.render()
        }
        let digits = key(numbers ? "ABC" : "123", special: true) { k in
            k.commit(); k.symbols = false; k.numbers.toggle(); k.render()
        }
        let comma = key(chinese ? "，" : ",", hint: chinese ? "。" : ".") { k in k.commit(); k.insert(k.chinese ? "，" : ",") }
        let space = key("", icon: "space", name: localize("Space")) { k in
            if k.query.isEmpty { k.insert(" ") } else { k.commit(); k.render() }
        }
        space.tintColor = muted
        let language = key(chinese ? "中ᴱᴺ" : "EN中", special: true, name: localize(chinese ? "Switch to English" : "Switch to Chinese")) { k in
            k.commit(); k.chinese.toggle(); k.symbols = false; k.numbers = false; k.shifted = false; k.render()
        }
        let enter = key(returnLabel, special: true, name: localize("Return")) { k in
            if k.query.isEmpty { k.insert("\n") } else { k.insert(k.query) }
        }
        if draft != nil { enter.backgroundColor = accent; enter.setTitleColor(.white, for: .normal) }
        let bottom = horizontal([punctuation, digits, comma, space, language, enter], gap: 7)
        for (b, fraction) in [(punctuation, 0.117), (digits, 0.101), (comma, 0.084), (language, 0.101), (enter, 0.202)] {
            b.widthAnchor.constraint(equalTo: bottom.widthAnchor, multiplier: fraction).isActive = true
        }
        rows.addArrangedSubview(bottom)
    }
    private var returnLabel: String {
        switch textDocumentProxy.returnKeyType {
        case .send: return localize("Send")
        case .done: return localize("Done")
        case .search: return localize("Search")
        case .go: return localize("Go")
        default: return localize("Return")
        }
    }

    private func clipboardPanel() {
        let back = button(icon: "chevron.left", name: localize("Keyboard"), size: 18) { k in k.clips = false; k.render() }
        let tabs = UIStackView()
        tabs.distribution = .fillEqually
        tabs.backgroundColor = cap
        tabs.layer.cornerRadius = 17
        for (index, title) in ["Clipboard", "Phrases"].enumerated() {
            let tab = button(localize(title), size: 14) { k in
                k.pinnedOnly = index == 1; k.filter = ""; k.page = 0; k.expanded = nil; k.hint = ""; k.listOffset = .zero; k.render()
            }
            if pinnedOnly == (index == 1) {
                tab.backgroundColor = accent; tab.layer.cornerRadius = 17
                tab.setTitleColor(.white, for: .normal); tab.accessibilityTraits.insert(.selected)
            }
            tabs.addArrangedSubview(tab)
        }
        let filterKey = button(icon: pinnedOnly ? "plus" : "checklist", name: localize(pinnedOnly ? "Add phrase" : "Filter"), role: .circle) { k in
            if k.pinnedOnly { k.startDraft(SavedPhrase(), editing: false) }
        }
        if !pinnedOnly { filterKey.menu = UIMenu(children: ["","Pinned","Text","Rich text","Image","File"].map { kind in
            UIAction(title: localize(kind.isEmpty ? "All" : kind), state: filter == kind ? .on : .off) { [weak self] _ in
                self?.pinnedOnly = false; self?.filter = kind; self?.page = 0; self?.render()
            }
        })
        filterKey.showsMenuAsPrimaryAction = true }
        filterKey.isEnabled = !pinnedOnly || library != nil
        let gear = button(icon: "gearshape", name: localize("Settings"), role: .circle) { _ in }
        gear.menu = UIMenu(children: [UIAction(title: localize("Keyboard"), image: UIImage(systemName: "keyboard")) { [weak self] _ in self?.clips = false; self?.render() },
                                      UIAction(title: localize("Next keyboard"), image: UIImage(systemName: "globe")) { [weak self] _ in self?.advanceToNextInputMode() }])
        gear.showsMenuAsPrimaryAction = true
        let head = UIView()
        for control in [back, tabs, filterKey, gear] as [UIView] {
            control.translatesAutoresizingMaskIntoConstraints = false; head.addSubview(control)
            control.centerYAnchor.constraint(equalTo: head.centerYAnchor).isActive = true
        }
        for b in [filterKey,gear] {
            let circle = UIView(); circle.backgroundColor = cap; circle.layer.cornerRadius = 14
            circle.isUserInteractionEnabled = false; circle.translatesAutoresizingMaskIntoConstraints = false
            head.insertSubview(circle, at: 0)
            NSLayoutConstraint.activate([b.widthAnchor.constraint(equalToConstant: 44), b.heightAnchor.constraint(equalToConstant: 44),
                circle.centerXAnchor.constraint(equalTo: b.centerXAnchor), circle.centerYAnchor.constraint(equalTo: b.centerYAnchor),
                circle.widthAnchor.constraint(equalToConstant: 28), circle.heightAnchor.constraint(equalToConstant: 28)])
        }
        NSLayoutConstraint.activate([head.heightAnchor.constraint(equalToConstant: 47),
            back.leadingAnchor.constraint(equalTo: head.leadingAnchor, constant: 4), back.widthAnchor.constraint(equalToConstant: 36), back.heightAnchor.constraint(equalTo: head.heightAnchor),
            tabs.centerXAnchor.constraint(equalTo: head.centerXAnchor), tabs.widthAnchor.constraint(equalTo: head.widthAnchor, multiplier: 0.41),
            tabs.heightAnchor.constraint(equalToConstant: 33), gear.trailingAnchor.constraint(equalTo: head.trailingAnchor, constant: -6),
            filterKey.trailingAnchor.constraint(equalTo: gear.leadingAnchor)])
        stack.addArrangedSubview(head)
        let count = (try? pinnedOnly ? library?.phraseCount() : library?.recordCount(kind: filter)) ?? 0
        page = min(page, max(0, (count-1)/30))
        let records = pinnedOnly ? [] : (try? library?.page(kind: filter, offset: page * 30, pinnedFirst: true)) ?? []
        let saved = pinnedOnly ? (try? library?.phrases(offset: page*30)) ?? [] : []
        let caption = UILabel()
        caption.textAlignment = .center; caption.textColor = muted; caption.font = .systemFont(ofSize: 11)
        caption.text = hint.isEmpty ? String(format: localize("Item capacity"), count, max(1000,count)) : hint
        stack.addArrangedSubview(caption)
        caption.heightAnchor.constraint(equalToConstant: 17).isActive = true
        let scroll = UIScrollView(), lines = UIStackView()
        listScroll = scroll
        lines.axis = .vertical; lines.spacing = 5; lines.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(lines); stack.addArrangedSubview(scroll)
        NSLayoutConstraint.activate([lines.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 3),
            lines.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -3),
            lines.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 13),
            lines.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -13),
            lines.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -26)])
        for record in records {
            let text = expanded == record.id ? (try? library?.clip(record.id).text) : nil
            let title = text ?? record.name
            let masked = MacHistoryPrivacy.isMasked(title, sensitive: ClipRelayPreferences.defaults.object(forKey: "phone.maskSensitive") as? Bool ?? true,
                codes: ClipRelayPreferences.defaults.bool(forKey: "phone.maskCodes"), forDetail: expanded == record.id)
            let card = itemCard(id: record.id, title: masked ? "••••••" : title, kind: record.kind, select: { $0.select(record) })
            let addPhrase: (Keyboard) -> Void = { k in
                guard let body = try? k.library?.clip(record.id).text else { return }
                k.startDraft(SavedPhrase(text: body), editing: false)
            }
            let pinTitle = record.pinned ? "Unpin" : "Pin"
            let pinSymbol = record.pinned ? "pin.slash" : "pin"
            let pinAction: (Keyboard) -> Void = { k in
                k.change { try k.library?.pin(record.id); k.page = 0; k.listOffset = .zero }
            }
            let wrapper = record.fromHub ? nil : swipeCard(card, first: ("Add phrase","text.badge.plus",addPhrase),
                pin: (pinTitle, pinSymbol), canAdd: !masked && ["Text","Rich text"].contains(record.kind),
                pinAction: pinAction,
                delete: { k in k.change { try k.library?.delete(record.id) } })
            if expanded == record.id {
                let add = action("Phrases", "plus") { k in
                    guard let text else { return }
                    k.startDraft(SavedPhrase(text: text), editing: false)
                }
                let words = action("Split words", "character.textbox") { k in k.splitText = text; k.render() }
                add.isEnabled = text != nil && !masked; words.isEnabled = text != nil && !masked
                if let wrapper {
                    let remove = action("Delete", "trash") { [weak wrapper] _ in wrapper?.askDelete() }
                    addActions([add, words, action(pinTitle, pinSymbol, pinAction), remove], to: card)
                } else {
                    addActions([add, words], to: card)
                }
            }
            lines.addArrangedSubview(wrapper ?? card as UIView)
        }
        for phrase in saved {
            let id = phrase.id.uuidString
            let card = itemCard(id: id, title: phrase.text, select: { $0.insert(phrase.text) })
            let firstAction: (Keyboard) -> Void = { k in k.page = 0; k.listOffset = .zero; k.change { try k.library?.movePhraseFirst(phrase.id) } }
            let wrapper = swipeCard(card, first: ("Edit", "pencil", { $0.startDraft(phrase, editing: true) }),
                pin: ("Move to first","pin"), canAdd: true, pinAction: firstAction,
                delete: { k in k.change { try k.library?.deletePhrase(phrase.id) } })
            if expanded == id {
                let edit = action("Edit", "pencil") { $0.startDraft(phrase, editing: true) }
                let first = action("Move to first", "arrow.up.to.line") { k in k.page = 0; k.listOffset = .zero; k.change { try k.library?.movePhraseFirst(phrase.id) } }
                let remove = action("Delete", "trash") { [weak wrapper] _ in wrapper?.askDelete() }
                addActions([edit, first, remove], to: card)
            }
            lines.addArrangedSubview(wrapper)
        }
        if records.isEmpty && saved.isEmpty {
            let label = UILabel(); label.textAlignment = .center; label.textColor = muted
            label.text = localize(hasFullAccess ? "No items" : "Full access required")
            lines.addArrangedSubview(label)
        }
        if page > 0 || (page + 1) * 30 < count {
            let prev = button("‹", name: localize("Previous page")) { k in k.page -= 1; k.render() }
            let next = button("›", name: localize("Next page")) { k in k.page += 1; k.render() }
            prev.isEnabled = page > 0; next.isEnabled = (page + 1) * 30 < count
            let pager = horizontal([prev,next]); pager.distribution = .fillEqually; lines.addArrangedSubview(pager)
        }
        view.layoutIfNeeded()
        scroll.setContentOffset(CGPoint(x: 0, y: min(listOffset.y, max(0,scroll.contentSize.height-scroll.bounds.height))), animated: false)
    }
    private func swipeCard(_ card: UIView, first: (String,String,(Keyboard)->Void), pin: (String,String), canAdd: Bool,
                           pinAction: @escaping (Keyboard)->Void, delete: @escaping (Keyboard)->Void) -> SwipeRow {
        let add = button(icon: first.1, name: localize(first.0), action: first.2)
        add.backgroundColor = .systemGray; add.isEnabled = canAdd; add.tintColor = canAdd ? .white : .systemGray4
        let top = button(icon: pin.1, name: localize(pin.0), action: pinAction)
        top.backgroundColor = .systemOrange; top.tintColor = .white
        let remove = button(icon: "trash", name: localize("Delete")) { _ in }
        remove.backgroundColor = .systemRed; remove.tintColor = .white
        let confirm = button(localize("Confirm deletion"), size: 14, action: delete)
        confirm.backgroundColor = .systemRed; confirm.setTitleColor(.white, for: .normal)
        let row = SwipeRow(face: card, actions: [add,top,remove], confirm: confirm)
        remove.addAction(UIAction { [weak row] _ in row?.askDelete() }, for: .touchUpInside)
        row.willOpen = { [weak self] row in
            if self?.openSwipe !== row { self?.openSwipe?.close(); self?.openSwipe = row }
        }
        return row
    }
    private func action(_ title: String, _ symbol: String, _ handler: @escaping (Keyboard) -> Void) -> UIButton {
        let control = button(" " + localize(title), icon: symbol, name: localize(title), size: 12, role: .action, action: handler)
        control.tintColor = .secondaryLabel
        control.setTitleColor(.secondaryLabel, for: .normal)
        return control
    }
    private func change(_ body: () throws -> Void) {
        do { try body(); expanded = nil; hint = "" } catch { hint = error.localizedDescription }
        render()
    }
    private func itemCard(id: String, title: String, kind: String? = nil, select: @escaping (Keyboard) -> Void) -> UIStackView {
        let open = expanded == id
        let label = UILabel()
        label.text = String(title.prefix(open ? 8192 : 500))
        label.font = .systemFont(ofSize: 15); label.textColor = ink
        label.numberOfLines = open ? 0 : 2; label.lineBreakMode = open ? .byCharWrapping : .byTruncatingTail
        let content = button(name: label.text, action: select)
        let caption = UIStackView(arrangedSubviews: [label])
        caption.axis = .vertical
        caption.spacing = 2
        let body = horizontal([caption], gap: 9)
        body.alignment = .center
        body.isUserInteractionEnabled = false
        if (kind == "Image" || kind == "File"), let library {
            let preview = UIImageView(image: UIImage(systemName: kind == "Image" ? "photo" : "doc"))
            preview.contentMode = .scaleAspectFit
            preview.tintColor = .secondaryLabel
            preview.setContentHuggingPriority(.required, for: .horizontal)
            NSLayoutConstraint.activate([preview.widthAnchor.constraint(equalToConstant: 30),
                                         preview.heightAnchor.constraint(equalToConstant: 30)])
            body.insertArrangedSubview(preview, at: 0)
            let size = UILabel()
            size.font = .systemFont(ofSize: 11)
            size.textColor = .secondaryLabel
            size.isHidden = true
            caption.addArrangedSubview(size)
            Task { [weak preview, weak size, weak content] in
                guard let info = await ClipAttachment.load(id, from: library), let preview, let size else { return }
                preview.image = info.thumbnail.map { UIImage(cgImage: $0) } ?? UIImage(systemName: info.symbol)
                size.text = info.formattedSize
                size.isHidden = false
                content?.accessibilityValue = info.formattedSize
            }
        }
        content.addSubview(body); body.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([body.leadingAnchor.constraint(equalTo: content.leadingAnchor), body.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            body.topAnchor.constraint(equalTo: content.topAnchor, constant: 7), body.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -7)])
        let more = button(icon: open ? "chevron.up" : "chevron.down", name: localize("Details"), role: .disclosure) { k in
            k.listOffset = k.listScroll?.contentOffset ?? .zero; k.expanded = open ? nil : id; k.render()
        }
        more.tintColor = .tertiaryLabel; more.widthAnchor.constraint(equalToConstant: 40).isActive = true
        more.heightAnchor.constraint(equalToConstant: 40).isActive = true
        let line = horizontal([content, more]); line.alignment = .top
        line.isLayoutMarginsRelativeArrangement = true
        line.directionalLayoutMargins = .init(top: 1, leading: 13, bottom: 1, trailing: 1)
        let card = UIStackView(arrangedSubviews: [line]); card.axis = .vertical
        card.backgroundColor = cap; card.layer.cornerRadius = 7; card.clipsToBounds = true
        return card
    }
    private func addActions(_ buttons: [UIButton], to card: UIStackView) {
        let actions = horizontal(buttons + [UIView()], gap: 16)
        actions.isLayoutMarginsRelativeArrangement = true
        actions.directionalLayoutMargins = .init(top: 0, leading: 13, bottom: 0, trailing: 8)
        actions.heightAnchor.constraint(equalToConstant: 34).isActive = true
        card.addArrangedSubview(actions)
    }
    private func startDraft(_ phrase: SavedPhrase, editing: Bool) {
        guard library != nil else { return }
        draft = phrase; editingExisting = editing; draftField = .body; bodyOffset = phrase.text.count
        clearQuery(); hint = ""; render()
    }
    private func editorPanel() {
        guard let phrase = draft else { return }
        let cancel = button(icon: "chevron.down", name: localize("Cancel")) { k in k.draft = nil; k.clearQuery(); k.render() }
        let done = button(localize("Done"), size: 15) { k in
            k.commit()
            guard let phrase = k.draft, let library = k.library else { return }
            do {
                try library.savePhrase(phrase)
                k.draft = nil; k.pinnedOnly = true; k.page = 0; k.listOffset = .zero; k.expanded = phrase.id.uuidString; k.hint = ""
            } catch { k.hint = error.localizedDescription }
            k.render()
        }
        done.isEnabled = (try? phrase.validate()) != nil || !query.isEmpty
        let title = UILabel(); title.text = localize(editingExisting ? "Edit phrase" : "Add phrase")
        title.font = .systemFont(ofSize: 17, weight: .medium); title.textAlignment = .center
        let header = horizontal([cancel,title,done]); stack.addArrangedSubview(header)
        cancel.widthAnchor.constraint(equalToConstant: 56).isActive = true; done.widthAnchor.constraint(equalTo: cancel.widthAnchor).isActive = true
        header.heightAnchor.constraint(equalToConstant: 44).isActive = true
        let area = UIStackView(); area.axis = .vertical; area.isLayoutMarginsRelativeArrangement = true
        area.directionalLayoutMargins = .init(top: 2, leading: 16, bottom: 9, trailing: 16)
        let card = UIStackView(); card.axis = .vertical; card.backgroundColor = cap; card.layer.cornerRadius = 7; card.clipsToBounds = true
        let field = UITextView(); field.backgroundColor = .clear; field.isEditable = false; field.isSelectable = false
        field.font = .systemFont(ofSize: 16); field.textContainerInset = .init(top: 9, left: 9, bottom: 0, right: 9)
        let placeholder = phrase.text.isEmpty
        let display = NSMutableAttributedString(string: placeholder ? localize("Phrase placeholder") : phrase.text,
            attributes: [.font: UIFont.systemFont(ofSize: 16), .foregroundColor: placeholder ? UIColor.placeholderText : ink])
        let utf16Offset = phrase.text.prefix(bodyOffset).utf16.count
        if draftField == .body {
            display.insert(NSAttributedString(string: "▏", attributes: [.foregroundColor: accent, .font: UIFont.systemFont(ofSize: 16)]), at: utf16Offset)
        }
        field.attributedText = display; field.accessibilityLabel = localize("Phrases")
        field.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(placeCursor(_:))))
        card.addArrangedSubview(field)
        let counter = UILabel(); counter.text = hint.isEmpty ? "\(phrase.text.count)/500   " : hint
        counter.textAlignment = .right; counter.font = .systemFont(ofSize: 11); counter.textColor = .secondaryLabel
        card.addArrangedSubview(counter)
        let code = button(localize("Input code") + "  " + (phrase.code.isEmpty ? localize("10 letters") : phrase.code), size: 11) { k in k.commit(); k.draftField = .code; k.render() }
        let folder = button(localize("Folder") + "  " + (phrase.folder.isEmpty ? localize("Default") : phrase.folder), size: 11) { k in k.commit(); k.draftField = .folder; k.render() }
        for (b, active) in [(code, draftField == .code),(folder, draftField == .folder)] { b.setTitleColor(active ? accent : .secondaryLabel, for: .normal) }
        let metadata = horizontal([code,UIView(),folder]); metadata.isLayoutMarginsRelativeArrangement = true
        metadata.directionalLayoutMargins = .init(top: 0, leading: 12, bottom: 0, trailing: 12)
        metadata.backgroundColor = Self.color(248,52); metadata.heightAnchor.constraint(equalToConstant: 30).isActive = true
        card.addArrangedSubview(metadata); area.addArrangedSubview(card); stack.addArrangedSubview(area)
        area.heightAnchor.constraint(equalToConstant: traitCollection.verticalSizeClass == .compact ? 62 : 108).isActive = true
        if draftField == .body { field.layoutIfNeeded(); field.scrollRangeToVisible(NSRange(location: utf16Offset, length: 0)) }
    }
    @objc private func placeCursor(_ tap: UITapGestureRecognizer) {
        guard let field = tap.view as? UITextView, let text = draft?.text,
              let position = field.closestPosition(to: tap.location(in: field)) else { return }
        var offset = field.offset(from: field.beginningOfDocument, to: position)
        if draftField == .body && offset > text.prefix(bodyOffset).utf16.count { offset -= 1 }
        bodyOffset = (text as NSString).substring(to: min(max(0, offset), text.utf16.count)).count
        draftField = .body; clearQuery(); render()
    }
    private func wordPanel(_ text: String) {
        let back = button(icon: "chevron.left", name: localize("Clipboard")) { k in k.splitText = nil; k.render() }
        let title = UILabel(); title.text = localize("Split words"); title.textAlignment = .center
        let spacer = UIView(); let bar = horizontal([back,title,spacer]); stack.addArrangedSubview(bar)
        back.widthAnchor.constraint(equalToConstant: 44).isActive = true; spacer.widthAnchor.constraint(equalTo: back.widthAnchor).isActive = true
        bar.heightAnchor.constraint(equalToConstant: 44).isActive = true
        let scroll = UIScrollView(); let list = UIStackView(); list.axis = .vertical; list.spacing = 4
        stack.addArrangedSubview(scroll); scroll.addSubview(list); list.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([list.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor), list.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            list.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 13), list.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -13),
            list.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -26)])
        let sample = String(text.prefix(8192))
        let tokenizer = NLTokenizer(unit: .word); tokenizer.string = sample
        var count = 0
        tokenizer.enumerateTokens(in: sample.startIndex..<sample.endIndex) { range, _ in
            let word = String(sample[range]); let b = button(word) { k in k.textDocumentProxy.insertText(word) }
            b.backgroundColor = cap; b.layer.cornerRadius = 6; list.addArrangedSubview(b); count += 1
            return count < 256
        }
    }
    private func select(_ r:Summary) {
        guard let library, !ClipRelayPreferences.historyLocked else { return }
        do {
            func paste(_ clip: Clip) throws {
                if clip.kind == "Text", let text = clip.text { textDocumentProxy.insertText(text); return }
                guard hasFullAccess else { throw RelayFailure.unauthorized }
                var representations: [String: Any] = [clip.type: clip.bytes]
                if let plain = clip.plain { representations[UTType.utf8PlainText.identifier] = Data(plain.utf8) }
                let board = UIPasteboard.general
                board.setItems([representations], options: [.localOnly: true])
                ClipRelayPreferences.keyboardPasteboardVersion = board.changeCount
                ClipRelayPreferences.defaults.set(board.changeCount, forKey: "phone.captureVersion")
            }
            if r.fromHub { try paste(library.clip(r.id)) } else { try library.useClip(r.id, paste) }
            hint = localize("Copied")
        } catch { hint = error.localizedDescription }
        render()
    }
    private func commit() {
        guard !query.isEmpty else { return }
        writeText(options().first ?? query)
        clearQuery()
    }
}
