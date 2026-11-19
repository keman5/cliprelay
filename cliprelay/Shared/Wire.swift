import Foundation
import CryptoKit
import Security
import UniformTypeIdentifiers

enum RelayFailure: LocalizedError {
    case invalid, tooLarge, unauthorized, unavailable, storage
    var errorDescription: String? {
        switch self {
        case .invalid: "Invalid ClipRelay data"
        case .tooLarge: "The item exceeds 10 MB"
        case .unauthorized: "Device not paired or credential rejected"
        case .unavailable: "Device or relay unavailable"
        case .storage: "Could not securely store this item"
        }
    }
}

enum Codec {
    static func pack<T: Encodable>(_ value: T) throws -> Data {
        let enc = PropertyListEncoder()
        enc.outputFormat = .binary
        return try enc.encode(value)
    }
    static func read<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        try PropertyListDecoder().decode(type, from: data)
    }
    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct Clip: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    var name: String
    var type: String
    var bytes: Data
    var plain: String?
    var isFile: Bool?
    static let limit = 10_000_000
    func validate() throws {
        guard !bytes.isEmpty, name.utf8.count <= 512, !type.isEmpty, type.utf8.count < 160 else { throw RelayFailure.invalid }
        guard bytes.count + (plain?.utf8.count ?? 0) <= Self.limit else { throw RelayFailure.tooLarge }
    }
    static func text(_ value: String) -> Clip {
        Clip(name: String(value.prefix(80)), type: UTType.utf8PlainText.identifier, bytes: Data(value.utf8))
    }
    var text: String? {
        guard isFile != true else { return nil }
        return UTType(type)?.conforms(to: .plainText) == true ? String(data: bytes, encoding: .utf8) : plain
    }
    var kind: String {
        guard let uti = UTType(type) else { return "File" }
        if uti.conforms(to: .image) { return "Image" }
        if isFile == true { return "File" }
        if uti.conforms(to: .rtf) || uti.conforms(to: .html) { return "Rich text" }
        return uti.conforms(to: .plainText) ? "Text" : "File"
    }
}

struct Peer: Codable, Hashable, Identifiable {
    let name: String
    let key: Data
    let box: String
    var id: String { Codec.hash(key) }
    var service: String { String(id.prefix(28)) }
    var fingerprint: String {
        let digest = Array(Codec.hash(key + Data(box.utf8)))
        return stride(from: 0, to: digest.count, by: 8)
            .map { String(digest[$0..<($0 + 8)]) }.joined(separator: " ")
    }
    func code() throws -> String { "CLIP1." + (try Codec.pack(self)).base64EncodedString() }
    static func parse(_ code: String) throws -> Peer {
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.hasPrefix("CLIP1."), code.count < 2048, let data = Data(base64Encoded: String(code.dropFirst(6))) else { throw RelayFailure.invalid }
        let peer = try Codec.read(Peer.self, data)
        guard peer.key.count == 32, !peer.name.isEmpty, peer.name.utf8.count <= 150,
              peer.box.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { throw RelayFailure.invalid }
        return peer
    }
}

struct PairingCard: Codable {
    let device: String
    let challenge: UUID
    let expires: Date
    let addresses: [String]?
    static let duration: TimeInterval = 120
    init(_ peer: Peer, now: Date = .now, addresses: [String] = []) throws {
        device = try peer.code()
        challenge = UUID()
        expires = now.addingTimeInterval(Self.duration)
        self.addresses = addresses.isEmpty ? nil : Array(addresses.prefix(3))
    }
    func code() throws -> String { try PairingCode.encode(self, prefix: "CLIP2.") }
    static func parse(_ code: String, now: Date = .now) throws -> Self {
        let card = try PairingCode.decode(Self.self, code, prefix: "CLIP2.")
        try card.validate(now: now)
        return card
    }
    func validate(now: Date = .now) throws {
        guard expires > now, expires <= now.addingTimeInterval(Self.duration + 30) else {
            throw RelayFailure.invalid
        }
    }
}

enum PairingCode {
    static func encode<T: Encodable>(_ value: T, prefix: String) throws -> String {
        prefix + (try Codec.pack(value)).base64EncodedString()
    }
    static func decode<T: Decodable>(_ type: T.Type, _ code: String, prefix: String) throws -> T {
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.hasPrefix(prefix), code.utf8.count < 4096,
              let bytes = Data(base64Encoded: String(code.dropFirst(prefix.count))) else { throw RelayFailure.invalid }
        return try Codec.read(type, bytes)
    }
}

struct MemberDirectory: Codable {
    let nonce: UUID
    let revision: Int64
    let members: [Peer]
    static let lease: TimeInterval = 120
}

