#if os(macOS)
import AppKit
import Carbon
import SwiftUI
import UniformTypeIdentifiers

enum MacClipKind: String, CaseIterable, Identifiable {
    case text, link, code, image, document, pdf, archive
    var id: Self { self }
    var title: String {
        switch self {
        case .text: ClipRelayPreferences.localized("Text")
        case .link: ClipRelayPreferences.localized("Link")
        case .code: ClipRelayPreferences.localized("Code")
        case .image: ClipRelayPreferences.localized("Image")
        case .document: ClipRelayPreferences.localized("Document")
        case .pdf: "PDF"
        case .archive: ClipRelayPreferences.localized("Archive")
        }
    }
    var symbol: String {
        switch self {
        case .text: "textformat"
        case .link: "link"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .image: "photo"
        case .document: "doc.text"
        case .pdf: "doc.richtext"
        case .archive: "doc.zipper"
        }
    }
    var color: Color {
        switch self {
        case .text: .teal
        case .link: .blue
        case .code: .purple
        case .image: .pink
        case .document: .indigo
        case .pdf: .red
        case .archive: .orange
        }
    }
}

extension Summary {
    var macKind: MacClipKind {
        if kind == "Image" { return .image }
        if kind == "File" {
            let ext = (name as NSString).pathExtension.lowercased()
            let uti = type.flatMap { UTType($0) }
            if uti?.conforms(to: .pdf) == true || ext == "pdf" { return .pdf }
            if uti?.conforms(to: .archive) == true || ["zip", "rar", "7z", "tar", "gz", "bz2", "xz"].contains(ext) { return .archive }
            if ["swift", "js", "ts", "py", "go", "rs", "sh", "html", "css", "json"].contains(ext) { return .code }
            return .document
        }
        if let url = URL(string: name), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
           url.host != nil, !name.contains(where: \.isWhitespace) { return .link }
        if name.range(of: #"(?m)^(import |func |let |const |class |sudo |swift |npm |git |#!)|[{};].*[{};]"#, options: .regularExpression) != nil { return .code }
        return .text
    }

    var macFormat: String {
        if let type, let uti = UTType(type), !uti.isDynamic, uti != .data {
            if let ext = uti.preferredFilenameExtension { return ext.uppercased() }
            if let description = uti.localizedDescription { return description }
        }
        let ext = (name as NSString).pathExtension
        if kind == "File", !ext.isEmpty { return ext.uppercased() }
        return ClipRelayPreferences.localized(kind)
    }

    var macDisplayDate: Date? { lastCopied ?? date }
}

struct MacHistorySession {
    private(set) var rows: [Summary] = []

    mutating func update(_ latest: [Summary]) {
        rows = ordered(latest)
    }

    func ordered(_ latest: [Summary]) -> [Summary] {
        let previous = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        return latest.map { latestRow in
            guard let old = previous[latestRow.id] else { return latestRow }
            var row = latestRow
            row.historyRank = old.historyRank
            row.lastCopied = old.lastCopied
            return row
        }.sorted { first, second in
            if first.pinned != second.pinned { return first.pinned }
            return first.historyRank > second.historyRank
        }
    }
}

struct MacHistory: View {
    @ObservedObject var model: Model
    @Environment(\.colorScheme) private var scheme
    @FocusState private var focused: Field?
    @AppStorage("mac.maskSensitive") private var maskSensitive = true
    @AppStorage("mac.maskCodes") private var maskCodes = false
    @State private var history = MacHistorySession()
    @State private var matches: [Summary] = []
    @State private var query = ""
    @State private var kinds: Set<MacClipKind> = []
    @State private var pinnedOnly = false
    @State private var sources: Set<Source> = []
    @State private var selection: String?
    @State private var batch = false
    @State private var checked: Set<String> = []
    @State private var confirming = false
    @State private var filter: Filter?

    private enum Source: Hashable {
        case thisMac, peer(String)

