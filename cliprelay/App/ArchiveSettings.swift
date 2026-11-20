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
        #if os(macOS)
        settings.alert("Import clipboard backup?", isPresented: $confirm) {
            importActions
        } message: {
            importMessage
        }
        #else
        settings.confirmationDialog("Import clipboard backup?", isPresented: $confirm, titleVisibility: .visible) {
            importActions
        } message: {
            importMessage
        }
        #endif
    }

    private var settings: some View {
        Group {
            #if os(macOS)
            MacSettingsCard(title: "Backup") {
                HStack {
                    passwordField.frame(maxWidth: 170)
                    Spacer()
                    backupActions
                }.padding(.vertical, 9)
                if let exportURL {
                    Divider()
                    shareBackup(exportURL).padding(.top, 9)
                }
            }
            #else
            Section("Backup") {
                passwordField
                backupActions
                if let exportURL { shareBackup(exportURL) }
            }
            #endif
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
    }

    private var passwordField: some View {
        SecureField("Archive password", text: $password).modifier(SettingsInputFocus())
    }

    @ViewBuilder private var backupActions: some View {
        Button("Create encrypted backup", action: export).disabled(working || password.isEmpty)
        Button("Import encrypted backup") { picking = true }.disabled(working || password.isEmpty)
    }

    private func shareBackup(_ url: URL) -> some View {
        ShareLink(item: url) { Label("Share encrypted backup", systemImage: "square.and.arrow.up") }
    }

    @ViewBuilder private var importActions: some View {
        Button("Import") { commit() }.disabled((contents?.count ?? 0) == 0)
        Button("Cancel", role: .cancel) { contents = nil }
    }

    @ViewBuilder private var importMessage: some View {
        if let contents {
            Text("\(contents.count) records to check for duplicates. \(contents.skipped) private or unavailable records skipped.")
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
