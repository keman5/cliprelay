#if os(iOS)
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

struct PhoneHistory: View {
    @ObservedObject var model: Model
    @State private var query = ""
    @State private var found: [Summary] = []
    @State private var searching = false
    @State private var kinds: Set<MacClipKind> = []
    @State private var sources: Set<String> = []
    @State private var pinned = false
    @State private var selecting = false
    @State private var checked: Set<String> = []
    @State private var deleting: Set<String> = []
    @State private var draft = ""
    @FocusState private var writing: Bool
    @State private var importing = false
    @State private var detail: Summary?
    @State private var shareURL: URL?
    @State private var filters = false
    @AppStorage("phone.maskSensitive", store: ClipRelayPreferences.defaults) private var sensitive = true
    @AppStorage("phone.maskCodes", store: ClipRelayPreferences.defaults) private var codes = false

    private struct Search: Equatable { let text: String; let revision: Int }
    private func device(_ row: Summary) -> String {
        (row.received ?? model.peers.contains(where: { $0.name == row.source })) ? row.source : ""
    }
    private var visible: [Summary] {
        found.filter { (!pinned || $0.pinned) && (kinds.isEmpty || kinds.contains($0.macKind)) && (sources.isEmpty || sources.contains(device($0))) }
    }
    private var eligible: Set<String> { checked.intersection(visible.filter { !$0.fromHub }.map(\.id)) }

