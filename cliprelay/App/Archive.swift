import Foundation
import CommonCrypto
import CryptoKit
import Security
import UniformTypeIdentifiers

enum ClipArchive {
    private static let magic = Data("CLIPARC\u{01}".utf8)
    private static let legacyMagic = Data("RAYCLIP\u{01}".utf8)
    private static let maximumBytes = 168_000_000
    private static let legacyMaximumBytes = 16 * 1024 * 1024
    private static let maximumRecords = 5_000
    private static let recordLimit = Clip.limit + 4_096

    enum Failure: LocalizedError {
        case password, invalid
        var errorDescription: String? {
            switch self {
            case .password: String(localized: "Use a nonblank archive password up to 1,024 bytes")
            case .invalid: String(localized: "Incorrect password or damaged archive")
            }
        }
    }

    struct Record: Codable {
        var clip: Clip
        var source: String
        var pinned: Bool
        var phrase: SavedPhrase?
    }

    private struct LegacyRecord: Codable {
        let id: UUID
        let kind: String
        let value: String
        let imageData: Data?
        let createdAt: Date
        let sourceApplicationName: String?
        let isPinned: Bool
        let isPrivate: Bool
    }

    struct Contents {
        var records: [Record] = []
        var phrases: [SavedPhrase] = []
        var count: Int { records.count + phrases.count }
        var skipped = 0
    }

