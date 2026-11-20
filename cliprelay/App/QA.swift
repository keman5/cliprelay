#if DEBUG
import Foundation
import Network
import CryptoKit
#if os(macOS)
import AppKit
#endif

enum QA {
    static var active:Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--relay-qa") || arguments.contains("--view-qa")
    }
    static func run() async {
        #if os(macOS)
        guard let path=ProcessInfo.processInfo.environment["CLIPRELAY_QA_DIR"] else{return}
        let dir=URL(fileURLWithPath:path)
        let sender=true
        #else
        let dir=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("relay-qa")
        let sender=false
        #endif
        func write(_ name:String,_ text:String)throws {try Data(text.utf8).write(to:dir.appendingPathComponent(name),options:.atomic)}
        func wait(_ condition:()throws->Bool) async throws {
            for _ in 0..<480 {if try condition(){return};try await Task.sleep(nanoseconds:250_000_000)}
            throw RelayFailure.unavailable
        }
        var stage = "archive and history"
        do {
            try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
            let me=try Identity(secret:Curve25519.KeyAgreement.PrivateKey().rawRepresentation,name:sender ? "QA Mac":"QA iPhone")
            try ClipArchive.selfCheck(in: dir.appendingPathComponent("archive-tests"))
            let lib=try Library(dir.appendingPathComponent("vault"))
            try testPages(in: dir.appendingPathComponent("page-tests"))
            let backup = dir.appendingPathComponent("phone.clipnote")
            let backupPass = "fixture " + "archive"
            #if os(iOS)
            let source = try Library(dir.appendingPathComponent("exports"))
            let styled = Clip(name: "Styled", type: "public.rtf", bytes: Data(#"{\rtf1 Sample}"#.utf8), plain: "Sample")
            try source.save(styled, source: "iPhone")
            try source.pin(styled.id.uuidString)
            try source.save(Clip(name: "sample.bin", type: "public.data", bytes: Data([1, 2, 3])), source: "iPhone")
            try ClipArchive.export(source, password: backupPass, to: backup)
            #endif
            stage = "local connection"
            let localOnly = ProcessInfo.processInfo.environment["CLIPRELAY_QA_LOCAL_ONLY"] == "1"
            let mode: Exchange.Mode = localOnly ? (sender ? .hub : .client) : .legacy
            let ex = Exchange(lib, me, mode: mode)
            try ex.start(port:sender ? 48231:48232)
            try write("card",me.peer.code())
            try await wait {FileManager.default.fileExists(atPath:dir.appendingPathComponent("peer").path)}
            let peer=try Peer.parse(String(contentsOf:dir.appendingPathComponent("peer"),encoding:.utf8))
            try lib.pair(peer)
            try write("ready","paired")
            try await wait {FileManager.default.fileExists(atPath:dir.appendingPathComponent("go").path)}
            #if os(macOS)
            let contents = try ClipArchive.read(backup, password: backupPass)
            let imported = try Library(dir.appendingPathComponent("imports"))
            guard try imported.importArchive(contents.records.map { ($0.clip, $0.source, $0.pinned) }) == 2,
                  let pinned = try imported.page(kind: "Pinned").first,
                  try imported.clip(pinned.id).plain == "Sample",
                  let file = try imported.page(kind: "File").first,
                  try imported.clip(file.id).bytes == Data([1, 2, 3]) else { throw RelayFailure.invalid }
            #endif
            stage = "LAN text"
            let text=sender ? "Mac to simulator via LAN" : "Simulator to Mac via LAN"
            let opposite=sender ? "Simulator to Mac via LAN":"Mac to simulator via LAN"
            for _ in 0..<12 { if ex.discovered().contains(peer.service) { break }; try await Task.sleep(nanoseconds:250_000_000) }
            let bonjour = ex.discovered().contains(peer.service)
            if !bonjour {
                try lib.setLANAddress(sender ? "127.0.0.1:48232" : "127.0.0.1:48231", peer: peer)
            }
            try write("discovery",bonjour ? "Bonjour" : "simulator loopback")
            if localOnly {
                stage = "Mac hub history"
                let newest = "History before the client opened"
                let privateClip = Clip.text("Burn after copy")
                let fixtures = lanFixtures(origin: "Mac")
                let file = Data("Copied file contents".utf8)
                let image = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgiPr/HwAEEAJZs1E1mQAAAABJRU5ErkJggg==")!
                if sender {
                    #if os(macOS)
                    try await recordClipboardFixtures(file: file, image: image, from: ex, in: dir)
                    #endif
                    let pinned = Clip.text(newest)
                    try lib.save(pinned, source: "QA")
                    try lib.pin(pinned.id.uuidString)
                    try lib.save(privateClip, source: "QA")
                    try lib.setBurn(privateClip.id.uuidString, true)
                    for clip in fixtures { try lib.save(clip, source: "QA") }
                    for index in 0..<32 { try lib.save(.text("Old history \(index)"), source: "QA") }
                    guard try lib.usage().jobs == 0 else { throw RelayFailure.invalid }
                    try write("hub-history", pinned.id.uuidString)
                    try await wait { FileManager.default.fileExists(atPath: dir.appendingPathComponent("verified-first").path) }
                    try lib.delete(pinned.id.uuidString)
                    try lib.save(.text("New history"), source: "QA")
                    try write("hub-updated", "ready")
                    try await wait { FileManager.default.fileExists(atPath: dir.appendingPathComponent("verified-update").path) }
                    guard try lib.usage().jobs == 0, try lib.recordCount(kind: "") == 39 else { throw RelayFailure.invalid }
                } else {
                    let local = Clip.text("Local phone history")
                    try lib.save(local, source: "QA")
                    try await wait { FileManager.default.fileExists(atPath: dir.appendingPathComponent("hub-history").path) }
                    let pinnedID = try String(contentsOf: dir.appendingPathComponent("hub-history"), encoding: .utf8)
                    try await ex.pullHistory(from: peer)
                    let rows = try lib.page(pinnedFirst: true) + lib.page(offset: 30, pinnedFirst: true)
                    guard rows.count == 39, rows.first?.id == pinnedID, rows.first?.fromHub == true,
                          !rows.contains(where: { $0.name == privateClip.name }),
                          let copied = rows.first(where: { $0.name == "Copied.txt" }),
                          let screenshot = rows.first(where: { $0.name == "public.png" }),
                          try lib.clip(copied.id).bytes == file, try lib.clip(screenshot.id).bytes == image,
                          let binary = rows.first(where: { $0.name == "Mac.bin" }),
                          try lib.clip(binary.id).bytes == fixtures.last?.bytes else { throw RelayFailure.invalid }
                    try write("verified-first", "ready")
                    try await wait { FileManager.default.fileExists(atPath: dir.appendingPathComponent("hub-updated").path) }
                    try await ex.pullHistory(from: peer)
                    try await ex.pullHistory(from: peer)
                    guard try lib.recordCount(kind: "") == 39, try lib.page(pinnedFirst: true).first?.name == "New history",
                          (try? lib.clip(pinnedID)) == nil, try lib.clip(local.id.uuidString).text == local.text,
                          try lib.usage().jobs == 0 else { throw RelayFailure.invalid }
                    try write("verified-update", "ready")
                }
                try testIntegrity(from: me, to: peer)
                try write("result", "PASS Mac history pull, saved attachments, pinning, deletions, retries, integrity and archive")
                return
            }
            try ex.queue(.text(text))
            guard try await ex.flush(to: peer, cloud: nil) == ["LAN"] else { throw RelayFailure.invalid }
            try await wait {
                guard let row = try lib.page().first(where: { $0.name == opposite && $0.source == peer.name }) else { return false }
                return try lib.clip(row.id).text == opposite
            }
            if ProcessInfo.processInfo.environment["CLIPRELAY_QA_DUPLEX_ONLY"] == "1" {
                try testIntegrity(from: me, to: peer)
                try write("result", "PASS direct duplex, integrity, pagination and archive")
                return
            }
            stage = "cloud configuration"
            let token=try String(contentsOf:dir.appendingPathComponent("credential"),encoding:.utf8)
            let cloud=try Cloud("https://cliprelay-test.macseek.cc",token)
            let attachment=Clip(name:sender ? "mac.bin":"ios.bin",type:"public.data",bytes:Data(repeating:sender ? 65:66,count:Clip.limit))
            stage = "cloud upload and delivery"
            try ex.queue(attachment)
            let disconnected=NWEndpoint.hostPort(host:"127.0.0.1",port:1)
            guard try await ex.flush(to:peer,cloud:cloud,address:disconnected)==["Cloud"] else {throw RelayFailure.invalid}
            for _ in 0..<30 {
                if try await ex.pull(cloud)>0 {break}
                try await Task.sleep(nanoseconds:500_000_000)
            }
            let expected=sender ? "ios.bin":"mac.bin"
            guard let row=try lib.page().first(where:{$0.name==expected && $0.source==peer.name}),
                  try lib.clip(row.id).bytes==Data(repeating:sender ? 66:65,count:Clip.limit) else {throw RelayFailure.invalid}
            guard try await cloud.list(me,nil).ids.isEmpty else {throw RelayFailure.invalid}
            let poison = "00000000-0000-0000-0000-000000000000"
            stage = "mailbox isolation"
            let afterPoison = Clip.text("Valid item after malformed cloud entry")
            try await cloud.put(Data([0]), me.peer.box, poison)
            let valid = try Envelope.seal(Codec.pack(afterPoison), from: me, to: me.peer)
            try lib.pair(me.peer)
            try await cloud.put(valid, me.peer.box, afterPoison.id.uuidString)
            guard try await ex.pull(cloud) == 1,
                  try lib.clip(afterPoison.id.uuidString).bytes == afterPoison.bytes else { throw RelayFailure.invalid }
            try lib.unpair(me.peer)
            try await cloud.remove(me, poison)
            stage = "integrity"
            try testIntegrity(from: me, to: peer)
            #if os(macOS)
            stage = "three-node relay and pairing"
            try await testForwarding(in: dir.appendingPathComponent("forwarding"))
            #endif
            try write("result","PASS direct duplex, 10 MB cloud duplex, inbox cleanup, integrity, pagination and archive")
        } catch {try? write("result","FAIL "+stage+" · "+String(describing:error))}
    }
    #if os(macOS)
    @MainActor private static func recordClipboardFixtures(file: Data, image: Data, from exchange: Exchange, in dir: URL) async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let fileURL = dir.appendingPathComponent("Copied.txt")
        try file.write(to: fileURL)
        let item = NSPasteboardItem()
        item.setData(image, forType: .png)
        guard board.writeObjects([fileURL as NSURL, item]) else { throw RelayFailure.invalid }
        let model = Model()
        model.transfer = exchange
        try model.recordClipboardCopies(in: board, source: "QA")
    }
    #endif
    private static func testIntegrity(from identity: Identity, to peer: Peer) throws {
        let sample = try Envelope.seal(Codec.pack(Clip.text("check")), from: identity, to: identity.peer)
        let envelope = try Codec.read(Envelope.self, sample)
        let damaged = Envelope(sender: envelope.sender, recipient: envelope.recipient, enc: envelope.enc,
                               ciphertext: envelope.ciphertext + Data([0]))
        let oversized = Clip(name: "over", type: "public.data", bytes: Data(count: Clip.limit + 1))
        guard (try? envelope.open(identity, peers: [identity.peer])) != nil,
              (try? envelope.open(identity, peers: [peer])) == nil,
              (try? damaged.open(identity, peers: [identity.peer])) == nil,
              (try? oversized.validate()) == nil else { throw RelayFailure.invalid }
    }
    private static func lanFixtures(origin: String) -> [Clip] {
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aGZ0AAAAASUVORK5CYII=")!
        return [
            Clip(name: "\(origin).rtf", type: "public.rtf", bytes: Data(#"{\rtf1 ClipRelay}"#.utf8), plain: "ClipRelay"),
            Clip(name: "\(origin).png", type: "public.png", bytes: png),
            Clip(name: "\(origin).bin", type: "public.data", bytes: Data(repeating: origin == "Mac" ? 65 : 66, count: Clip.limit)),
        ]
    }
    private static func testPages(in dir: URL) throws {
        let library = try Library(dir)
        let pinned = Clip.text("keep")
        try library.save(pinned, source: "QA")
        try library.pin(pinned.id.uuidString)
        for index in 0..<30 { try library.save(.text("fixture \(index)"), source: "QA") }
        let stats = try library.usage()
        guard try library.page().count == 30, try library.page(offset: 30).first?.id == pinned.id.uuidString,
              try library.page(kind: "Pinned", search: "keep").count == 1,
              stats.entries == 31, stats.historyBytes > 0, stats.jobs == 0 else { throw RelayFailure.invalid }
        var conflict = pinned
        conflict.bytes = Data("different".utf8)
        guard (try? library.save(conflict, source: "QA")) == nil,
              try library.clip(pinned.id.uuidString).bytes == pinned.bytes else { throw RelayFailure.invalid }
        let extensionConnection = try Library(dir)
        try extensionConnection.delete(pinned.id.uuidString)
        guard try library.page(kind: "Pinned", search: "keep").isEmpty else { throw RelayFailure.invalid }
    }
    #if os(macOS)
    static func testForwarding(in dir: URL) async throws {
        func device(_ name: String, forwarding: Bool = false) throws -> Exchange {
            let key = Curve25519.KeyAgreement.PrivateKey().rawRepresentation
            return Exchange(try Library(dir.appendingPathComponent(name)), try Identity(secret: key, name: name),
                            forwardingAllowed: { forwarding }, directoryAllowed: { forwarding })
        }
        let sender = try device("Sender")
        let destination = try device("Destination")
        let hub = try device("Hub", forwarding: true)
        let disabled = try device("Disabled")
        let now = Date.now
        let invitation = try PairingCard(sender.me.peer, now: now)
        let card = try invitation.code()
        let imported = try PairingCard.parse(card, now: now)
        let request = try PairingRequest(from: destination.me, card: imported)
        let verified = try PairingRequest.parse(request.code())
        let receipt = try verified.approve(at: sender.me, card: invitation)
        let alternate = try PairingRequest(from: destination.me, card: imported)
        guard try verified.verify(at: sender.me, card: invitation) == destination.me.peer,
              try request.accept(receipt, at: destination.me, card: imported) == sender.me.peer,
              (try? alternate.accept(receipt, at: destination.me, card: imported)) == nil,
              (try? verified.verify(at: sender.me, card: PairingCard(sender.me.peer))) == nil,
              (try? PairingCard.parse(card, now: now.addingTimeInterval(121))) == nil else { throw RelayFailure.invalid }
        try hub.library.pair(sender.me.peer)
        try hub.library.pair(destination.me.peer)
        try disabled.library.pair(sender.me.peer)
        try disabled.library.pair(destination.me.peer)
        try destination.library.pair(sender.me.peer)
        try destination.library.pair(hub.me.peer)
        try hub.start(port: 48233)
        try destination.start(port: 48234)
        try disabled.start(port: 48235)
        try await Task.sleep(nanoseconds: 350_000_000)
        let lanCard = try PairingCard(hub.me.peer, addresses: ["127.0.0.1:48233"])
        hub.offerPairing(lanCard)
        let lanAddress = NWEndpoint.hostPort(host: "127.0.0.1", port: 48233)
        let offered = try await disabled.pairingMessage("invite", service: hub.me.peer.service, at: lanAddress)
        print("QA received invitation")
        let lanInvite = try PairingCard.parse(offered)
        let pin = lanCard.shortCode
        let wrongPin = pin == "000000" ? "000001" : "000000"
        let found = try await sender.findPairing(pin, address: "127.0.0.1:48233")
        guard PairingCard.isShortCode(pin), found.challenge == lanInvite.challenge,
              (try? await sender.findPairing(wrongPin, address: "127.0.0.1:48233")) == nil,
              !PairingCard.isShortCode("12345"), !PairingCard.isShortCode("１２３４５６") else {
            throw RelayFailure.invalid
        }
        let lanRequest = try PairingRequest(from: disabled.me, card: lanInvite)
        let lanCode = try lanRequest.code()
        // The sender has no browser, as on a network that blocks Bonjour.
        let pending = try await sender.sendPairingRequest(lanCode, card: lanInvite)
        guard imported.addresses == nil, pending.code == "pending", pending.address == "127.0.0.1:48233",
              hub.pendingPairing() == disabled.me.peer,
              try !hub.library.peers().contains(disabled.me.peer) else { throw RelayFailure.invalid }
        let copiedApproval = try hub.approvePairing(disabled.me.peer, requestCode: lanCode)
        print("QA approved request")
        let lanReceipt = try await sender.sendPairingRequest(lanCode, card: lanInvite)
        let pairedHub = try lanRequest.accept(lanReceipt.code, at: disabled.me, card: lanInvite)
        try disabled.library.pair(pairedHub, address: lanReceipt.address)
        guard lanReceipt.code == copiedApproval,
              pairedHub == hub.me.peer,
              try disabled.library.lanAddress(pairedHub) == "127.0.0.1:48233",
              try hub.library.peers().contains(disabled.me.peer) else { throw RelayFailure.invalid }
        print("QA verified receipt")
        let pullClient = try device("Pull client")
        try pullClient.library.pair(hub.me.peer, address: "127.0.0.1:48233")
        guard (try? await pullClient.pullLAN(from: hub.me.peer)) == nil else { throw RelayFailure.invalid }
        try hub.library.pair(pullClient.me.peer)
        let outgoing = Clip.text("Queued clipboard item")
        try hub.library.save(outgoing, source: "QA", sendToPeers: true)
        let localOnly = Clip.text("Local clipboard history")
        try hub.library.save(localOnly, source: "QA")
        let pulled = try await pullClient.pullLAN(from: hub.me.peer)
        let remaining = try await pullClient.pullLAN(from: hub.me.peer)
        guard pulled == 1, remaining == 0, try pullClient.library.page().map(\.id) == [outgoing.id.uuidString],
              try hub.library.pendingIDs(pullClient.me.peer).isEmpty,
              try hub.library.sharedSends(pullClient.me.peer).isEmpty else { throw RelayFailure.invalid }
        try hub.library.unpair(pullClient.me.peer)
        try hub.library.delete(outgoing.id.uuidString)
        try hub.library.delete(localOnly.id.uuidString)
        try hub.library.unpair(disabled.me.peer)
        let manualCard = try PairingCard(hub.me.peer)
        hub.offerPairing(manualCard)
        let manualRequest = try PairingRequest(from: disabled.me, card: manualCard)
        let manualCode = try manualRequest.code()
        let manualReceipt = try hub.approvePairing(disabled.me.peer, requestCode: manualCode)
        guard try manualRequest.accept(manualReceipt, at: disabled.me, card: manualCard) == hub.me.peer,
              try hub.library.peers().contains(disabled.me.peer) else { throw RelayFailure.invalid }
        hub.offerPairing(nil)
        try hub.library.unpair(disabled.me.peer)
        let clip = Clip(name: "10 MB across hub.bin", type: "public.data", bytes: Data(repeating: 73, count: Clip.limit))
        let id = clip.id.uuidString
        let wire = try Envelope.seal(Codec.pack(clip), from: sender.me, to: destination.me.peer)
        let denied = await (try? sender.sendRelay(wire, id: id, via: disabled.me.peer, at: .hostPort(host: "127.0.0.1", port: 48235)))
        guard denied == nil, try disabled.library.forwards(to: destination.me.peer).isEmpty else { throw RelayFailure.invalid }
        try await sender.sendRelay(wire, id: id, via: hub.me.peer, at: .hostPort(host: "127.0.0.1", port: 48233))
        print("QA accepted forwarding job")
        let persisted = try Library(hub.library.root)
        guard try persisted.forwards(to: destination.me.peer).first?.id == id, try persisted.page().isEmpty,
              try destination.library.page().isEmpty else { throw RelayFailure.invalid }
        guard try await hub.flushForwarded(to: destination.me.peer, cloud: nil, address: .hostPort(host: "127.0.0.1", port: 48234)) == ["LAN"],
              try destination.library.clip(id).bytes == clip.bytes,
              try persisted.forwards(to: destination.me.peer).isEmpty else { throw RelayFailure.invalid }
        try sender.library.pair(hub.me.peer)
        print("QA delivered through hub")
        try destination.library.unpair(sender.me.peer)
        for client in [sender, destination] {
            try client.library.chooseDirectory(hub.me.peer.id)
            try await client.refreshDirectory(at: lanAddress)
        }
        guard try sender.library.peers().contains(destination.me.peer),
              try destination.library.peers().contains(sender.me.peer) else { throw RelayFailure.invalid }
        let groupClip = Clip.text("Directory-introduced peer delivery")
        print("QA synchronized directory")
        try sender.queue(groupClip)
        guard try await sender.flush(to: destination.me.peer, cloud: nil, address: .hostPort(host: "127.0.0.1", port: 48234)) == ["LAN"],
              try destination.library.clip(groupClip.id.uuidString).bytes == groupClip.bytes else { throw RelayFailure.invalid }
        let old = try hub.library.publishedDirectory(UUID(), requester: sender.me.peer.id)
        try hub.library.unpair(destination.me.peer)
        try await sender.refreshDirectory(at: lanAddress)
        guard try !sender.library.peers().contains(destination.me.peer),
              (try? sender.library.applyDirectory(old, from: hub.me.peer, selfID: sender.me.peer.id)) == nil,
              (try? await destination.refreshDirectory(at: lanAddress)) == nil else { throw RelayFailure.invalid }
    }
    #endif
}
#endif