    var body: some View {
        List {
            if !selecting {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Image(systemName: "square.and.pencil").foregroundStyle(.indigo)
                            TextField("New text", text: $draft)
                                .focused($writing).onSubmit(add)
                            Button { add() } label: {
                                Image(systemName: "plus.circle.fill").font(.title2)
                            }.accessibilityLabel("Add item").disabled(draft.isEmpty).buttonStyle(.borderless)
                        }
                        Divider()
                        HStack {
                            PasteButton(supportedContentTypes: ClipboardPaste.types) { providers in
                                Task { await importProviders(providers) }
                            }.controlSize(.small).buttonBorderShape(.capsule)
                            Spacer()
                            Button { importing = true } label: { Label("Import file", systemImage: "folder") }.buttonStyle(.borderless)
                        }.font(.subheadline)
                    }.padding(.vertical, 5)
                }
            }
            Section {
                if searching {
                    ProgressView("Searching…")
                } else if visible.isEmpty {
                    ContentUnavailableView {
                        Label(found.isEmpty && query.isEmpty && !pinned && kinds.isEmpty && sources.isEmpty ? "No clipboard history" : "No matching items", systemImage: "list.clipboard")
                    }
                } else {
                    ForEach(visible) { item in record(item) }
                }
            } header: {
                HStack {
                    Text(pinned ? "Pinned" : "Recent")
                    Spacer()
                    Text(visible.count, format: .number).monospacedDigit()
                }
            }
        }
        .navigationTitle("History")
        .searchable(text: $query, prompt: "Search history…")
        .scrollDismissesKeyboard(.immediately)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { filters = true } label: {
                    Image(systemName: pinned || !kinds.isEmpty || !sources.isEmpty ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }.accessibilityLabel("Filter")
                Button(selecting ? "Done" : "Select") { selecting.toggle(); checked.removeAll() }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if selecting {
                HStack {
                    Text("\(eligible.count) selected").font(.footnote)
                    Spacer()
                    Button("Pin") {
                        model.operation { try model.library?.setPinned(eligible) }
                        if model.notice.isEmpty { checked.removeAll(); selecting = false }
                    }
                    Button("Delete", role: .destructive) { deleting = eligible }
                }.disabled(eligible.isEmpty).padding().background(.bar)
            }
        }
        .task(id: Search(text: query, revision: model.phoneRevision)) {
            guard let library = model.library else { return }
            searching = !query.isEmpty
            do {
                let result: [Summary]
                if query.isEmpty { result = try library.macHistory() }
                else {
                    try await Task.sleep(for: .milliseconds(160))
                    result = try await Library.searchMacHistory(in: library.root, for: query)
                }
                try Task.checkCancellation()
                found = result
                searching = false
            } catch {
                if !Task.isCancelled { found = []; searching = false; model.notice = error.localizedDescription }
            }
        }
        .sheet(isPresented: $filters) {
            NavigationStack {
                Form {
                    Toggle("Pinned", isOn: $pinned)
                    Section("Filter by type") {
                        ForEach(MacClipKind.allCases) { kind in
                            Toggle(kind.title, isOn: Binding(get: { kinds.contains(kind) }, set: { on in
                                if on { kinds.insert(kind) } else { kinds.remove(kind) }
                            }))
                        }
                    }
                    Section("Filter by source") {
                        ForEach(Set(found.map(device)).union(sources).union([""]).sorted(), id: \.self) { name in
                            Toggle(name.isEmpty ? ClipRelayPreferences.localized("This iPhone") : name,
                                   isOn: Binding(get: { sources.contains(name) }, set: { selected in
                                       if selected { sources.insert(name) } else { sources.remove(name) }
                                   }))
                        }
                    }
                    Button("Clear all filters") { pinned = false; kinds = []; sources = [] }
                }.navigationTitle("Filter").toolbar { Button("Done") { filters = false } }
            }.presentationDetents([.medium, .large])
        }
        .sheet(item: $detail) { item in PhoneDetail(model: model, original: item) }
        .sheet(isPresented: Binding(get: { shareURL != nil }, set: { if !$0 { shareURL = nil } })) {
            if let shareURL { PhoneShare(url: shareURL, removeAfterSharing: true) }
        }
        .alert(deleting.count == 1 ? Text("Delete clipboard item?") : Text("Confirm deletion of \(deleting.count) items"),
               isPresented: Binding(get: { !deleting.isEmpty }, set: { if !$0 { deleting = [] } }), presenting: deleting) { ids in
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                model.operation { try model.library?.deleteClips(ids) }
                checked.subtract(ids)
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            do {
                var errors: [String] = []
                let urls = try result.get()
                for url in urls {
                    do { try model.save([fileClip(url)]) } catch { errors.append(url.lastPathComponent + " · " + ClipRelayPreferences.localized(error.localizedDescription)) }
                }
                finishImport(urls.count, errors)
            } catch { if (error as NSError).code != NSUserCancelledError { model.notice = error.localizedDescription } }
        }
    }

    private func record(_ row: Summary) -> some View {
        let masked = MacHistoryPrivacy.isMasked(row.name, sensitive: sensitive, codes: codes, forDetail: false)
        return HStack(spacing: 0) {
            Button {
                if selecting {
                    if checked.contains(row.id) { checked.remove(row.id) } else { checked.insert(row.id) }
                } else { detail = row }
            } label: {
                HStack(spacing: 11) {
                    if selecting { Image(systemName: checked.contains(row.id) ? "checkmark.circle.fill" : "circle") }
                    PhoneTile(row: row, library: model.library)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(masked ? "••••••" : row.name).lineLimit(2).foregroundStyle(.primary)
                        HStack(spacing: 4) {
                            if row.burn { Image(systemName: "flame").accessibilityLabel("Delete after copying") }
                            if row.pinned { Image(systemName: "pin.fill").accessibilityLabel("Pinned") }
                            Text(device(row).isEmpty ? ClipRelayPreferences.localized("This iPhone") : row.source)
                            if let date = row.macDisplayDate { Text("·"); Text(date, style: .relative) }
                        }.font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }.disabled(selecting && row.fromHub).buttonStyle(.plain)
                .accessibilityIdentifier("history.row.\(row.id)")
                .accessibilityAddTraits(selecting && checked.contains(row.id) ? .isSelected : [])
            if !selecting {
                Button { model.copy(row) } label: { Image(systemName: "doc.on.doc").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle()) }
                    .accessibilityLabel("Copy").accessibilityIdentifier("history.copy.\(row.id)")
                Menu {
                    PhoneSend(model: model, row: row)
                } label: { Image(systemName: "paperplane").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle()) }
                    .disabled(model.peers.isEmpty || row.fromHub || ClipRelayPreferences.paused)
                    .accessibilityLabel("Send to devices").accessibilityIdentifier("history.send.\(row.id)")
                Menu {
                    Button("Preview") { detail = row }
                    Button("Share item") {
                        Task {
                            do {
                                guard try await MacHistoryAuthentication.verify("Verify to export a clipboard item") else { return }
                                shareURL = try materialize(model.storedClip(row.id), directoryID: UUID())
                            } catch { model.notice = error.localizedDescription }
                        }
                    }
                    if !row.fromHub {
                        Button(row.pinned ? "Unpin" : "Pin") { model.operation { try model.library?.pin(row.id) } }
                        Button("Delete", role: .destructive) { deleting = [row.id] }
                    }
                } label: { Image(systemName: "ellipsis.circle").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle()) }
                    .accessibilityLabel("Item actions").accessibilityIdentifier("history.actions.\(row.id)")
            }
        }.buttonStyle(.borderless).padding(.vertical, 3)
    }

    private func add() {
        guard !draft.isEmpty else { return }
        model.operation { try model.save([.text(draft)]); draft = ""; writing = false }
    }
    private func importProviders(_ providers: [NSItemProvider]) async {
        guard !ClipboardPaste.isPrivate(providers) else { model.notice = ClipRelayPreferences.localized("Private clipboard content was skipped"); return }
        var errors: [String] = []
        for (index, provider) in providers.enumerated() {
            do { try model.save([try await ClipboardPaste.load(provider)]) }
            catch { errors.append((provider.suggestedName ?? String(format: ClipRelayPreferences.localized("Item %lld"), index+1)) + " · " + ClipRelayPreferences.localized(error.localizedDescription)) }
        }
        finishImport(providers.count, errors)
    }
    private func finishImport(_ count: Int, _ errors: [String]) {
        model.reload()
        model.notice = ([String(format: ClipRelayPreferences.localized("Saved %lld items"), count-errors.count)] + errors).joined(separator: "\n")
    }
}