    private static func derive(_ password: String, salt: Data) throws -> SymmetricKey {
        guard !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              password.utf8.count <= 1_024 else { throw Failure.password }
        var bytes = Array(password.utf8)
        var key = Data(count: 32)
        defer {
            _ = bytes.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) }
            key.resetBytes(in: 0..<key.count)
        }
        let status = bytes.withUnsafeBytes { pass in
            salt.withUnsafeBytes { salt in
                key.withUnsafeMutableBytes { out in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                        pass.baseAddress!.assumingMemoryBound(to: Int8.self), pass.count,
                        salt.baseAddress!.assumingMemoryBound(to: UInt8.self), salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 600_000,
                        out.baseAddress!.assumingMemoryBound(to: UInt8.self), out.count)
                }
            }
        }
        guard status == kCCSuccess else { throw RelayFailure.storage }
        return SymmetricKey(data: key)
    }

    private static func number(_ n: Int) -> Data {
        var bigEndian = UInt32(n).bigEndian
        return withUnsafeBytes(of: &bigEndian) { Data($0) }
    }

    private static func integer(_ data: Data) -> Int { data.reduce(0) { ($0 << 8) | Int($1) } }

    static func export(_ library: Library, password: String, to url: URL) throws {
        let records = try library.archiveIDs()
        let phrases = Array(try library.phrases(limit: 1000).reversed())
        let count = records.count + phrases.count
        guard count <= maximumRecords else { throw Failure.invalid }
        var salt = Data(count: 16)
        guard salt.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) })
                == errSecSuccess else { throw RelayFailure.storage }
        let header = magic + salt + number(count)
        let key = try derive(password, salt: salt)
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw RelayFailure.storage
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.write(contentsOf: header)
        var size = header.count
        for index in 0...count {
            let plaintext: Data
            if index == count {
                plaintext = Data()
            } else if index >= records.count {
                let p = phrases[index-records.count]
                var clip = Clip.text(p.text); clip.id = p.id
                plaintext = try Codec.pack(Record(clip: clip, source: "Keyboard", pinned: true, phrase: p))
            } else {
                let entry = records[index]
                var clip = try library.clip(entry.id)
                clip.date = entry.captured
                plaintext = try Codec.pack(Record(clip: clip, source: entry.source, pinned: entry.pinned))
            }
            guard plaintext.count <= recordLimit,
                  let frame = try AES.GCM.seal(plaintext, using: key, authenticating: header + number(index)).combined
            else { throw Failure.invalid }
            size += 4 + frame.count
            guard size <= maximumBytes else { throw Failure.invalid }
            try handle.write(contentsOf: number(frame.count) + frame)
        }
        try handle.close()
    }

    static func read(_ url: URL, password: String) throws -> Contents {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= maximumBytes else { throw Failure.invalid }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        func exact(_ count: Int) throws -> Data {
            guard let data = try handle.read(upToCount: count), data.count == count else { throw Failure.invalid }
            return data
        }
        let prefix = try exact(8)
        guard prefix == magic || prefix == legacyMagic else { throw Failure.invalid }
        let salt = try exact(16)
        let key = try derive(password, salt: salt)
        if prefix == legacyMagic {
            guard size >= 52, size <= legacyMaximumBytes + 64 else { throw Failure.invalid }
            let plain = try open(exact(size - 24), key: key, aad: prefix + salt)
            guard (try handle.read(upToCount: 1) ?? Data()).isEmpty else { throw Failure.invalid }
            return try decodeLegacy(plain)
        }
        let countBytes = try exact(4)
        let count = integer(countBytes)
        guard count <= maximumRecords else { throw Failure.invalid }
        let header = prefix + salt + countBytes
        var readSize = header.count
        var contents = Contents()
        var seen = Set<UUID>()
        for index in 0...count {
            let frameSize = integer(try exact(4))
            readSize += 4 + frameSize
            guard (28...recordLimit + 28).contains(frameSize), readSize <= maximumBytes else { throw Failure.invalid }
            let plain = try open(exact(frameSize), key: key, aad: header + number(index))
            if index == count {
                guard plain.isEmpty else { throw Failure.invalid }
                break
            }
            let record = try Codec.read(Record.self, plain)
            try record.clip.validate()
            guard record.source.utf8.count <= 512, record.clip.date.timeIntervalSinceReferenceDate.isFinite,
                  seen.insert(record.clip.id).inserted else { throw Failure.invalid }
            if let phrase = record.phrase {
                try phrase.validate()
                guard phrase.id == record.clip.id, phrase.text == record.clip.text, contents.phrases.count < 1000 else { throw Failure.invalid }
                contents.phrases.append(phrase)
            } else { contents.records.append(record) }
        }
        guard (try handle.read(upToCount: 1) ?? Data()).isEmpty else { throw Failure.invalid }
        return contents
    }

    private static func open(_ data: Data, key: SymmetricKey, aad: Data) throws -> Data {
        do { return try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key, authenticating: aad) }
        catch { throw Failure.invalid }
    }

    private static func decodeLegacy(_ data: Data) throws -> Contents {
        guard data.count <= legacyMaximumBytes else { throw Failure.invalid }
        var offset = 0
        func take(_ count: Int) throws -> Data {
            guard count <= data.count - offset else { throw Failure.invalid }
            defer { offset += count }
            return data.subdata(in: offset..<offset + count)
        }
        let count = integer(try take(4))
        guard count <= maximumRecords else { throw Failure.invalid }
        var contents = Contents()
        var seen = Set<UUID>()
        for _ in 0..<count {
            let length = integer(try take(4))
            guard (1...2 * 1024 * 1024).contains(length) else { throw Failure.invalid }
            let entry = try JSONDecoder().decode(LegacyRecord.self, from: take(length))
            guard seen.insert(entry.id).inserted, entry.createdAt.timeIntervalSinceReferenceDate.isFinite else {
                throw Failure.invalid
            }
            var clip: Clip
            switch entry.kind {
            case "text":
                guard entry.imageData == nil else { throw Failure.invalid }
                clip = .text(entry.value)
            case "image":
                guard let bytes = entry.imageData else { throw Failure.invalid }
                clip = Clip(name: "Image", type: UTType.tiff.identifier, bytes: bytes)
            case "file":
                guard entry.imageData == nil, entry.value.split(separator: "\n", omittingEmptySubsequences: false)
                    .allSatisfy({ $0.hasPrefix("/") && !$0.utf8.contains(0) }) else { throw Failure.invalid }
                contents.skipped += 1
                continue
            default: throw Failure.invalid
            }
            try clip.validate()
            if entry.isPrivate { contents.skipped += 1; continue }
            clip.id = entry.id
            clip.date = entry.createdAt
            let source = String((entry.sourceApplicationName ?? "AuvCast").prefix(120))
            contents.records.append(Record(clip: clip, source: source, pinned: entry.isPinned))
        }
        guard offset == data.count else { throw Failure.invalid }
        return contents
    }
}

