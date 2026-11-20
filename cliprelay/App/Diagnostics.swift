import SwiftUI

struct DiagnosticsSection: View {
    @ObservedObject var model: Model
    @State private var usage: Library.Usage?
    @State private var milliseconds: Double = 0

    var body: some View {
        Group {
            #if os(macOS)
            MacSettingsCard(title: "Diagnostics") {
                details
                Button("Refresh diagnostics", action: refresh).padding(.top, 9)
            }
            #else
            Section("Diagnostics") {
                details
                Button("Refresh diagnostics", action: refresh)
            }
            #endif
        }.onAppear(perform: refresh)
    }

    @ViewBuilder private var details: some View {
        if let usage {
            metric("History", String(usage.entries))
            metric("History storage", bytes(usage.historyBytes) + " / 160 MB")
            metric("Pending", String(usage.jobs))
            metric("Queued data", bytes(usage.queuedBytes))
            metric("Page read time", milliseconds.formatted(.number.precision(.fractionLength(2))) + " ms")
        }
    }

    @ViewBuilder private func metric(_ title: LocalizedStringKey, _ value: String) -> some View {
        #if os(macOS)
        HStack {
            Text(title).font(.callout.weight(.semibold))
            Spacer()
            Text(value).font(.callout).foregroundStyle(.secondary).monospacedDigit()
        }.padding(.vertical, 9)
        Divider()
        #else
        LabeledContent { Text(value) } label: { Text(title) }
        #endif
    }
    private func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .decimal)
    }
    private func refresh() {
        guard let library = model.library else { return }
        do {
            let start = ProcessInfo.processInfo.systemUptime
            _ = try library.page(kind: model.filter, search: model.search, offset: model.page * 30)
            milliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1_000
            usage = try library.usage()
        } catch { model.notice = error.localizedDescription }
    }
}