private struct PhoneTile: View {
    let row: Summary
    let library: Library?
    @State private var attachment: ClipAttachment?
    var body: some View {
        Group {
            if let image = attachment?.thumbnail {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
            } else {
                Image(systemName: row.macKind.symbol).foregroundStyle(row.macKind.color)
            }
        }.frame(width: 36, height: 40).background(row.macKind.color.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
        .clipShape(RoundedRectangle(cornerRadius: 9)).accessibilityHidden(true)
        .task(id: row.id) {
            guard row.kind == "Image", let library else { return }
            let value = await ClipAttachment.load(row.id, from: library)
            if !Task.isCancelled { attachment = value }
        }
    }
}

private struct PhoneSend: View {
    @ObservedObject var model: Model
    let row: Summary
    var body: some View {
        ForEach(model.peers) { peer in
            Button(peer.name) { Task { await model.sendStoredClip(row.id, to: peer) } }
        }
        if model.peers.count > 1 {
            Button("Send to all paired devices") { Task { await model.sendStoredClip(row.id, to: nil) } }
        }
    }
}

struct PhoneShare: View {
    let url: URL
    var removeAfterSharing = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "doc").font(.largeTitle).foregroundStyle(.indigo)
            Text(url.lastPathComponent).font(.headline).lineLimit(2)
            ShareLink(item: url).buttonStyle(.borderedProminent)
            Button("Done") { dismiss() }
        }.padding().presentationDetents([.medium])
            .onDisappear {
                if removeAfterSharing { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            }
    }
}

