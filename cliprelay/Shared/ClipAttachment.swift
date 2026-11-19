import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ClipAttachment {
    let byteCount: Int
    let symbol: String
    let thumbnail: CGImage?

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
    }

    init(_ clip: Clip) {
        byteCount = clip.bytes.count
        symbol = Self.symbol(for: clip)
        if clip.kind == "Image", let image = CGImageSourceCreateWithData(clip.bytes as CFData, nil) {
            thumbnail = CGImageSourceCreateThumbnailAtIndex(image, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 144,
            ] as CFDictionary)
        } else {
            thumbnail = nil
        }
    }

    private static let previewQueue = DispatchQueue(label: "cc.macseek.cliprelay.thumbnails", qos: .userInitiated)

    static func load(_ id: String, from library: Library) async -> Self? {
        await withCheckedContinuation { continuation in
            previewQueue.async {
                let attachment = autoreleasepool { (try? library.clip(id)).map(Self.init) }
                continuation.resume(returning: attachment)
            }
        }
    }

    private static func symbol(for clip: Clip) -> String {
        if clip.kind == "Image" { return "photo" }
        let ext = (clip.name as NSString).pathExtension.lowercased()
        let types = [UTType(clip.type), UTType(filenameExtension: ext)].compactMap { $0 }
        func matches(_ type: UTType) -> Bool { types.contains { $0.conforms(to: type) } }
        if matches(.pdf) || ["doc", "docx", "odt", "pages"].contains(ext) { return "doc.richtext" }
        if matches(.spreadsheet) || matches(.commaSeparatedText) { return "tablecells" }
        if matches(.presentation) { return "rectangle.on.rectangle" }
        if matches(.archive) { return "archivebox" }
        if matches(.audio) { return "waveform" }
        if matches(.movie) { return "film" }
        if matches(.sourceCode) || matches(.json) || matches(.xml) { return "chevron.left.forwardslash.chevron.right" }
        if matches(.text) { return "doc.text" }
        return "doc"
    }
}