        var title: String {
            switch self {
            case .thisMac: Host.current().localizedName ?? ClipRelayPreferences.localized("This Mac")
            case .peer(let name): name
            }
        }
    }
    private enum Field { case search, list }
    private enum Filter { case kind, source }
    private var palette: MacPalette { MacPalette(scheme) }
    private var all: [Summary] { history.rows }
    private var rows: [Summary] {
        (query.isEmpty ? all : matches).filter {
            matchesKind($0) && matchesSource($0)
        }
    }
    private func matchesKind(_ row: Summary) -> Bool {
        (!pinnedOnly && kinds.isEmpty) || kinds.contains(row.macKind) || (pinnedOnly && row.pinned)
    }
    private func matchesSource(_ row: Summary) -> Bool { sources.isEmpty || sources.contains(source(for: row)) }
    private func source(for row: Summary) -> Source {
        let received = row.received ?? model.peers.contains { $0.name == row.source }
        return received ? .peer(row.source) : .thisMac
    }
    private var selected: Summary? { rows.first { $0.id == selection } ?? rows.first }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                toolbar
                Divider()
                if batch { batchBar }
                historyList
                Divider()
                MacClipComposer(model: model)
            }
            .background(palette.surface)
            Divider()
            Group {
                if let selected {
                    MacClipDetail(model: model, row: selected, sourceName: source(for: selected).title,
                                  sourceApplication: source(for: selected) == .thisMac && selected.source != "Local" ? selected.source : nil,
                                  deleteShortcutEnabled: !batch && filter == nil && focused != .search)
                        .id(selected.id)
                } else {
                    Text("Select an item to view its details").foregroundStyle(palette.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: 318)
            .background(palette.surface)
        }
        .onReceive(model.$rows) { _ in reload() }
        .onDisappear { history = MacHistorySession() }
        .onChange(of: query) { _, _ in search() }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            if all.contains(where: { $0.expires.map { $0 <= .now } ?? false }) { model.reload() }
        }
        .onExitCommand {
            if filter != nil { filter = nil }
            else if focused != nil { focused = nil }
            else if batch { finishBatch() }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(palette.muted)
                TextField("Search history…", text: $query)
                    .textFieldStyle(.plain)
                    .focused($focused, equals: .search)
                    .accessibilityIdentifier("mac.history.search")
                    .macFeedbackTarget("history.search")
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(palette.muted).accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 9)
            .frame(width: 166, height: 32)
            .background(palette.raised, in: Capsule())
            .overlay { Capsule().strokeBorder(palette.line) }
            Button {
                if batch { finishBatch() } else { batch = true }
            } label: {
                Image(systemName: "checkmark")
                    .frame(width: 33, height: 32)
                    .background(batch ? palette.accentSoft : palette.raised, in: Circle())
                    .overlay { Circle().strokeBorder(batch ? palette.accent : palette.line) }
            }
            .buttonStyle(.plain)
            .help("Batch manage")
            .accessibilityLabel("Batch manage")
            filterButton(.kind, title: "Filter by type", symbol: "square.grid.2x2",
                         count: all.filter(matchesKind).count, active: !kinds.isEmpty || pinnedOnly)
            filterButton(.source, title: "Filter by source", symbol: "laptopcomputer.and.iphone",
                         count: all.filter(matchesSource).count, active: !sources.isEmpty)
            if pinnedOnly || !kinds.isEmpty || !sources.isEmpty {
                Button(action: clearFilters) { Image(systemName: "xmark.circle") }
                    .buttonStyle(.plain).help("Clear all filters").accessibilityLabel("Clear all filters")
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 13))
        .foregroundStyle(palette.text)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func filterButton(_ target: Filter, title: String, symbol: String, count: Int, active: Bool) -> some View {
        Button {
            filter = filter == target ? nil : target
        } label: {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                Text(count, format: .number).monospacedDigit()
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            .background(active ? palette.accentSoft : palette.raised, in: Capsule())
            .overlay { Capsule().strokeBorder(active ? palette.accent : palette.line) }
        }
        .buttonStyle(.plain)
        .help(Text(LocalizedStringKey(title)))
        .accessibilityLabel(Text(LocalizedStringKey(title)))
        .accessibilityValue("\(count) items")
        .popover(isPresented: Binding(get: { filter == target }, set: { if !$0 && filter == target { filter = nil } }), arrowEdge: .bottom) {
            filterPanel(target, title: title)
        }
    }

    private func filterPanel(_ target: Filter, title: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(LocalizedStringKey(title)).font(.headline)
                Spacer()
                Button("Reset") {
                    if target == .kind { kinds.removeAll(); pinnedOnly = false } else { sources.removeAll() }
                }.buttonStyle(.plain).foregroundStyle(palette.accent)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if target == .kind {
                        ForEach(MacClipKind.allCases) { kind in
                            filterOption(kind.title, symbol: kind.symbol, value: kind, picks: $kinds,
                                         count: all.filter { $0.macKind == kind }.count)
                        }
                        Toggle(isOn: $pinnedOnly) {
                            HStack {
                                Image(systemName: "pin").frame(width: 16)
                                Text("Pinned")
                                Spacer()
                                Text(all.filter(\.pinned).count, format: .number).foregroundStyle(.secondary)
                            }
                        }.toggleStyle(.checkbox)
                    } else {
                        let groups = Dictionary(grouping: all, by: source(for:))
                        ForEach(groups.keys.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }, id: \.self) { source in
                            filterOption(source.title, symbol: "laptopcomputer", value: source,
                                         picks: $sources, count: groups[source]?.count ?? 0)
                        }
                    }
                }
            }
            .frame(maxHeight: 250)
        }
        .padding(12)
        .frame(width: 232)
        .onExitCommand { filter = nil }
    }

    private func filterOption<Value: Hashable>(_ title: String, symbol: String, value: Value,
                                                picks: Binding<Set<Value>>, count: Int) -> some View {
        Toggle(isOn: Binding(get: { picks.wrappedValue.contains(value) }, set: { selected in
            if selected { picks.wrappedValue.insert(value) } else { picks.wrappedValue.remove(value) }
        })) {
            HStack {
                Image(systemName: symbol).frame(width: 16)
                Text(title).lineLimit(1)
                Spacer()
                Text(count, format: .number).foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.checkbox)
    }

    private var historyList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    if rows.isEmpty {
                        Text(query.isEmpty && kinds.isEmpty && !pinnedOnly && sources.isEmpty ? "No clipboard history" : "No matching items")
                            .font(.system(size: 13)).foregroundStyle(palette.secondary)
                            .frame(maxWidth: .infinity).padding(.vertical, 36)
                    }
                    ForEach(rows) { row in
                        Button { activate(row) } label: { rowLabel(row) }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("mac.history.row.\(row.id)")
                            .macFeedbackTarget("history.row.\(row.id)")
                            .accessibilityAddTraits(selected?.id == row.id ? .isSelected : [])
                            .contextMenu {
                                Button("View details") { selection = row.id }
                                Button("Copy") { model.macCopy(row, at: "history.row.\(row.id)") }
                            }
                            .id(row.id)
                    }
                }
                .padding(8)
            }
            .scrollIndicators(.never)
            .focusable()
            .focused($focused, equals: .list)
            .onKeyPress(.downArrow) { move(1) }
            .onKeyPress(.upArrow) { move(-1) }
            .onKeyPress(.return) {
                guard let selected else { return .ignored }
                activate(selected)
                return .handled
            }
            .onChange(of: selection) { _, id in if let id { proxy.scrollTo(id) } }
        }
    }

    private func rowLabel(_ row: Summary) -> some View {
        let masked = MacHistoryPrivacy.isMasked(row.name, sensitive: maskSensitive, codes: maskCodes, forDetail: false)
        return HStack(spacing: 10) {
            if batch {
                Image(systemName: checked.contains(row.id) ? "checkmark.square.fill" : "square")
                    .foregroundStyle(checked.contains(row.id) ? palette.accent : palette.muted)
            }
            MacClipTile(row: row)
            VStack(alignment: .leading, spacing: 4) {
                Text(masked ? "••••••••" : row.name)
                    .font(.system(size: 13, design: row.macKind == .code ? .monospaced : .default))
                    .foregroundStyle(palette.text).lineLimit(1)
                if let date = row.macDisplayDate {
                    Text(date, format: .dateTime.hour().minute())
                        .font(.system(size: 11)).foregroundStyle(palette.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 2)
            MacClipStatus(row: row)
        }
        .padding(.horizontal, 9)
        .frame(height: 56)
        .contentShape(Rectangle())
        .background(selected?.id == row.id ? palette.selection : .clear, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(selected?.id == row.id ? palette.accent : .clear)
                .allowsHitTesting(false)
        }
    }

    private var batchBar: some View {
        HStack(spacing: 8) {
            Text("\(checked.count) selected").foregroundStyle(palette.secondary)
            Button("Pin") {
                let pinned = model.macOperation(at: "history.batch.pin") { try model.library?.setPinned(checked) }
                if pinned { finishBatch() }
            }.disabled(checked.isEmpty).macFeedbackTarget("history.batch.pin")
            Button("Delete", role: .destructive) { confirming = true }
                .foregroundStyle(.red)
                .disabled(checked.isEmpty)
                .macFeedbackTarget("history.batch.delete")
            Button("Done") { finishBatch() }
            Spacer()
        }
        .font(.system(size: 12)).padding(8)
        .background(palette.accentSoft)
        .background(MacDeleteShortcut(enabled: !checked.isEmpty && filter == nil && focused != .search) { confirming = true })
        .alert("Confirm deletion of \(checked.count) items", isPresented: $confirming) {
            Button("Cancel", role: .cancel) {}.keyboardShortcut(.cancelAction)
            Button("Delete", role: .destructive) {
                let deleted = model.macOperation(at: "history.batch.delete") { try model.library?.deleteClips(checked) }
                if deleted { finishBatch() }
            }
        }
    }

    private func clearFilters() {
        kinds.removeAll()
        pinnedOnly = false
        sources.removeAll()
    }

    private func activate(_ row: Summary) {
        selection = row.id
        if batch {
            if !checked.insert(row.id).inserted { checked.remove(row.id) }
        } else { model.macCopy(row, at: "history.row.\(row.id)") }
    }

    private func finishBatch() {
        batch = false
        checked.removeAll()
        confirming = false
    }

    private func move(_ amount: Int) -> KeyPress.Result {
        let visible = rows
        guard let index = visible.firstIndex(where: { $0.id == selected?.id }) else { return .ignored }
        selection = visible[min(max(index + amount, 0), visible.count - 1)].id
        return .handled
    }

    private func reload() {
        do {
            let latest = try model.library?.macHistory() ?? []
            history.update(latest)
            checked.formIntersection(Set(latest.map(\.id)))
            sources.formIntersection(Set(latest.map(source(for:))))
            search()
        } catch { model.showMacFeedback(error.localizedDescription, at: "history.search") }
    }

    private func search() {
        do { matches = query.isEmpty ? [] : history.ordered(try model.library?.macHistory(search: query) ?? []) }
        catch { model.showMacFeedback(error.localizedDescription, at: "history.search") }
    }
}

struct MacClipTile: View {
    let row: Summary
    var body: some View {
        let kind = row.macKind
        Text(row.macFormat)
            .font(.system(size: 10, weight: .semibold)).foregroundStyle(kind.color)
            .lineLimit(1).minimumScaleFactor(0.68)
            .padding(.horizontal, 3)
            .frame(width: 42, height: 34)
            .background(kind.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 9))
    }
}

