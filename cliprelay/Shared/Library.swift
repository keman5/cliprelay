import Foundation
import SQLite3

struct Summary: Identifiable {
    let id: String
    let name: String
    let kind: String
    let source: String
    let pinned: Bool
    var date: Date? = nil
    var type: String? = nil
    var burn = false
    var expires: Date? = nil
    var expirySeconds: Double? = nil
    var localOnly = false
    var received: Bool? = nil
}

struct SavedPhrase: Identifiable, Codable, Equatable {
    var id = UUID()
    var text = ""
    var code = ""
    var folder = ""
    func validate() throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 500,
              text.utf8.count <= 32_768, code.utf8.count <= 10,
              code.utf8.allSatisfy({ (97...122).contains($0) }), folder.count <= 32,
              ![text, folder].contains(where: { $0.utf8.contains(0) }) else { throw RelayFailure.invalid }
    }
}

final class Library {
    let root: URL
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    private struct PageKey: Equatable {
        let kind: String, search: String, offset: Int
        let pinnedFirst: Bool
    }
    private var cachedPages: [(key: PageKey, rows: [Summary])] = []
    private var cacheVersion: (local: Int64, external: Int64) = (-1, -1)
    static func directory() throws -> URL {
        #if os(iOS)
        guard let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier:"group.cc.macseek.cliprelay") else { throw RelayFailure.storage }
        return root.appendingPathComponent("Library/ClipRelay")
        #else
        return try FileManager.default.url(for:.applicationSupportDirectory,in:.userDomainMask,appropriateFor:nil,create:true).appendingPathComponent("cc.macseek.cliprelay")
        #endif
    }
    init(_ root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        guard sqlite3_open_v2(root.appendingPathComponent("history.sqlite").path,&db,SQLITE_OPEN_READWRITE|SQLITE_OPEN_CREATE|SQLITE_OPEN_FULLMUTEX,nil) == SQLITE_OK else { throw RelayFailure.storage }
        sqlite3_busy_timeout(db, 3000)
        guard sqlite3_exec(db,"PRAGMA journal_mode=WAL; CREATE TABLE IF NOT EXISTS clips(id TEXT PRIMARY KEY, name TEXT, kind TEXT, source TEXT, pinned INTEGER DEFAULT 0, data BLOB NOT NULL); CREATE TABLE IF NOT EXISTS peers(id TEXT PRIMARY KEY, card BLOB NOT NULL); CREATE TABLE IF NOT EXISTS pending(id TEXT,peer TEXT,wire BLOB NOT NULL,PRIMARY KEY(id,peer)); CREATE TABLE IF NOT EXISTS forward(id TEXT, origin TEXT, peer TEXT, wire BLOB NOT NULL, PRIMARY KEY(id,origin,peer));",nil,nil,nil)==SQLITE_OK else { throw RelayFailure.storage }
        try run("CREATE TABLE IF NOT EXISTS share_send(id TEXT, peer TEXT, PRIMARY KEY(id, peer))")
        try run("CREATE TABLE IF NOT EXISTS pairing_dates(peer TEXT PRIMARY KEY, date REAL NOT NULL)")
        try run("CREATE TRIGGER IF NOT EXISTS save_pairing_date AFTER INSERT ON peers BEGIN INSERT OR IGNORE INTO pairing_dates VALUES(NEW.id, unixepoch()); END")
        try run("CREATE TRIGGER IF NOT EXISTS remove_pairing_date AFTER DELETE ON peers BEGIN DELETE FROM pairing_dates WHERE peer=OLD.id; END")
        try run("CREATE TABLE IF NOT EXISTS lan_addresses(peer TEXT PRIMARY KEY,address TEXT NOT NULL)")
        try run("CREATE TABLE IF NOT EXISTS phrases(id TEXT PRIMARY KEY, body TEXT NOT NULL, code TEXT NOT NULL, folder TEXT NOT NULL, rank INTEGER NOT NULL)")
        guard sqlite3_exec(db, """
            CREATE TABLE IF NOT EXISTS directory_revision(value INTEGER NOT NULL);
            INSERT INTO directory_revision SELECT 0 WHERE NOT EXISTS (SELECT 1 FROM directory_revision);
            CREATE TRIGGER IF NOT EXISTS directory_insert AFTER INSERT ON peers BEGIN UPDATE directory_revision SET value=value+1; END;
            CREATE TRIGGER IF NOT EXISTS directory_delete AFTER DELETE ON peers BEGIN UPDATE directory_revision SET value=value+1; END;
            CREATE TABLE IF NOT EXISTS directory_settings(slot INTEGER PRIMARY KEY, owner TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS directory_state(owner TEXT PRIMARY KEY, revision INTEGER NOT NULL, digest TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS directory_members(id TEXT PRIMARY KEY, card BLOB NOT NULL, expires INTEGER NOT NULL);
            CREATE VIEW IF NOT EXISTS effective_peers AS SELECT id,card FROM peers UNION ALL
                SELECT id,card FROM directory_members WHERE expires>unixepoch()
                AND EXISTS(SELECT 1 FROM directory_settings JOIN peers ON owner=peers.id)
                AND id NOT IN(SELECT id FROM peers);
            """, nil, nil, nil) == SQLITE_OK else { throw RelayFailure.storage }
        if try schemaVersion() < 4 {
            try run("BEGIN IMMEDIATE")
            do {
                if try schemaVersion() == 0 {
                    let old = try query("SELECT id FROM clips WHERE pinned=1 AND kind IN ('Text','Rich text') AND length(data)<65536 ORDER BY rowid DESC LIMIT 1000") { self.string($0,0) }
                    for id in old.reversed() {
                        if let text = try readClip(id).text {
                            let p = SavedPhrase(text: text)
                            if (try? p.validate()) != nil, try phraseCount() < 1000 { try savePhrase(p) }
                        }
                    }
                    try run("PRAGMA user_version=1")
                }
                if try schemaVersion() == 1 {
                    try run("ALTER TABLE clips ADD COLUMN content_key TEXT")
                    let ids = try query("SELECT id FROM clips") { self.string($0, 0) }
                    for id in ids {
                        let key = try contentKey(readClip(id))
                        try run("UPDATE clips SET content_key=? WHERE id=?", [.text(key), .text(id)])
                    }
                    try run("CREATE INDEX clips_content_key ON clips(content_key)")
                    try run("PRAGMA user_version=2")
                }
                if try schemaVersion() == 2 {
                    try run("ALTER TABLE clips ADD COLUMN captured REAL")
                    try run("ALTER TABLE clips ADD COLUMN uti TEXT")
                    try run("ALTER TABLE clips ADD COLUMN burn INTEGER NOT NULL DEFAULT 0")
                    try run("ALTER TABLE clips ADD COLUMN expires REAL")
                    try run("ALTER TABLE clips ADD COLUMN expiry_seconds REAL")
                    try run("ALTER TABLE clips ADD COLUMN shared INTEGER NOT NULL DEFAULT 1")
                    let ids = try query("SELECT id FROM clips") { self.string($0, 0) }
                    for id in ids {
                        let clip = try readClip(id)
                        try run("UPDATE clips SET captured=CAST(? AS REAL), uti=? WHERE id=?",
                                [.text(String(clip.date.timeIntervalSince1970)), .text(clip.type), .text(id)])
                    }
                    try run("CREATE INDEX clips_expires ON clips(expires) WHERE expires IS NOT NULL")
                    try run("PRAGMA user_version=3")
                }
                if try schemaVersion() == 3 {
                    try run("ALTER TABLE clips ADD COLUMN received INTEGER")
                    try run("PRAGMA user_version=4")
                }
                try run("COMMIT")
            } catch { try? run("ROLLBACK"); throw error }
        }
    }
    deinit { sqlite3_close(db) }

    private func schemaVersion() throws -> Int32 {
        try query("PRAGMA user_version") { sqlite3_column_int($0, 0) }.first ?? 0
    }
    func phraseCount() throws -> Int {
        try query("SELECT COUNT(*) FROM phrases") { Int(sqlite3_column_int($0,0)) }.first ?? 0
    }
    func phrases(offset: Int = 0, limit: Int = 30, code: String = "") throws -> [SavedPhrase] {
        try query("SELECT id,body,code,folder FROM phrases WHERE ?='' OR code=? ORDER BY rank DESC,id LIMIT CAST(? AS INTEGER) OFFSET CAST(? AS INTEGER)",
                  [.text(code), .text(code), .text(String(limit)), .text(String(offset))]) { row in
            SavedPhrase(id: UUID(uuidString: self.string(row,0))!, text: self.string(row,1), code: self.string(row,2), folder: self.string(row,3))
        }
    }
    func savePhrase(_ p: SavedPhrase) throws {
        try p.validate()
        let id = p.id.uuidString
        try run("""
            INSERT INTO phrases(id,body,code,folder,rank) SELECT ?,?,?,?,COALESCE(MAX(rank),0)+1 FROM phrases
            HAVING COUNT(*)<1000 OR EXISTS(SELECT 1 FROM phrases WHERE id=?)
            ON CONFLICT(id) DO UPDATE SET body=excluded.body,code=excluded.code,folder=excluded.folder
            """, [.text(id), .text(p.text), .text(p.code), .text(p.folder), .text(id)])
        guard try query("SELECT 1 FROM phrases WHERE id=?", [.text(id)], {_ in true}).first == true else { throw RelayFailure.storage }
    }
    func movePhraseFirst(_ id: UUID) throws {
        try run("UPDATE phrases SET rank=(SELECT MAX(rank)+1 FROM phrases) WHERE id=?", [.text(id.uuidString)])
    }
    func deletePhrase(_ id: UUID) throws { try run("DELETE FROM phrases WHERE id=?", [.text(id.uuidString)]) }
    enum Value { case text(String), bytes(Data) }
    @discardableResult private func query<T>(_ sql: String, _ args: [Value] = [], _ row: (OpaquePointer)->T) throws -> [T] {
        lock.lock(); defer {lock.unlock()}
        var raw: OpaquePointer?
        guard sqlite3_prepare_v2(db,sql,-1,&raw,nil)==SQLITE_OK, let stmt=raw else {throw RelayFailure.storage}
        defer {sqlite3_finalize(stmt)}
        let copy = unsafeBitCast(-1,to:sqlite3_destructor_type.self)
        for (i,v) in args.enumerated() {
            let n=Int32(i+1)
            let rc: Int32
            switch v {
            case .text(let s): rc = sqlite3_bind_text(stmt,n,s,-1,copy)
            case .bytes(let d): rc = d.withUnsafeBytes {sqlite3_bind_blob(stmt,n,$0.baseAddress,Int32($0.count),copy)}
            }
            guard rc==SQLITE_OK else {throw RelayFailure.storage}
        }
        var result:[T]=[]
        while true { switch sqlite3_step(stmt) {
        case SQLITE_ROW: result.append(row(stmt))
        case SQLITE_DONE: return result
        default: throw RelayFailure.storage
        } }
    }
    private func run(_ sql:String,_ args:[Value]=[]) throws {try query(sql,args){_ in ()}}
    private func blob(_ s:OpaquePointer,_ i:Int32)->Data { Data(bytes:sqlite3_column_blob(s,i),count:Int(sqlite3_column_bytes(s,i))) }
    private func string(_ s:OpaquePointer,_ i:Int32)->String {String(cString:sqlite3_column_text(s,i))}
    struct Usage {
        let entries: Int64, historyBytes: Int64, jobs: Int64, queuedBytes: Int64
    }
    func usage() throws -> Usage {
        let sql = """
            SELECT COUNT(*),COALESCE(SUM(length(data)),0),
            (SELECT COUNT(*) FROM pending)+(SELECT COUNT(*) FROM forward)+(SELECT COUNT(*) FROM share_send),
            (SELECT COALESCE(SUM(length(wire)),0) FROM pending)+(SELECT COALESCE(SUM(length(wire)),0) FROM forward)
            FROM clips
            """
        guard let value = try query(sql, [], { row in
            Usage(entries: sqlite3_column_int64(row, 0), historyBytes: sqlite3_column_int64(row, 1),
                  jobs: sqlite3_column_int64(row, 2), queuedBytes: sqlite3_column_int64(row, 3))
        }).first else { throw RelayFailure.storage }
        return value
    }
    private func contentKey(_ clip: Clip) -> String {
        // Plain text can arrive with different UTI spellings from the system pickers.
        let type = clip.kind == "Text" ? "" : clip.type
        return "\(clip.kind):\(type):\(Codec.hash(clip.bytes))"
    }

    private func insert(_ clip: Clip, source: String, pinned: Bool = false, key: String, received: Bool? = false) throws {
        try run("INSERT INTO clips(id,name,kind,source,pinned,data,content_key,captured,uti,shared,received) VALUES(?,?,?,?,CAST(? AS INTEGER),?,?,CAST(? AS REAL),?,CAST(? AS INTEGER),CAST(NULLIF(?,'') AS INTEGER))",
                [.text(clip.id.uuidString), .text(clip.name), .text(clip.kind), .text(source),
                 .text(pinned ? "1" : "0"), .bytes(try Codec.pack(clip)), .text(key),
                 .text(String(clip.date.timeIntervalSince1970)), .text(clip.type), .text(received == true ? "1" : "0"), .text(received.map { $0 ? "1" : "0" } ?? "")])
    }

    // Incoming messages and archives retain their original IDs for retries and acknowledgements.
    func save(_ clip: Clip, source: String, sendToPeers: Bool = false, received: Bool = false) throws {
        lock.lock(); defer {lock.unlock()}
        try run("BEGIN IMMEDIATE")
        do {
            try clip.validate()
            let id = clip.id.uuidString
            if let previous = try query("SELECT data FROM clips WHERE id=?", [.text(id)], {self.blob($0,0)}).first {
                let existing = try Codec.read(Clip.self, previous)
                guard existing.bytes == clip.bytes, existing.type == clip.type, existing.plain == clip.plain,
                      existing.kind == clip.kind else { throw RelayFailure.invalid }
            } else {
                try insert(clip, source: source, key: contentKey(clip), received: received)
            }
            if sendToPeers {
                try run("INSERT OR IGNORE INTO share_send SELECT ?, id FROM effective_peers", [.text(id)])
            }
            try prune(protecting: [id])
            try run("COMMIT")
        } catch {try? run("ROLLBACK"); throw error}
    }

    @discardableResult
    func saveCopies(_ clips: [Clip], source: String, sendToPeers: Bool = false) throws -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        try run("BEGIN IMMEDIATE")
        do {
            var saved: Set<String> = []
            for clip in clips {
                try clip.validate()
                let key = contentKey(clip)
                let previous = try query("SELECT id FROM clips WHERE content_key=? AND (expires IS NULL OR expires > unixepoch()) ORDER BY pinned DESC,rowid DESC LIMIT 1", [.text(key)]) {
                    self.string($0, 0)
                }.first
                let id = previous ?? clip.id.uuidString
                if previous != nil {
                    try markRecent(id, source: source)
                } else {
                    try insert(clip, source: source, key: key)
                }
                if sendToPeers {
                    try run("INSERT OR IGNORE INTO share_send SELECT ?, id FROM effective_peers", [.text(id)])
                }
                saved.insert(id)
            }
            try prune(protecting: saved)
            try run("COMMIT")
            return saved
        } catch { try? run("ROLLBACK"); throw error }
    }

    func markRecent(_ id: String, source: String = "") throws {
        try run("UPDATE clips SET rowid=(SELECT MAX(rowid)+1 FROM clips),source=COALESCE(NULLIF(?,''),source),received=CASE WHEN ?='' THEN received ELSE 0 END WHERE id=?",
                [.text(source), .text(source), .text(id)])
    }

    private func prune(protecting saved: Set<String>) throws {
        try run("DELETE FROM clips WHERE pinned=0 AND rowid NOT IN (SELECT rowid FROM clips ORDER BY rowid DESC LIMIT 1000) AND id NOT IN (SELECT id FROM pending) AND id NOT IN (SELECT id FROM share_send)")
        var size = try usage().historyBytes
        guard size > 160_000_000 else { return }
        let removable = try query("""
            SELECT id,length(data) FROM clips WHERE pinned=0
            AND id NOT IN (SELECT id FROM pending) AND id NOT IN (SELECT id FROM share_send)
            ORDER BY rowid
            """) { (self.string($0, 0), sqlite3_column_int64($0, 1)) }
        for (id, bytes) in removable where !saved.contains(id) {
            try run("DELETE FROM clips WHERE id=?", [.text(id)])
            size -= bytes
            if size <= 150_000_000 { break }
        }
        guard size <= 160_000_000 else { throw RelayFailure.storage }
    }

    func recordCount(kind: String, search: String = "") throws -> Int {
        try purgeExpired()
        return try query("SELECT COUNT(*) FROM clips WHERE (?='' OR kind=? OR (?='Pinned' AND pinned=1)) AND instr(lower(name),lower(?))>0", [.text(kind), .text(kind), .text(kind), .text(search)]) {
            Int(sqlite3_column_int64($0, 0))
        }.first ?? 0
    }
    func page(kind:String="",search:String="",offset:Int=0,pinnedFirst:Bool=false) throws -> [Summary] {
        lock.lock(); defer { lock.unlock() }
        try purgeExpired()
        // SQLite's data_version tracks other connections, total_changes tracks this one.
        let external = try query("PRAGMA data_version") { sqlite3_column_int64($0, 0) }.first ?? 0
        let version = (Int64(sqlite3_total_changes(db)), external)
        if version != cacheVersion {
            cachedPages.removeAll(keepingCapacity: true)
            cacheVersion = version
        }
        let key = PageKey(kind: kind, search: search, offset: max(0, offset), pinnedFirst: pinnedFirst)
        if let index = cachedPages.firstIndex(where: { $0.key == key }) {
            let hit = cachedPages.remove(at: index)
            cachedPages.append(hit)
            return hit.rows
        }
        let order = pinnedFirst ? "pinned DESC, rowid DESC" : "rowid DESC"
        let rows = try query("SELECT \(Self.summaryColumns) FROM clips WHERE (?='' OR kind=? OR (?='Pinned' AND pinned=1)) AND instr(lower(name),lower(?))>0 ORDER BY \(order) LIMIT 30 OFFSET CAST(? AS INTEGER)",[.text(kind),.text(kind),.text(kind),.text(search),.text(String(key.offset))]) { s in
            self.summary(s)
        }
        if cachedPages.count == 4 { cachedPages.removeFirst() }
        cachedPages.append((key, rows))
        return rows
    }
    private static let summaryColumns = "id,name,kind,source,pinned,captured,uti,burn,expires,shared,expiry_seconds,received"

    private func summary(_ statement: OpaquePointer) -> Summary {
        func date(_ column: Int32) -> Date? {
            sqlite3_column_type(statement, column) == SQLITE_NULL
                ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, column))
        }
        return Summary(id: string(statement, 0), name: string(statement, 1), kind: string(statement, 2),
                       source: string(statement, 3), pinned: sqlite3_column_int(statement, 4) != 0,
                       date: date(5), type: sqlite3_column_type(statement, 6) == SQLITE_NULL ? nil : string(statement, 6),
                       burn: sqlite3_column_int(statement, 7) != 0, expires: date(8),
                       expirySeconds: sqlite3_column_type(statement, 10) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 10),
                       localOnly: sqlite3_column_int(statement, 9) == 0,
                       received: sqlite3_column_type(statement, 11) == SQLITE_NULL ? nil : sqlite3_column_int(statement, 11) != 0)
    }

    #if os(macOS)
    func macHistory(search: String = "") throws -> [Summary] {
        lock.lock(); defer { lock.unlock() }
        try purgeExpired()
        let rows = try query("SELECT \(Self.summaryColumns) FROM clips ORDER BY pinned DESC, rowid DESC", [], summary)
        guard !search.isEmpty else { return rows }
        return try rows.filter { row in
            if row.name.localizedCaseInsensitiveContains(search) { return true }
            guard row.kind == "Text" || row.kind == "Rich text" else { return false }
            return try readClip(row.id).text?.localizedCaseInsensitiveContains(search) == true
        }
    }
    #endif

    func archiveIDs() throws -> [(id: String, source: String, pinned: Bool)] {
        try purgeExpired()
        return try query("SELECT id, source, pinned FROM clips ORDER BY rowid") {
            (self.string($0, 0), self.string($0, 1), sqlite3_column_int($0, 2) != 0)
        }
    }
    func importArchive(_ records: [(clip: Clip, source: String, pinned: Bool)], phrases: [SavedPhrase] = [], sendToPeers: Bool = false) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        try run("BEGIN IMMEDIATE")
        do {
            if sendToPeers, try peers().isEmpty { throw RelayFailure.unauthorized }
            var added = 0
            for p in phrases {
                if try query("SELECT 1 FROM phrases WHERE id=?", [.text(p.id.uuidString)], {_ in true}).first == true { continue }
                try savePhrase(p); added += 1
            }
            for (clip, source, pinned) in records {
                try clip.validate()
                let id = clip.id.uuidString
                if let previous = try query("SELECT data FROM clips WHERE id=?", [.text(id)], { self.blob($0, 0) }).first {
                    let existing = try Codec.read(Clip.self, previous)
                    guard existing.bytes == clip.bytes, existing.type == clip.type, existing.plain == clip.plain,
                          existing.kind == clip.kind else {
                        throw RelayFailure.invalid
                    }
                    continue
                }
                try insert(clip, source: source, pinned: pinned, key: contentKey(clip), received: nil)
                if sendToPeers { try run("INSERT INTO share_send SELECT ?, id FROM effective_peers", [.text(id)]) }
                added += 1
            }
            let size = try query("SELECT COALESCE(SUM(length(data)),0) FROM clips") { sqlite3_column_int64($0, 0) }.first ?? 0
            guard size <= 160_000_000 else { throw RelayFailure.storage }
            try run("COMMIT")
            return added
        } catch {
            try? run("ROLLBACK")
            throw error
        }
    }
    func sharedSends(_ peer: Peer) throws -> [String] {
        try query("SELECT id FROM share_send WHERE peer=? ORDER BY rowid LIMIT 30", [.text(peer.id)]) { self.string($0, 0) }
    }
    func completeSharedSend(_ id: String, to peer: Peer) throws {
        try run("DELETE FROM share_send WHERE id=? AND peer=?", [.text(id), .text(peer.id)])
    }
    func prepareSharedSend(_ id: String, from me: Identity, to peer: Peer, maxBytes: Int = .max) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        try run("BEGIN IMMEDIATE")
        do {
            let size = try query("SELECT length(data) FROM clips JOIN share_send USING(id) WHERE id=? AND peer=?",
                                 [.text(id), .text(peer.id)]) { sqlite3_column_int64($0, 0) }.first
            if let size, size <= maxBytes {
                let bytes = try Codec.pack(clip(id))
                try queue(id, peer: peer, wire: Envelope.seal(bytes, from: me, to: peer))
                try completeSharedSend(id, to: peer)
                try run("COMMIT")
                return true
            }
            try run("COMMIT")
            return false
        } catch { try? run("ROLLBACK"); throw error }
    }
    private func readClip(_ id: String) throws -> Clip {
        guard let data = try query("SELECT data FROM clips WHERE id=?",[.text(id)],{self.blob($0,0)}).first else {throw RelayFailure.invalid}
        return try Codec.read(Clip.self,data)
    }
    func clip(_ id: String) throws -> Clip {
        let exists = try query("SELECT 1 FROM clips WHERE id=? AND (expires IS NULL OR expires > unixepoch())",
                               [.text(id)]) { _ in true }.first ?? false
        guard exists else { throw RelayFailure.invalid }
        return try readClip(id)
    }

    func useClip(_ id: String, _ use: (Clip) throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        try run("BEGIN IMMEDIATE")
        do {
            let clip = try self.clip(id)
            let burn = try query("SELECT burn FROM clips WHERE id=?", [.text(id)]) {
                sqlite3_column_int($0, 0) != 0
            }.first ?? false
            try use(clip)
            if burn { try removeClip(id) } else { try markRecent(id) }
            try run("COMMIT")
        } catch { try? run("ROLLBACK"); throw error }
    }

    func setBurn(_ id: String, _ enabled: Bool) throws {
        try run("UPDATE clips SET burn=CAST(? AS INTEGER) WHERE id=?", [.text(enabled ? "1" : "0"), .text(id)])
    }

    func setExpiry(_ id: String, after seconds: TimeInterval?, now: Date = .now) throws {
        let expiry = seconds.map { String(floor(now.timeIntervalSince1970 + $0)) } ?? ""
        try run("UPDATE clips SET expires=CAST(NULLIF(?, '') AS REAL), expiry_seconds=CAST(NULLIF(?, '') AS REAL) WHERE id=?",
                [.text(expiry), .text(seconds.map { String($0) } ?? ""), .text(id)])
    }

    @discardableResult func purgeExpired() throws -> Bool {
        #if os(macOS)
        let hours = UserDefaults.standard.integer(forKey: "mac.historyRetentionHours")
        #else
        let hours = 0
        #endif
        let now = Date.now.timeIntervalSince1970
        let cutoff = now - Double(hours) * 3_600
        let condition = "expires <= CAST(? AS REAL)" + (hours > 0 ? " OR (pinned=0 AND captured <= CAST(? AS REAL))" : "")
        let args: [Value] = [.text(String(now))] + (hours > 0 ? [.text(String(cutoff))] : [])
        lock.lock(); defer { lock.unlock() }
        let ids = try query("SELECT id FROM clips WHERE " + condition, args) { self.string($0, 0) }
        guard !ids.isEmpty else { return false }
        try run("BEGIN IMMEDIATE")
        do {
            for id in ids {
                let stillExpired = try query("SELECT 1 FROM clips WHERE id=? AND (" + condition + ")",
                                             [.text(id)] + args) { _ in true }.first ?? false
                if stillExpired { try removeClip(id) }
            }
            try run("COMMIT")
        } catch { try? run("ROLLBACK"); throw error }
        return true
    }

    #if os(macOS)
    func clearHistory() throws {
        lock.lock(); defer { lock.unlock() }
        try run("BEGIN IMMEDIATE")
        do {
            try run("DELETE FROM share_send")
            try run("DELETE FROM pending")
            try run("DELETE FROM forward")
            try run("DELETE FROM clips")
            try run("COMMIT")
        } catch { try? run("ROLLBACK"); throw error }
    }

    func clearReadCache() {
        lock.lock(); defer { lock.unlock() }
        cachedPages.removeAll()
    }

    func pairingDate(_ peer: Peer) throws -> Date? {
        try query("SELECT date FROM pairing_dates WHERE peer=?", [.text(peer.id)]) {
            Date(timeIntervalSince1970: sqlite3_column_double($0, 0))
        }.first
    }
    #endif

    func pin(_ id: String) throws {
        try run("UPDATE clips SET pinned=1-pinned WHERE id=?", [.text(id)])
    }

    func setPinned(_ ids: Set<String>) throws {
        lock.lock(); defer { lock.unlock() }
        try run("BEGIN IMMEDIATE")
        do {
            for id in ids { try run("UPDATE clips SET pinned=1 WHERE id=?", [.text(id)]) }
            try run("COMMIT")
        } catch { try? run("ROLLBACK"); throw error }
    }

    func delete(_ id: String) throws { try deleteClips([id]) }

    func deleteClips(_ ids: Set<String>) throws {
        lock.lock(); defer { lock.unlock() }
        try run("BEGIN IMMEDIATE")
        do {
            for id in ids { try removeClip(id) }
            try run("COMMIT")
        } catch { try? run("ROLLBACK"); throw error }
    }

    private func removeClip(_ id: String) throws {
        try run("DELETE FROM clips WHERE id=?", [.text(id)])
        try run("DELETE FROM share_send WHERE id=?", [.text(id)])
        try run("DELETE FROM pending WHERE id=?", [.text(id)])
        try run("DELETE FROM forward WHERE id=?", [.text(id)])
    }
    func pair(_ peer: Peer, address: String? = nil) throws {
        let sql = "INSERT OR REPLACE INTO peers VALUES(?,?)"
        let values: [Value] = [.text(peer.id), .bytes(try Codec.pack(peer))]
        guard let address else {
            try run(sql, values)
            return
        }
        lock.lock(); defer { lock.unlock() }
        try run("BEGIN IMMEDIATE")
        do {
            try run(sql, values)
            try setLANAddress(address, peer: peer)
            try run("COMMIT")
        } catch { try? run("ROLLBACK"); throw error }
    }
    func peers()throws->[Peer] {try query("SELECT card FROM effective_peers"){self.blob($0,0)}.map{try Codec.read(Peer.self,$0)}}
    func directPeers() throws -> [Peer] {
        try query("SELECT card FROM peers ORDER BY id"){self.blob($0,0)}.map{try Codec.read(Peer.self,$0)}
    }
    func directoryOwner() throws -> String {
        try query("SELECT owner FROM directory_settings"){self.string($0,0)}.first ?? ""
    }
    func chooseDirectory(_ owner: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard owner != (try directoryOwner()) else { return }
        try run("BEGIN IMMEDIATE")
        do {
            try run("DELETE FROM directory_settings")
            try run("DELETE FROM directory_members")
            if !owner.isEmpty {
                try run("INSERT INTO directory_settings SELECT 1,id FROM peers WHERE id=?",[.text(owner)])
                guard try directoryOwner() == owner else { throw RelayFailure.unauthorized }
            }
            try pruneDirectoryJobs()
            try run("COMMIT")
        } catch { try? run("ROLLBACK"); throw error }
    }
    func publishedDirectory(_ nonce: UUID, requester: String) throws -> MemberDirectory {
        let rows = try query("SELECT value,card FROM directory_revision CROSS JOIN peers WHERE EXISTS(SELECT 1 FROM peers WHERE id=?) ORDER BY id LIMIT 13",
                             [.text(requester)]) { (sqlite3_column_int64($0,0),self.blob($0,1)) }
        guard let revision = rows.first?.0, rows.count <= 12 else { throw RelayFailure.unavailable }
        return MemberDirectory(nonce: nonce, revision: revision, members: try rows.map { try Codec.read(Peer.self, $0.1) })
    }
    func applyDirectory(_ update: MemberDirectory, from owner: Peer, selfID: String) throws {
        let members = update.members
        guard update.revision >= 0, members.count <= 12, members.contains(where: { $0.id == selfID }),
              Set(members.map(\.id)).count == members.count else { throw RelayFailure.invalid }
        for peer in members { _ = try Peer.parse(peer.code()) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let digest = Codec.hash(try encoder.encode(members.sorted { $0.id < $1.id }))
        lock.lock(); defer { lock.unlock() }
        try run("BEGIN IMMEDIATE")
        do {
            guard try directoryOwner() == owner.id, try directPeers().contains(owner) else { throw RelayFailure.unauthorized }
            if let old = try query("SELECT revision,digest FROM directory_state WHERE owner=?", [.text(owner.id)], {
                (sqlite3_column_int64($0,0),self.string($0,1))
            }).first {
                guard update.revision > old.0 || update.revision == old.0 && digest == old.1 else { throw RelayFailure.unauthorized }
            }
            try run("INSERT OR REPLACE INTO directory_state VALUES(?,?,?)", [.text(owner.id),.text(String(update.revision)),.text(digest)])
            try run("DELETE FROM directory_members")
            for peer in members where peer.id != selfID && peer.id != owner.id {
                try run("INSERT INTO directory_members VALUES(?,?,unixepoch()+?)",
                        [.text(peer.id),.bytes(try Codec.pack(peer)),.text(String(Int(MemberDirectory.lease)))])
            }
            try pruneDirectoryJobs()
            try run("COMMIT")
        } catch { try? run("ROLLBACK"); throw error }
    }
    private func pruneDirectoryJobs() throws {
        try run("DELETE FROM pending WHERE peer NOT IN (SELECT id FROM effective_peers)")
        try run("DELETE FROM share_send WHERE peer NOT IN (SELECT id FROM effective_peers)")
        try run("DELETE FROM forward WHERE origin NOT IN (SELECT id FROM effective_peers) OR peer NOT IN (SELECT id FROM effective_peers)")
    }
    func unpair(_ peer:Peer)throws {
        lock.lock(); defer {lock.unlock()}
        try run("BEGIN IMMEDIATE")
        do {
            try run("DELETE FROM peers WHERE id=?",[.text(peer.id)])
            try run("DELETE FROM lan_addresses WHERE peer=?", [.text(peer.id)])
            if try directoryOwner() == peer.id {
                try run("DELETE FROM directory_settings")
                try run("DELETE FROM directory_members")
                try pruneDirectoryJobs()
            }
            try run("DELETE FROM pending WHERE peer=?",[.text(peer.id)])
            try run("DELETE FROM forward WHERE origin=? OR peer=?",[.text(peer.id),.text(peer.id)])
            try run("DELETE FROM share_send WHERE peer=?", [.text(peer.id)])
            try run("COMMIT")
        }
        catch {try? run("ROLLBACK");throw error}
    }
    func lanAddress(_ peer: Peer) throws -> String {
        try query("SELECT address FROM lan_addresses WHERE peer=?", [.text(peer.id)]) { self.string($0, 0) }.first ?? ""
    }
    func setLANAddress(_ value: String, peer: Peer) throws {
        guard try peers().contains(peer) else { throw RelayFailure.unauthorized }
        try run("INSERT OR REPLACE INTO lan_addresses VALUES(?,?)", [.text(peer.id), .text(value)])
    }
    func queue(_ id:String,peer:Peer,wire:Data)throws {
        try run("INSERT OR IGNORE INTO pending SELECT ?,?,? WHERE EXISTS(SELECT 1 FROM effective_peers WHERE id=?) AND (SELECT COALESCE(SUM(length(wire)),0) FROM pending) + ? <= 100000000",[.text(id),.text(peer.id),.bytes(wire),.text(peer.id),.text(String(wire.count))])
        guard try pending(id,peer:peer) != nil else {throw RelayFailure.storage}
    }
    func pending(_ id:String,peer:Peer)throws->Data? {try query("SELECT wire FROM pending WHERE id=? AND peer=?",[.text(id),.text(peer.id)]){self.blob($0,0)}.first}
    func pendingIDs(_ peer:Peer)throws->[String] {try query("SELECT id FROM pending WHERE peer=? ORDER BY rowid LIMIT 30",[.text(peer.id)]){self.string($0,0)}}
    func delivered(_ id: String, peer: Peer) throws {
        try run("UPDATE clips SET shared=1 WHERE id=?", [.text(id)])
        try run("DELETE FROM pending WHERE id=? AND peer=?", [.text(id), .text(peer.id)])
    }
    func stageForward(_ id: String, origin: String, peer: String, wire: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        let key: [Value] = [.text(id), .text(origin), .text(peer)]
        try run("""
            INSERT OR IGNORE INTO forward SELECT ?,?,?,?
            WHERE (SELECT COUNT(*) FROM effective_peers WHERE id IN (?,?))=2
            AND (SELECT COALESCE(SUM(length(wire)),0) FROM forward)+? <= 60000000
            """, key + [.bytes(wire), .text(origin), .text(peer), .text(String(wire.count))])
        guard try query("SELECT wire FROM forward WHERE id=? AND origin=? AND peer=?", key, {
            self.blob($0, 0)
        }).first == wire else { throw RelayFailure.storage }
    }
    func forwards(to peer: Peer) throws -> [(id: String, origin: String)] {
        try query("SELECT id,origin FROM forward WHERE peer=? ORDER BY rowid LIMIT 30", [.text(peer.id)]) {
            (self.string($0, 0), self.string($0, 1))
        }
    }
    func forward(_ id: String, origin: String, to peer: Peer) throws -> Data? {
        try query("SELECT wire FROM forward WHERE id=? AND origin=? AND peer=?", [.text(id), .text(origin), .text(peer.id)]) {
            self.blob($0, 0)
        }.first
    }
    func forwarded(_ id: String, origin: String, to peer: Peer) throws {
        try run("DELETE FROM forward WHERE id=? AND origin=? AND peer=?", [.text(id), .text(origin), .text(peer.id)])
    }
}
