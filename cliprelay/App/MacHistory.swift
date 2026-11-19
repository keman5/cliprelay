#if os(macOS)
import AppKit
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

    var macSource: String { source == "Local" ? Host.current().localizedName ?? ClipRelayPreferences.localized("This Mac") : source }
}

struct MacHistory: View {
    @ObservedObject var model: Model
    @Environment(\.colorScheme) private var scheme
    @FocusState private var focused: Field?
    @AppStorage("mac.maskSensitive") private var maskSensitive = true
    @AppStorage("mac.maskCodes") private var maskCodes = false
    @State private var all: [Summary] = []
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
                                  sourceApplication: source(for: selected) == .thisMac && selected.source != "Local" ? selected.source : nil).id(selected.id)
                } else {
                    Text("Select an item to view its details").foregroundStyle(palette.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: 318)
            .background(palette.surface)
        }
        .onReceive(model.$rows) { _ in reload() }
        .onChange(of: query) { _, _ in search() }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            if all.contains(where: { $0.expires.map { $0 <= .now } ?? false }) { model.reload() }
        }
        .onExitCommand {
            if filter != nil { filter = nil }
            else if focused != nil { focused = nil }
            else if confirming { confirming = false }
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
                            .accessibilityAddTraits(selected?.id == row.id ? .isSelected : [])
                            .contextMenu {
                                Button("View details") { selection = row.id }
                                Button("Copy") { model.copy(row) }
                            }
                            .id(row.id)
                    }
                }
                .padding(8)
            }
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
                HStack(spacing: 8) {
                    Text("From \(source(for: row).title)").lineLimit(1)
                    if let date = row.date {
                        Text(date, format: .dateTime.hour().minute())
                            .lineLimit(1).fixedSize().layoutPriority(1)
                    }
                }
                .font(.system(size: 11)).foregroundStyle(palette.secondary)
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
        .help(source(for: row) == .thisMac && row.source != "Local" ? Text(row.source) : Text(batch ? "Select item" : "Click to copy"))
    }

    private var batchBar: some View {
        HStack(spacing: 8) {
            Text("\(checked.count) selected").foregroundStyle(palette.secondary)
            Button("Pin") {
                model.operation { try model.library?.setPinned(checked) }
                if model.notice.isEmpty { finishBatch() }
            }.disabled(checked.isEmpty)
            Button(role: .destructive) {
                if confirming {
                    model.operation { try model.library?.deleteClips(checked) }
                    if model.notice.isEmpty { finishBatch() }
                } else { confirming = true }
            } label: {
                Text(confirming ? "Confirm deletion of \(checked.count) items" : "Delete")
            }.disabled(checked.isEmpty)
            Button("Done") { finishBatch() }
            Spacer()
        }
        .font(.system(size: 12)).padding(8)
        .background(palette.accentSoft)
        .task(id: confirming) {
            guard confirming else { return }
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            confirming = false
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
            confirming = false
            if !checked.insert(row.id).inserted { checked.remove(row.id) }
        } else { model.copy(row) }
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
            all = try model.library?.macHistory() ?? []
            checked.formIntersection(Set(all.map(\.id)))
            sources.formIntersection(Set(all.map(source(for:))))
            search()
        } catch { model.notice = error.localizedDescription }
    }

    private func search() {
        do { matches = query.isEmpty ? [] : try model.library?.macHistory(search: query) ?? [] }
        catch { model.notice = error.localizedDescription }
    }
}

struct MacClipTile: View {
    let row: Summary
    var body: some View {
        let kind = row.macKind
        Image(systemName: kind.symbol)
            .font(.system(size: 15, weight: .medium)).foregroundStyle(kind.color)
            .frame(width: 34, height: 34)
            .background(kind.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 9))
            .accessibilityLabel(kind.title)
    }
}

struct MacClipStatus: View {
    let row: Summary
    var body: some View {
        HStack(spacing: 4) {
            if row.pinned { status("pin", color: .orange, label: "Pinned") }
            if row.burn { status("flame", color: .red, label: "Burn after paste") }
            if row.localOnly { status("clock", color: .orange, label: "On this Mac · Not synced") }
        }
    }

    private func status(_ symbol: String, color: Color, label: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 10, weight: .semibold)).foregroundStyle(color)
            .frame(width: 19, height: 19)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
            .accessibilityLabel(Text(LocalizedStringKey(label))).help(Text(LocalizedStringKey(label)))
    }
}

struct MacClipComposer: View {
    @ObservedObject var model: Model
    var compact = false
    @Environment(\.colorScheme) private var scheme
    @FocusState private var focused: Bool
    @State private var draft = ""
    @State private var importing = false
    private var palette: MacPalette { MacPalette(scheme) }