struct MacClipStatus: View {
    let row: Summary
    var body: some View {
        HStack(spacing: 4) {
            if row.pinned { status("pin", color: .orange, label: "Pinned") }
            if row.burn { status("flame", color: .red, label: "Burn after copy") }
        }
    }

    private func status(_ symbol: String, color: Color, label: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 10, weight: .semibold)).foregroundStyle(color)
            .frame(width: 19, height: 19)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
            .accessibilityLabel(Text(LocalizedStringKey(label)))
    }
}

struct MacCopyToast: View {
    var animateCheck = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bounce = false

    var body: some View {
        Label {
            Text("Copied")
        } icon: {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                .symbolEffect(.bounce.up, value: bounce)
        }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(MacPalette(scheme).text)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(MacPalette(scheme).toast, in: Capsule())
            .overlay { Capsule().strokeBorder(.secondary.opacity(0.25)) }
            .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
            .allowsHitTesting(false)
            .accessibilityIdentifier("mac.history.copy-toast")
            .task {
                guard animateCheck, !reduceMotion else { return }
                // Let the symbol render once before triggering its discrete effect.
                do { try await Task.sleep(for: .milliseconds(35)) } catch { return }
                bounce = true
            }
    }
}

struct MacClipComposer: View {
    @ObservedObject var model: Model
    var compact = false
    @Environment(\.colorScheme) private var scheme
    @State private var focused = false
    @State private var draft = ""
    @State private var pastedClips: [Clip] = []
    @State private var importing = false
    private var palette: MacPalette { MacPalette(scheme) }
    private var hasContent: Bool { !draft.isEmpty || !pastedClips.isEmpty }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 5) {
                if !pastedClips.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 5) {
                            ForEach(pastedClips) { clip in
                                let title = clip.name == clip.type ? UTType(clip.type)?.localizedDescription ?? clip.name : clip.name
                                HStack(spacing: 5) {
                                    Image(systemName: ClipAttachment.symbol(for: clip)).accessibilityHidden(true)
                                    Text(title).lineLimit(1).truncationMode(.middle).frame(maxWidth: 150)
                                    Button {
                                        pastedClips.removeAll { $0.id == clip.id }
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(Text("Remove"))
                                    .accessibilityValue(Text(title))
                                }
                                .padding(.horizontal, 7).padding(.vertical, 4)
                                .background(palette.raised, in: Capsule())
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                }
                MacComposerEditor(text: $draft, focused: $focused, paste: stagePaste, submit: add)
                    .overlay(alignment: .topLeading) {
                        if draft.isEmpty && pastedClips.isEmpty {
                            Text("Type or paste content and press Return…")
                                .foregroundStyle(palette.muted).lineLimit(1)
                                .allowsHitTesting(false).accessibilityHidden(true)
                        }
                    }
            }
            .padding(.horizontal, 11).padding(.vertical, 7)
            .frame(minHeight: 38)
            .background(palette.surface, in: RoundedRectangle(cornerRadius: 11))
            .overlay {
                RoundedRectangle(cornerRadius: 11).strokeBorder(focused ? palette.accent : palette.line)
                    .allowsHitTesting(false)
            }
            Button { add(draft) } label: {
                Image(systemName: "plus").font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white).frame(width: 38, height: 38)
                    .background(palette.accent, in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .opacity(hasContent ? 1 : 0.55)
            .accessibilityLabel("Add to clipboard history")
            .macFeedbackTarget("history.add")
            .help("Add to clipboard history")
            .contextMenu {
                Button("Add from system clipboard") {
                    model.macOperation(at: "history.add") { try model.save(clipboardClips(in: .general)) }
                }
                Button("Import file") { importing = true }
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, compact ? 10 : 12).padding(.vertical, 10)
        .background(palette.raised)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            model.macOperation(at: "history.add") { try model.save(result.get().map { try fileClip($0) }) }
        }
    }

    private func stagePaste(_ pasteboard: NSPasteboard) {
        do {
            let clips = try clipboardClips(in: pasteboard)
            for clip in clips { try clip.validate() }
            pastedClips.append(contentsOf: clips)
            model.showMacFeedback("", at: "history.add")
        } catch {
            model.showMacFeedback(error.localizedDescription, at: "history.add")
        }
    }

    private func add(_ text: String) {
        guard !text.isEmpty || !pastedClips.isEmpty else { return }
        var clips = pastedClips
        if !text.isEmpty { clips.append(.text(text)) }
        model.macOperation(at: "history.add") {
            try model.save(clips)
            pastedClips = []
            draft = ""
        }
    }
}

