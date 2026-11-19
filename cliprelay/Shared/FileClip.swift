import Foundation
import UniformTypeIdentifiers

func fileClip(_ url:URL,type:String?=nil,name:String?=nil,asFile:Bool=true)throws->Clip {
    let scoped=url.startAccessingSecurityScopedResource();defer {if scoped {url.stopAccessingSecurityScopedResource()}}
    let values=try url.resourceValues(forKeys:[.fileSizeKey,.isRegularFileKey,.isSymbolicLinkKey,.contentTypeKey])
    guard values.isRegularFile==true,values.isSymbolicLink != true,let size=values.fileSize,size<=Clip.limit else {throw RelayFailure.tooLarge}
    let handle=try FileHandle(forReadingFrom:url);defer{try? handle.close()}
    let bytes=try handle.read(upToCount:Clip.limit+1) ?? Data()
    let uti=type ?? values.contentType?.identifier ?? UTType.data.identifier
    var clip=Clip(name:String((name ?? url.lastPathComponent).prefix(120)),type:uti,bytes:bytes,isFile:asFile ? true : nil)
    if let text=clip.text {clip.name=String(text.prefix(80))}
    try clip.validate();return clip
}

#if os(iOS)
enum ClipboardPaste {
    static let types: [UTType] = [.fileURL, .rtf, .html, .image, .plainText, .data]

    @MainActor static func load(_ provider: NSItemProvider) async throws -> Clip {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            let url: URL = try await withCheckedThrowingContinuation { reply in
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                    if let url = item as? URL { reply.resume(returning: url) }
                    else { reply.resume(throwing: error ?? RelayFailure.invalid) }
                }
            }
            return try fileClip(url)
        }
        let identifiers = provider.registeredTypeIdentifiers
        let chosen = types.dropFirst().compactMap { group in
            identifiers.first { UTType($0)?.conforms(to: group) == true }
        }.first
        guard let chosen else { throw RelayFailure.invalid }
        let name = provider.suggestedName
        var clip: Clip = try await withCheckedThrowingContinuation { reply in
            provider.loadFileRepresentation(forTypeIdentifier: chosen) { url, error in
                do {
                    guard let url else { throw error ?? RelayFailure.invalid }
                    reply.resume(returning: try fileClip(url, type: chosen, name: name, asFile: false))
                } catch { reply.resume(throwing: error) }
            }
        }
        if clip.kind == "Rich text", provider.canLoadObject(ofClass: NSString.self) {
            let plain: String? = await withCheckedContinuation { reply in
                _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                    reply.resume(returning: (object as? NSString).map(String.init))
                }
            }
            if let plain, plain.utf8.count <= Clip.limit - clip.bytes.count {
                clip.plain = plain
                clip.name = String(plain.prefix(80))
            }
        }
        try clip.validate()
        return clip
    }
}
#endif