    var body: some View {
        HStack(spacing: 8) {
            TextField("Type or paste content and press Return…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain).lineLimit(1...3)
                .padding(.horizontal, 11).padding(.vertical, 7)
                .frame(minHeight: 38)
                .background(palette.surface, in: RoundedRectangle(cornerRadius: 11))
                .overlay { RoundedRectangle(cornerRadius: 11).strokeBorder(focused ? palette.accent : palette.line) }
                .focused($focused)
                .onKeyPress(keys: [.return]) { press in
                    guard !press.modifiers.contains(.shift), !draft.isEmpty else { return .ignored }
                    add()
                    return .handled
                }
                .onExitCommand { focused = false }
                .accessibilityIdentifier("mac.history.composer")
            Button { add() } label: {
                Image(systemName: "plus").font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white).frame(width: 38, height: 38)
                    .background(palette.accent, in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .opacity(draft.isEmpty ? 0.55 : 1)
            .accessibilityLabel("Add to clipboard history")
            .help("Add to clipboard history")
            .contextMenu {
                Button("Add from system clipboard") { add(paste: true) }
                Button("Import file") { importing = true }
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, compact ? 10 : 12).padding(.vertical, 10)
        .background(palette.raised)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            model.operation { try model.save(result.get().map { try fileClip($0) }) }
        }
    }

    private func add(paste: Bool = false) {
        guard paste || !draft.isEmpty else { return }
        model.operation {
            if paste { try model.save(clipboardClips(in: .general)) }
            else { try model.save([.text(draft)]); draft = "" }
        }
    }
}

struct MacClipDetail: View {
    @ObservedObject var model: Model
    let row: Summary
    let sourceName: String
    let sourceApplication: String?
    let showsCopy: Bool

    init(model: Model, row: Summary, sourceName: String? = nil, sourceApplication: String? = nil) {
        self.model = model
        self.row = row
        let remote = row.received ?? model.peers.contains { $0.name == row.source }
        self.sourceName = sourceName ?? (remote ? row.source : Host.current().localizedName ?? ClipRelayPreferences.localized("This Mac"))
        self.sourceApplication = sourceApplication ?? (!remote && row.source != "Local" ? row.source : nil)
        self.showsCopy = sourceName == nil
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
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    Text(row.macKind.title)
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
                    if let clip {
                        metadata("Size", clip.text.map { String(localized: "\($0.count) characters") }
                                 ?? ByteCountFormatter.string(fromByteCount: Int64(clip.bytes.count), countStyle: .file))
                    }
                }
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
                            model.operation { try model.library?.pin(row.id) }
                        }
                        detailButton(row.burn ? "Turn off burn after paste" : "Burn after paste", symbol: "flame") {
                            model.operation { try model.library?.setBurn(row.id, !row.burn) }
                        }
                        .help("Remove from this Mac when copied from history")
                    }
                    GridRow {
                        detailButton("Export file", symbol: "square.and.arrow.down", action: export)
                        detailButton(confirming ? "Confirm deletion" : "Delete", symbol: "trash", color: .red) {
                            if confirming {
                                model.operation { try model.library?.delete(row.id) }
                                if model.notice.isEmpty { confirming = false }
                            } else { confirming = true }
                        }
                    }
                }
                if showsCopy { detailButton("Copy", symbol: "doc.on.doc") { model.copy(row) } }
            }
            .padding(16)
        }
        .background(palette.surface)
        .task(id: row.id) {
            thumbnail = nil
            clip = try? model.storedClip(row.id)
            if let library = model.library, row.macKind == .image {
                thumbnail = await ClipAttachment.load(row.id, from: library)?.thumbnail
            }
        }
        .task(id: confirming) {
            guard confirming else { return }
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            confirming = false
        }
        .onKeyPress(.escape) {
            guard confirming else { return .ignored }
            confirming = false
            return .handled
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
                Text(LocalizedStringKey(label)).foregroundStyle(palette.secondary)
                Spacer()
                Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
            }
            .font(.system(size: 12)).padding(.vertical, 7)
            Divider()
        }
    }

    private func expiry(_ title: String, seconds: TimeInterval?) -> some View {
        let selected = row.expirySeconds == seconds
        return Button {
            model.operation { try model.library?.setExpiry(row.id, after: seconds) }
        } label: {
            Text(LocalizedStringKey(title)).font(.system(size: 11, weight: selected ? .semibold : .regular))
                .frame(maxWidth: .infinity).padding(.vertical, 6)
                .foregroundStyle(selected ? palette.accent : palette.secondary)
                .background(selected ? palette.accentSoft : palette.raised, in: RoundedRectangle(cornerRadius: 7))
                .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(selected ? palette.accent : palette.line) }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func detailButton(_ title: String, symbol: String, color: Color? = nil,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(LocalizedStringKey(title), systemImage: symbol)
                .font(.system(size: 12, weight: .medium)).lineLimit(1)
                .foregroundStyle(color ?? palette.text)
                .frame(maxWidth: .infinity, minHeight: 34)
                .background(palette.raised, in: RoundedRectangle(cornerRadius: 9))
                .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(palette.line) }
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
                model.operation { try value.bytes.write(to: destination, options: .atomic) }
            }
        } catch { model.notice = error.localizedDescription }
    }
}
#endif