struct MacClipDetail: View {
    @ObservedObject var model: Model
    let row: Summary
    let sourceName: String
    let sourceApplication: String?
    let showsCopy: Bool
    let deleteShortcutEnabled: Bool
    let copy: (() -> Void)?

    init(model: Model, row: Summary, sourceName: String? = nil, sourceApplication: String? = nil,
         deleteShortcutEnabled: Bool = true, copy: (() -> Void)? = nil) {
        self.model = model
        self.row = row
        let remote = row.received ?? model.peers.contains { $0.name == row.source }
        self.sourceName = sourceName ?? (remote ? row.source : Host.current().localizedName ?? ClipRelayPreferences.localized("This Mac"))
        self.sourceApplication = sourceApplication ?? (!remote && row.source != "Local" ? row.source : nil)
        self.showsCopy = sourceName == nil
        self.deleteShortcutEnabled = deleteShortcutEnabled
        self.copy = copy
    }

    @State private var clip: Clip?
    @State private var thumbnail: CGImage?
    @State private var confirming = false
    @AppStorage("mac.maskSensitive") private var maskSensitive = true
    @AppStorage("mac.maskCodes") private var maskCodes = false
    @Environment(\.colorScheme) private var scheme
    private var palette: MacPalette { MacPalette(scheme) }
    private var masked: Bool {
        MacHistoryPrivacy.isMasked(clip?.text ?? clip?.name ?? row.name, sensitive: maskSensitive, codes: maskCodes, forDetail: true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 6) {
                        Text(row.macFormat)
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(palette.accent)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(palette.accentSoft, in: RoundedRectangle(cornerRadius: 6))
                        MacClipStatus(row: row)
                    }
                    contentPreview
                    VStack(spacing: 0) {
                        metadata("Source device", sourceName)
                        if let sourceApplication { metadata("Source application", sourceApplication) }
                        if let date = row.date { metadata("Time", date.formatted(date: .abbreviated, time: .shortened)) }
                        if let date = row.lastCopied { metadata("Last copied", date.formatted(date: .abbreviated, time: .shortened)) }
                        if let clip {
                            metadata("Size", clip.text.map { String(localized: "\($0.count) characters") }
                                     ?? ByteCountFormatter.string(fromByteCount: Int64(clip.bytes.count), countStyle: .file))
                        }
                    }
                }
            }
            // A legacy scroller takes space from the text and changes its wrapping.
            .scrollIndicators(.never)
            .frame(maxHeight: .infinity, alignment: .top)
            .accessibilityIdentifier("mac.history.detail.preview")
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Expiration").font(.system(size: 12, weight: .semibold)).foregroundStyle(palette.secondary)
                    HStack(spacing: 4) {
                        expiry("Never", seconds: nil)
                        expiry("5 minutes", seconds: 300)
                        expiry("24 hours", seconds: 86_400)
                    }
                }
                Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                    GridRow {
                        detailButton(row.pinned ? "Unpin" : "Pin", symbol: row.pinned ? "pin.slash" : "pin") {
                            model.macOperation(at: "detail.pin") { try model.library?.pin(row.id) }
                        }.macFeedbackTarget("detail.pin")
                        detailButton(row.burn ? "Turn off burn after copy" : "Burn after copy", symbol: "flame") {
                            model.macOperation(at: "detail.burn") { try model.library?.setBurn(row.id, !row.burn) }
                        }
                        .macFeedbackTarget("detail.burn")
                        .help("Remove from this Mac when copied from history")
                    }
                    GridRow {
                        detailButton("Export file", symbol: "square.and.arrow.down", action: export)
                            .macFeedbackTarget("detail.export")
                        detailButton("Delete", symbol: "trash", destructive: true) { confirming = true }
                            .accessibilityIdentifier("mac.history.detail.delete")
                            .macFeedbackTarget("detail.delete")
                    }
                }
                if showsCopy {
                    detailButton("Copy", symbol: "doc.on.doc") {
                        if let copy { copy() } else { model.macCopy(row, at: "detail.copy") }
                    }.macFeedbackTarget("detail.copy")
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(1)
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(palette.surface)
        .background(MacDeleteShortcut(enabled: deleteShortcutEnabled) { confirming = true })
        .task(id: row.id) {
            thumbnail = nil
            clip = try? model.storedClip(row.id)
            if let library = model.library, row.macKind == .image {
                thumbnail = await ClipAttachment.load(row.id, from: library)?.thumbnail
            }
        }
        .alert("Confirm deletion", isPresented: $confirming) {
            Button("Cancel", role: .cancel) {}.keyboardShortcut(.cancelAction)
            Button("Delete", role: .destructive) { model.macOperation(at: "detail.delete") { try model.library?.delete(row.id) } }
        }
    }

    private var contentPreview: some View {
        Group {
            if masked {
                Text("••••••••").accessibilityLabel("Masked")
            } else if let thumbnail {
                Image(decorative: thumbnail, scale: 1).resizable().scaledToFit().accessibilityLabel(row.name)
            } else if row.macKind == .link, let url = URL(string: clip?.text ?? row.name),
                      ["https", "http"].contains(url.scheme ?? ""), url.host != nil {
                Link(clip?.text ?? row.name, destination: url).foregroundStyle(palette.accent).textSelection(.enabled)
            } else {
                Text(clip?.text ?? row.name)
                    .font(.system(size: 13, design: row.macKind == .code ? .monospaced : .default)).textSelection(.enabled)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.raised, in: RoundedRectangle(cornerRadius: 10))
    }

    private func metadata(_ label: String, _ value: String) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(LocalizedStringKey(label)).foregroundStyle(palette.secondary).fixedSize()
                Spacer()
                Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 12)).padding(.vertical, 7)
            Divider()
        }
    }

    private func expiry(_ title: String, seconds: TimeInterval?) -> some View {
        let selected = row.expirySeconds == seconds
        let target = "detail.expiry.\(title)"
        return Button {
            model.macOperation(at: target) { try model.library?.setExpiry(row.id, after: seconds) }
        } label: {
            Text(LocalizedStringKey(title)).font(.system(size: 11, weight: selected ? .semibold : .regular))
                .frame(maxWidth: .infinity).padding(.vertical, 6)
                .foregroundStyle(selected ? palette.accent : palette.secondary)
                .background(selected ? palette.accentSoft : palette.raised, in: RoundedRectangle(cornerRadius: 7))
                .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(selected ? palette.accent : palette.line) }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .macFeedbackTarget(target)
    }

    private func detailButton(_ title: String, symbol: String, destructive: Bool = false,
                              action: @escaping () -> Void) -> some View {
        Button(role: destructive ? .destructive : nil, action: action) {
            Label(LocalizedStringKey(title), systemImage: symbol)
                .font(.system(size: 12, weight: .medium)).lineLimit(1)
                .foregroundStyle(destructive ? Color.red : palette.text)
                .frame(maxWidth: .infinity, minHeight: 34)
                .background(destructive ? Color.red.opacity(0.09) : palette.raised, in: RoundedRectangle(cornerRadius: 9))
                .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(destructive ? Color.red.opacity(0.3) : palette.line) }
        }
        .buttonStyle(.plain)
    }

    private func export() {
        do {
            let value = try model.storedClip(row.id)
            let panel = NSSavePanel()
            let name = URL(fileURLWithPath: value.name).lastPathComponent
            panel.nameFieldStringValue = value.isFile == true && !masked ? name : "ClipRelay"
            if let type = UTType(value.type) { panel.allowedContentTypes = [type] }
            panel.begin { result in
                guard result == .OK, let destination = panel.url else { return }
                model.macOperation(at: "detail.export") { try value.bytes.write(to: destination, options: .atomic) }
            }
        } catch { model.showMacFeedback(error.localizedDescription, at: "detail.export") }
    }
}

private struct MacDeleteShortcut: NSViewRepresentable {
    let enabled: Bool
    let confirm: () -> Void

    func makeNSView(context: Context) -> KeyMonitor { KeyMonitor() }

    func updateNSView(_ view: KeyMonitor, context: Context) {
        view.confirm = enabled ? confirm : nil
    }

    static func dismantleNSView(_ view: KeyMonitor, coordinator: ()) { view.stop() }

    final class KeyMonitor: NSView {
        var confirm: (() -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      window.attachedSheet == nil, let confirm = self.confirm,
                      event.keyCode == kVK_Delete || event.keyCode == kVK_ForwardDelete,
                      event.modifierFlags.intersection([.shift, .control, .option, .command]).isEmpty,
                      (window.firstResponder as? NSTextView)?.isEditable != true else { return event }
                if !event.isARepeat { confirm() }
                return nil
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
#endif