private struct PhoneDetail: View {
    @ObservedObject var model: Model
    let original: Summary
    @State private var row: Summary?
    @State private var clip: Clip?
    @State private var file: URL?
    @State private var previewImage: CGImage?
    @State private var confirmDeletion = false
    @Environment(\.dismiss) private var dismiss
    @AppStorage("phone.maskCodes", store: ClipRelayPreferences.defaults) private var codes = false
    var body: some View {
        NavigationStack {
            List {
                if let row, let clip {
                    Section("Preview") {
                        if let text = clip.text {
                            if MacHistoryPrivacy.isMasked(text, sensitive: false, codes: codes, forDetail: true) {
                                Text("••••••").accessibilityLabel("Masked")
                            } else if row.macKind == .link, let url = URL(string: text),
                                      ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil {
                                Link(text, destination: url)
                            } else {
                                Text(text).font(row.macKind == .code ? .body.monospaced() : .body).textSelection(.enabled)
                            }
                        } else if let image = previewImage {
                            Image(decorative: image, scale: 1).resizable().scaledToFit().accessibilityLabel("Image")
                        } else { Label(row.name, systemImage: row.macKind.symbol) }
                        LabeledContent("Source", value: row.source == "Local" ? ClipRelayPreferences.localized("This iPhone") : row.source)
                        LabeledContent("Format", value: row.macFormat)
                        LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: Int64(clip.bytes.count), countStyle: .file))
                        if let date = row.date { LabeledContent("Date", value: date.formatted()) }
                        if let copied = row.lastCopied { LabeledContent("Last copied", value: copied.formatted()) }
                    }
                    Section {
                        Button("Copy") { if model.copy(row), row.burn { dismiss() } }.accessibilityIdentifier("history.detail.copy")
                        Button("Export file") {
                            Task {
                                do {
                                    guard try await MacHistoryAuthentication.verify("Verify to export a clipboard item") else { return }
                                    file = try materialize(model.storedClip(row.id), directoryID: UUID())
                                } catch { model.notice = error.localizedDescription }
                            }
                        }
                        if !row.fromHub {
                            Toggle("Pinned", isOn: Binding(get: { row.pinned }, set: { _ in model.operation { try model.library?.pin(row.id) } }))
                            Toggle("Delete after copying", isOn: Binding(get: { row.burn }, set: { on in model.operation { try model.library?.setBurn(row.id, on) } }))
                            Picker("Expiration", selection: Binding(get: { row.expirySeconds ?? 0 }, set: { seconds in
                                model.operation { try model.library?.setExpiry(row.id, after: seconds > 0 ? seconds : nil) }
                            })) {
                                Text("Never").tag(0.0); Text("5 minutes").tag(300.0); Text("24 hours").tag(86400.0)
                            }
                        }
                    }
                    if !row.fromHub && !model.peers.isEmpty {
                        Section("Send to devices") {
                            Menu("Send to devices") { PhoneSend(model: model, row: row) }.disabled(ClipRelayPreferences.paused)
                            let states = model.deliveryStates(for: row.id)
                            ForEach(model.peers) { peer in
                                let state = states[peer.id]
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(peer.name)
                                        Text(state?.phoneTitle ?? "Not sent").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if state == .pending { Button("Cancel") { model.cancelDelivery(row.id, to: peer) } }
                                }
                            }
                        }
                    }
                    if !row.fromHub {
                        Button("Delete", role: .destructive) { confirmDeletion = true }
                            .alert("Delete clipboard item?", isPresented: $confirmDeletion) {
                                Button("Cancel", role: .cancel) {}
                                Button("Delete", role: .destructive) {
                                    model.operation { try model.library?.delete(row.id) }
                                    if model.notice.isEmpty { dismiss() }
                                }
                            }
                    }
                } else { ProgressView() }
            }
            .navigationTitle("Details").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
            .safeAreaInset(edge: .bottom) { if !model.notice.isEmpty { Text(model.notice).font(.footnote).padding(5) } }
        }
        .task(id: model.phoneRevision) {
            do {
                guard let current = try model.library?.macHistory().first(where: { $0.id == original.id }) else { dismiss(); return }
                row = current
                if clip == nil {
                    let item = try model.storedClip(current.id)
                    if item.kind == "Image", let source = CGImageSourceCreateWithData(item.bytes as CFData, nil) {
                        previewImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceCreateThumbnailWithTransform: true,
                            kCGImageSourceThumbnailMaxPixelSize: 1200
                        ] as CFDictionary)
                    }
                    clip = item
                }
            } catch { model.notice = error.localizedDescription; dismiss() }
        }
        .task(id: row?.expires) {
            guard let date = row?.expires else { return }
            do { try await Task.sleep(for: .seconds(max(0, date.timeIntervalSinceNow))) } catch { return }
            model.reload()
        }
        .sheet(isPresented: Binding(get: { file != nil }, set: { if !$0 { file = nil } })) { if let file { PhoneShare(url: file, removeAfterSharing: true) } }
    }
}

extension DeliveryState {
    var phoneTitle: LocalizedStringKey {
        switch self {
        case .pending: "等待设备接收"
        case .relayed: "已交给中继，等待设备接收"
        case .received: "对方设备已接收"
        }
    }
}
#endif