struct PairingRequest: Codable {
    private struct Proof: Codable, Equatable {
        let invitation: UUID
        let request: UUID
        let owner: String
        let requester: String
    }
    let device: String
    private let request: UUID
    private let wire: Data
    init(from me: Identity, card: PairingCard) throws {
        let owner = try Peer.parse(card.device)
        guard owner.id != me.peer.id else { throw RelayFailure.invalid }
        request = UUID()
        device = try me.peer.code()
        let proof = Proof(invitation: card.challenge, request: request, owner: card.device, requester: device)
        wire = try Envelope.seal(Codec.pack(proof), from: me, to: owner, purpose: "pair-request")
    }
    func code() throws -> String { try PairingCode.encode(self, prefix: "CLIPREQ.") }
    static func parse(_ code: String) throws -> Self { try PairingCode.decode(Self.self, code, prefix: "CLIPREQ.") }
    func verify(at owner: Identity, card: PairingCard, now: Date = .now) throws -> Peer {
        try card.validate(now: now)
        let peer = try Peer.parse(device)
        guard peer.id != owner.peer.id, try Peer.parse(card.device) == owner.peer else { throw RelayFailure.invalid }
        let (data, _) = try Codec.read(Envelope.self, wire).open(owner, peers: [peer], purpose: "pair-request")
        let expected = Proof(invitation: card.challenge, request: request, owner: card.device, requester: device)
        guard try Codec.read(Proof.self, data) == expected else { throw RelayFailure.unauthorized }
        return peer
    }
    func approve(at owner: Identity, card: PairingCard) throws -> String {
        let peer = try verify(at: owner, card: card)
        let proof = Proof(invitation: card.challenge, request: request, owner: card.device, requester: device)
        let receipt = try Envelope.seal(Codec.pack(proof), from: owner, to: peer, purpose: "pair-approved")
        return try PairingCode.encode(receipt, prefix: "CLIPOK.")
    }
    func accept(_ receipt: String, at me: Identity, card: PairingCard) throws -> Peer {
        try card.validate()
        let owner = try Peer.parse(card.device)
        let wire = try PairingCode.decode(Data.self, receipt, prefix: "CLIPOK.")
        let (data, _) = try Codec.read(Envelope.self, wire).open(me, peers: [owner], purpose: "pair-approved")
        let expected = Proof(invitation: card.challenge, request: request, owner: card.device, requester: device)
        guard try Codec.read(Proof.self, data) == expected else { throw RelayFailure.unauthorized }
        return owner
    }
}

struct Identity {
    let key: Curve25519.KeyAgreement.PrivateKey
    let reader: String
    let peer: Peer
    init(secret: Data, name: String) throws {
        key = try .init(rawRepresentation: secret)
        reader = Codec.hash(Data("ClipRelay mailbox v1".utf8) + secret)
        peer = Peer(name: name, key: key.publicKey.rawRepresentation, box: Codec.hash(Data(reader.utf8)))
    }
    static func load(name: String, account: String = "device", createIfMissing: Bool = true) throws -> Identity {
        var query: [String: Any] = [kSecClass as String:kSecClassGenericPassword, kSecAttrService as String:"cc.macseek.cliprelay.v1", kSecAttrAccount as String:account]
        #if os(iOS)
        let legacy = query
        query[kSecAttrAccessGroup as String] = "group.cc.macseek.cliprelay"
        #endif
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query.merging([kSecReturnData as String:true]) { $1 } as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data { return try Identity(secret:data,name:name) }
        guard status == errSecItemNotFound, createIfMissing else { throw RelayFailure.storage }
        var secret = Curve25519.KeyAgreement.PrivateKey().rawRepresentation
        #if os(iOS)
        let previous = SecItemCopyMatching(legacy.merging([kSecReturnData as String:true]) { $1 } as CFDictionary, &result)
        if previous == errSecSuccess, let data = result as? Data { secret = data }
        else if previous != errSecItemNotFound { throw RelayFailure.storage }
        #endif
        var item = query
        item[kSecValueData as String] = secret
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(item as CFDictionary,nil) == errSecSuccess else { throw RelayFailure.storage }
        return try Identity(secret:secret,name:name)
    }
}

struct Envelope: Codable {
    let sender: String
    let recipient: String
    let enc: Data
    let ciphertext: Data
    static let maxWire = 10_080_000
    static func context(_ sender: String, _ recipient: String, _ purpose: String) -> Data {
        Data("ClipRelay/1/\(purpose)/\(sender)/\(recipient)".utf8)
    }
    static func seal(_ data: Data, from me: Identity, to peer: Peer, purpose: String = "clip") throws -> Data {
        let info = context(me.peer.id,peer.id,purpose)
        var sender = try HPKE.Sender(recipientKey: Curve25519.KeyAgreement.PublicKey(rawRepresentation:peer.key), ciphersuite:.Curve25519_SHA256_ChachaPoly, info:info, authenticatedBy:me.key)
        return try Codec.pack(Self(sender:me.peer.id,recipient:peer.id,enc:sender.encapsulatedKey,ciphertext:try sender.seal(data)))
    }
    func open(_ me: Identity, peers: [Peer], purpose: String = "clip") throws -> (Data, Peer) {
        guard recipient == me.peer.id, let peer = peers.first(where:{$0.id == sender}) else { throw RelayFailure.unauthorized }
        var receiver = try HPKE.Recipient(privateKey:me.key,ciphersuite:.Curve25519_SHA256_ChachaPoly,info:Self.context(sender,recipient,purpose),encapsulatedKey:enc,authenticatedBy:Curve25519.KeyAgreement.PublicKey(rawRepresentation:peer.key))
        return (try receiver.open(ciphertext),peer)
    }
}
