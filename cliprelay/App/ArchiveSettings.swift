import SwiftUI
import UniformTypeIdentifiers

struct ArchiveSettings: View {
    @ObservedObject var model: Model
    @State private var password = ""
    @State private var picking = false
    @State private var working = false
    @State private var confirm = false
    @State private var contents: ClipArchive.Contents?
    @State private var exportURL: URL?

    var body: some View {
        Section("Backup") {
            SecureField("Archive password", text: $password)
            Button("Create encrypted backup", action: export).disabled(working || password.isEmpty)
            Button("Import encrypted backup") { picking = true }.disabled(working || password.isEmpty)
            if let exportURL {
                ShareLink(item: exportURL) { Label("Share encrypted backup", systemImage: "square.and.arrow.up") }
            }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.data]) { result in
            do {
                let url = try result.get()
                guard ["clipnote", "rayonclip"].contains(url.pathExtension.lowercased()) else {
                    throw ClipArchive.Failure.invalid
                }
                let secret = password
                password = ""
                working = true
                Task { @MainActor in
                    defer { working = false }
                    do {
                        contents = try await Task.detached { try ClipArchive.read(url, password: secret) }.value
                        confirm = true
                    } catch { model.notice = error.localizedDescription }
                }
            } catch { model.notice = error.localizedDescription }
        }
        .confirmationDialog("Import clipboard backup?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Import") { commit() }.disabled((contents?.count ?? 0) == 0)
            Button("Cancel", role: .cancel) { contents = nil }
        } message: {
            if let contents {
                Text("\(contents.count) records to check for duplicates. \(contents.skipped) private or unavailable records skipped.")
            }
        }
    }

    private func export() {
        guard let library = model.library else { return }
        let secret = password
        password = ""
        working = true
        Task { @MainActor in
            defer { working = false }
            do {
                let newURL = try await Task.detached {
                    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                            attributes: [.posixPermissions: 0o700])
                    let url = folder.appendingPathComponent("ClipRelay.clipnote")
                    do { try ClipArchive.export(library, password: secret, to: url); return url }
                    catch { try? FileManager.default.removeItem(at: folder); throw error }
                }.value
                if let exportURL { try? FileManager.default.removeItem(at: exportURL.deletingLastPathComponent()) }
                exportURL = newURL
            } catch { model.notice = error.localizedDescription }
        }
    }

    private func commit() {
        guard let contents, let library = model.library else { return }
        self.contents = nil
        working = true
        Task { @MainActor in
            defer { working = false }
            do {
                let count = try await Task.detached {
                    try library.importArchive(contents.records.map { ($0.clip, $0.source, $0.pinned) }, phrases: contents.phrases)
                }.value
                model.notice = String(localized: "Imported \(count) records")
                model.reload()
            } catch { model.notice = error.localizedDescription }
        }
    }
}