#if DEBUG
extension ClipArchive {
    static func selfCheck(in root: URL) throws {
        let scratch = root.appendingPathComponent(UUID().uuidString)
        let source = try Library(scratch.appendingPathComponent("source"))
        let target = try Library(scratch.appendingPathComponent("target"))
        let clip = Clip(name: "Styled", type: UTType.rtf.identifier, bytes: Data("{\\rtf1 Styled}".utf8), plain: "Styled")
        try source.save(clip, source: "QA")
        try source.pin(clip.id.uuidString)
        let url = scratch.appendingPathComponent("check.clipnote")
        let password = "backup-QA"
        let phrase = SavedPhrase(text: "下次见", code: "xcj", folder: "问候")
        try source.savePhrase(phrase)
        let other = SavedPhrase(text: "稍后联系")
        try source.savePhrase(other)
        try source.movePhraseFirst(phrase.id)
        guard try source.phrases().first == phrase,
              (try? source.savePhrase(SavedPhrase(text: String(repeating: "字", count: 501)))) == nil else { throw RelayFailure.invalid }
        try source.deletePhrase(other.id)
        try export(source, password: password, to: url)
        do {
            _ = try read(url, password: "wrong")
            throw RelayFailure.invalid
        } catch Failure.invalid {}
        let contents = try read(url, password: password)
        let records = contents.records.map { ($0.clip, $0.source, $0.pinned) }
        guard try target.importArchive(records, phrases: contents.phrases) == 2,
              try target.phrases(code: "xcj") == [phrase],
              try target.clip(clip.id.uuidString).bytes == clip.bytes,
              try target.page().first?.pinned == true else { throw RelayFailure.invalid }
        var edited = phrase; edited.text = "本机修改"
        try target.savePhrase(edited)
        guard try target.importArchive(records, phrases: contents.phrases) == 0,
              try target.phrases() == [edited] else { throw RelayFailure.invalid }
        let stream = try FileHandle(forWritingTo: url)
        let end = try stream.seekToEnd()
        try stream.truncate(atOffset: end - 1)
        try stream.close()
        do {
            _ = try read(url, password: password)
            throw RelayFailure.invalid
        } catch Failure.invalid {}
        let date = Date.now
        let legacyRecords = [
            LegacyRecord(id: UUID(), kind: "text", value: "Legacy text", imageData: nil, createdAt: date,
                         sourceApplicationName: "AuvCast", isPinned: true, isPrivate: false),
            LegacyRecord(id: UUID(), kind: "text", value: "Private text", imageData: nil, createdAt: date,
                         sourceApplicationName: nil, isPinned: false, isPrivate: true),
            LegacyRecord(id: UUID(), kind: "file", value: url.path, imageData: nil, createdAt: date,
                         sourceApplicationName: nil, isPinned: false, isPrivate: false),
        ]
        var clear = number(legacyRecords.count)
        for row in legacyRecords {
            let encoded = try JSONEncoder().encode(row)
            clear += number(encoded.count) + encoded
        }
        let salt = Data(repeating: 1, count: 16)
        let header = legacyMagic + salt
        let box = try AES.GCM.seal(clear, using: derive(password, salt: salt), authenticating: header)
        guard let sealed = box.combined else { throw RelayFailure.invalid }
        let legacy = scratch.appendingPathComponent("check.rayonclip")
        try (header + sealed).write(to: legacy)
        let converted = try read(legacy, password: password)
        guard converted.records.count == 1, converted.skipped == 2,
              converted.records.first?.clip.text == "Legacy text",
              converted.records.first?.pinned == true else { throw RelayFailure.invalid }
    }
}
#endif
