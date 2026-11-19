import SwiftUI

struct DiagnosticsSection: View {
    @ObservedObject var model: Model
    @State private var usage: Library.Usage?
    @State private var milliseconds: Double = 0

    var body: some View {
        Section("Diagnostics") {
            if let usage {
                LabeledContent("History", value: String(usage.entries))
                LabeledContent("History storage", value: bytes(usage.historyBytes) + " / 160 MB")
                LabeledContent("Pending", value: String(usage.jobs))
                LabeledContent("Queued data", value: bytes(usage.queuedBytes))
                LabeledContent("Page read time", value: milliseconds.formatted(.number.precision(.fractionLength(2))) + " ms")
            }
            Button("Refresh diagnostics", action: refresh)
        }.onAppear(perform: refresh)
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
