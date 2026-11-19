import Foundation
import Network
import CryptoKit
import Darwin
import dnssd

final class Exchange {
    let library: Library
    let me: Identity
    private var listener: NWListener?
    private var advertisement: NetService?
    private var browser: NWBrowser?
    private let io = DispatchQueue(label:"cc.macseek.cliprelay.transport")
    private var connections = 0
    private var endpoints: [String:NWEndpoint] = [:]
    private var nearby: [String:String] = [:]
    private var phoneInvitations: Set<String> = []
    private var localNetworkDenied = false
    private var invitation: PairingCard?
    private var pairingRequest: (code: String, request: PairingRequest, peer: Peer, receipt: String?)?
    private var pairingAttempts = 0
    private static let pairingFlag: UInt32 = 1 << 31
    private let forwardingAllowed: () -> Bool
    private let directoryAllowed: () -> Bool
    private static let maxLANFrame = Envelope.maxWire + 1024
    private struct Forward: Codable {
        let id: UUID
        let wire: Data
    }
    var didReceive: (() -> Void)?
    init(_ library: Library, _ me: Identity, forwardingAllowed: @escaping () -> Bool = {
        #if os(macOS)
        UserDefaults.standard.bool(forKey: "relay.lanForwarding")
        #else
        false
        #endif
    }, directoryAllowed: @escaping () -> Bool = {
        #if os(macOS)
        UserDefaults.standard.bool(forKey: "relay.publishDirectory")
        #else
        false
        #endif
    }) {
        self.library = library
        self.me = me
        self.forwardingAllowed = forwardingAllowed
        self.directoryAllowed = directoryAllowed
    }
    func start(port: UInt16=0) throws {
        let preferred = UInt16(me.peer.id.prefix(4), radix: 16) ?? 0
        let port = NWEndpoint.Port(rawValue: port == 0 ? (49_152 + preferred % 16_383) : port)!
        let listener = try NWListener(using:.tcp,on:port)
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, case .ready = state, let port = listener?.port else { return }
            let inviting = self.invitation != nil
            DispatchQueue.main.async {
                #if os(macOS)
                guard UserDefaults.standard.object(forKey: "mac.lanDiscovery") as? Bool ?? true else { return }
                #endif
                self.publishLAN(port.rawValue, inviting: inviting)
            }
        }
        listener.newConnectionHandler = { [weak self] c in
            guard let self, self.connections < 6 else {c.cancel();return}
            self.connections += 1
            c.stateUpdateHandler = { state in if case .cancelled = state {self.connections -= 1} }
            c.start(queue:self.io)
            self.io.asyncAfter(deadline:.now()+15){c.cancel()}
            self.read(c) { data, pairing in
                guard let data else {c.cancel();return}
                do {
                    let ack = try pairing ? self.receivePairing(data) : self.receiveLAN(data)
                    self.write(ack,on:c,pairing:pairing){_ in c.cancel()}
                } catch {c.cancel()}
            }
        }
        listener.start(queue:io); self.listener=listener
        #if os(macOS)
        if UserDefaults.standard.object(forKey: "mac.lanDiscovery") as? Bool ?? true { startBrowsing() }
        #else
        startBrowsing()
        #endif
    }

    private func publishLAN(_ port: UInt16, inviting: Bool) {
        guard advertisement == nil else { return }
        let service = NetService(domain: "local.", type: "_cliprelay._tcp.", name: me.peer.service, port: Int32(port))
        advertisement = service
        setPairingTXT(inviting)
        service.publish()
    }

    #if os(macOS)
    func setLANDiscovery(_ enabled: Bool) {
        if enabled {
            startBrowsing()
            if let listeningPort { publishLAN(listeningPort, inviting: io.sync { invitation != nil }) }
        } else {
            advertisement?.stop()
            advertisement = nil
            io.sync {
                browser?.cancel()
                browser = nil
                endpoints.removeAll()
                nearby.removeAll()
                phoneInvitations.removeAll()
            }
        }
    }
    #endif

    func startBrowsing() {
        io.sync {
            guard browser == nil else { return }
            let browser=NWBrowser(for:.bonjourWithTXTRecord(type:"_cliprelay._tcp",domain:nil),using:.tcp)
            browser.stateUpdateHandler = { [weak self] state in
                switch state {
                case .waiting(.dns(let code)), .failed(.dns(let code)):
                    self?.localNetworkDenied = code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied)
                case .ready:
                    self?.localNetworkDenied = false
                default: break
                }
            }
            browser.browseResultsChangedHandler = { [weak self, weak browser] results,_ in
                guard let self, let browser, self.browser === browser else { return }
                var next:[String:NWEndpoint]=[:]
                var nearby: [String:String] = [:]
                var phones: Set<String> = []
                for result in results {
                    if case .service(let name,_,_,_) = result.endpoint {
                        next[name] = result.endpoint
                        if name != self.me.peer.service, case .bonjour(let txt) = result.metadata,
                           let label = txt["pair"], !label.isEmpty {
                            nearby[name] = label
                            if txt["platform"] == "ios" { phones.insert(name) }
                        }
                    }
                }
                self.endpoints=next
                self.nearby=nearby
                self.phoneInvitations = phones
            }
            self.browser = browser
            browser.start(queue: io)
        }
    }
    deinit {advertisement?.stop();listener?.cancel();browser?.cancel()}
    func discovered() -> [String] {io.sync {Array(endpoints.keys)}}
    var listeningPort: UInt16? { io.sync { listener?.port?.rawValue } }
    static func localEndpoint(_ text: String) -> NWEndpoint? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let ip = IPv4Address(String(parts[0])), let port = UInt16(parts[1]),
              port > 0, let nwPort = NWEndpoint.Port(rawValue: port) else { return nil }
        let octets = Array(ip.rawValue)
        guard octets[0] == 10 || octets[0] == 127 || (octets[0] == 192 && octets[1] == 168) ||
              (octets[0] == 172 && (16...31).contains(octets[1])) || (octets[0] == 169 && octets[1] == 254) else { return nil }
        return .hostPort(host: .ipv4(ip), port: nwPort)
    }
    private func endpoint(for peer: Peer) -> NWEndpoint? {
        io.sync { endpoints[peer.service] } ?? (try? library.lanAddress(peer)).flatMap(Self.localEndpoint)
    }
    var isLocalNetworkDenied: Bool { io.sync { localNetworkDenied } }
    func nearbyInvitations(macOnly: Bool = false) -> [String:String] {
        io.sync { macOnly ? nearby.filter { !phoneInvitations.contains($0.key) } : nearby }
    }
    func makePairingCard() throws -> PairingCard {
        var addresses: [String] = []
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        if let port = listeningPort, getifaddrs(&interfaces) == 0, let interfaces {
            defer { freeifaddrs(interfaces) }
            var cursor: UnsafeMutablePointer<ifaddrs>? = interfaces
            while let interface = cursor?.pointee {
                cursor = interface.ifa_next
                guard String(cString: interface.ifa_name).hasPrefix("en"),
                      interface.ifa_flags & UInt32(IFF_UP) != 0,
                      let address = interface.ifa_addr, address.pointee.sa_family == AF_INET else { continue }
                var host = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count),
                                  nil, 0, NI_NUMERICHOST) == 0 else { continue }
                let value = "\(String(cString: host)):\(port)"
                if Self.localEndpoint(value) != nil, !addresses.contains(value) { addresses.append(value) }
            }
        }
        return try PairingCard(me.peer, addresses: addresses)
    }
    func offerPairing(_ card: PairingCard?, replacing challenge: UUID? = nil) {
        io.sync {
            if let challenge, invitation?.challenge != challenge { return }
            invitation = card
            pairingRequest = nil
            pairingAttempts = 0
            advertisePairing(card != nil)
            if let card {
                io.asyncAfter(deadline: .now() + max(0, card.expires.timeIntervalSinceNow)) { [weak self] in
                    guard let self, self.invitation?.challenge == card.challenge else { return }
                    self.invitation = nil
                    self.pairingRequest = nil
                    self.advertisePairing(false)
                }
            }
        }
    }
    private func advertisePairing(_ active: Bool) {
        DispatchQueue.main.async { [weak self] in self?.setPairingTXT(active) }
    }
    private func setPairingTXT(_ active: Bool) {
        var record: [String: Data] = [:]
        if active {
            record["pair"] = Data(me.peer.name.prefix(50).utf8)
            #if os(iOS)
            record["platform"] = Data("ios".utf8)
            #endif
        }
        advertisement?.setTXTRecord(NetService.data(fromTXTRecord: record))
    }
    func pendingPairing() -> Peer? {
        io.sync {
            guard pairingRequest?.receipt == nil else { return nil }
            return pairingRequest?.peer
        }
    }
    @discardableResult
    func approvePairing(_ peer: Peer, requestCode: String? = nil) throws -> String {
        try io.sync {
            if let requestCode { _ = try receivePairing(Data(requestCode.utf8)) }
            guard let invitation, let pending = pairingRequest, pending.peer == peer else {
                throw RelayFailure.invalid
            }
            try invitation.validate()
            if let receipt = pending.receipt { return receipt }
            let receipt = try pending.request.approve(at: me, card: invitation)
            try library.pair(peer)
            pairingRequest?.receipt = receipt
            advertisePairing(false)
            return receipt
        }
    }
    private func receivePairing(_ data: Data) throws -> Data {
        guard let invitation, let code = String(data: data, encoding: .utf8) else { throw RelayFailure.unavailable }
        try invitation.validate()
        if code == "invite", pairingRequest?.receipt == nil { return Data(try invitation.code().utf8) }
        if let pending = pairingRequest {
            guard pending.code == code else { throw RelayFailure.unavailable }
            return Data((pending.receipt ?? "pending").utf8)
        }
        guard pairingAttempts < 5 else { throw RelayFailure.unavailable }
        pairingAttempts += 1
        let request = try PairingRequest.parse(code)
        let peer = try request.verify(at: me, card: invitation)
        pairingRequest = (code, request, peer, nil)
        return Data("pending".utf8)
    }
    func fetchPairing(_ service: String) async throws -> String {
        let code = try await pairingMessage("invite", service: service)
        let card = try PairingCard.parse(code)
        guard try Peer.parse(card.device).service == service else { throw RelayFailure.unauthorized }
        return code
    }
    func findPairing(_ pin: String, address: String? = nil) async throws -> PairingCard {
        guard PairingCard.isShortCode(pin) else { throw RelayFailure.invalid }
        if let address {
            guard let endpoint = Self.localEndpoint(address) else { throw RelayFailure.invalid }
            let code = try await pairingMessage("invite", service: "", at: endpoint)
            let card = try PairingCard.parse(code)
            guard card.shortCode == pin else { throw RelayFailure.invalid }
            return card
        }

        // A result can be reachable even when Bonjour has not delivered its invitation TXT record.
        let services = discovered().filter { $0 != me.peer.service }
        return try await withThrowingTaskGroup(of: PairingCard?.self) { group in
            for service in services {
                group.addTask { [self] in
                    guard let code = try? await fetchPairing(service), let card = try? PairingCard.parse(code),
                          card.shortCode == pin else { return nil }
                    return card
                }
            }
            var match: PairingCard?
            for try await card in group {
                guard let card else { continue }
                guard match == nil else { throw RelayFailure.invalid }
                match = card
            }
            guard let match else { throw RelayFailure.unavailable }
            return match
        }
    }
    func pairingMessage(_ code: String, service: String, at address: NWEndpoint? = nil) async throws -> String {
        guard code.utf8.count < 4096, let endpoint = address ?? io.sync(execute: { endpoints[service] }) else {
            throw RelayFailure.unavailable
        }
        let response = try await exchange(Data(code.utf8), endpoint: endpoint, pairing: true, timeout: 3)
        guard let value = String(data: response, encoding: .utf8) else { throw RelayFailure.invalid }
        return value
    }
    func sendPairingRequest(_ code: String, card: PairingCard, address explicitAddress: String? = nil) async throws -> (code: String, address: String?) {
        let peer = try Peer.parse(card.device)
        try Task.checkCancellation()
        try card.validate()
        if let explicitAddress, let endpoint = Self.localEndpoint(explicitAddress) {
            let response = try await pairingMessage(code, service: peer.service, at: endpoint)
            return (response, explicitAddress)
        }
        if let response = try? await pairingMessage(code, service: peer.service) { return (response, nil) }
        for address in (card.addresses ?? []).prefix(3) {
            try Task.checkCancellation()
            try card.validate()
            guard let endpoint = Self.localEndpoint(address),
                  let response = try? await pairingMessage(code, service: peer.service, at: endpoint) else { continue }
            return (response, address)
        }
        throw RelayFailure.unavailable
    }
    private func receiveLAN(_ wire: Data) throws -> Data {
        let envelope = try Codec.read(Envelope.self, wire)
        if wire.count < 4096, directoryAllowed(),
           let (data, requester) = try? envelope.open(me, peers: library.directPeers(), purpose: "directory-request"),
           let nonce = UUID(uuidString: String(decoding: data, as: UTF8.self)) {
            let update = try library.publishedDirectory(nonce, requester: requester.id)
            return try Envelope.seal(Codec.pack(update), from: me, to: requester, purpose: "directory-update")
        }
        let peers = try library.peers()
        if wire.count < 4096,
           let (receipt, peer) = try? envelope.open(me, peers: peers, purpose: "lan-pull") {
            if !receipt.isEmpty {
                guard let delivered = UUID(uuidString: String(decoding: receipt, as: UTF8.self)) else { throw RelayFailure.invalid }
                try library.delivered(delivered.uuidString, peer: peer)
            }
            if let id = try library.pendingIDs(peer).first,
               let item = try library.pending(id, peer: peer) { return item }
            if let id = try library.sharedSends(peer).first,
               try library.prepareSharedSend(id, from: me, to: peer),
               let item = try library.pending(id, peer: peer) { return item }
            return try Envelope.seal(Data(), from: me, to: peer, purpose: "lan-pull-done")
        }
        if wire.count < 4096,
           let (receipt, peer) = try? envelope.open(me, peers: peers, purpose: "lan-pull-ack"),
           let delivered = UUID(uuidString: String(decoding: receipt, as: UTF8.self)) {
            try library.delivered(delivered.uuidString, peer: peer)
            return try Envelope.seal(receipt, from: me, to: peer, purpose: "lan-pull-done")
        }
        if wire.count <= Envelope.maxWire, let (data, peer) = try? envelope.open(me, peers: peers) {
            let clip = try save(data, from: peer)
            return try Envelope.seal(Data(clip.id.uuidString.utf8), from: me, to: peer, purpose: "ack")
        }
        if let (data, hub) = try? envelope.open(me, peers: peers, purpose: "relay-delivery") {
            let forward = try Codec.read(Forward.self, data)
            guard forward.wire.count <= Envelope.maxWire else { throw RelayFailure.tooLarge }
            let inner = try Codec.read(Envelope.self, forward.wire)
            let (body, origin) = try inner.open(me, peers: peers)
            let clip = try Codec.read(Clip.self, body)
            guard clip.id == forward.id else { throw RelayFailure.invalid }
            try library.save(clip, source: origin.name, received: true)
            didReceive?()
            return try Envelope.seal(Data(clip.id.uuidString.utf8), from: me, to: hub, purpose: "relay-delivery-ack")
        }
        guard forwardingAllowed() else { throw RelayFailure.unauthorized }
        let (data, sender) = try envelope.open(me, peers: peers, purpose: "forward")
        let forward = try Codec.read(Forward.self, data)
        guard forward.wire.count <= Envelope.maxWire else { throw RelayFailure.tooLarge }
        let inner = try Codec.read(Envelope.self, forward.wire)
        guard inner.sender == sender.id, inner.recipient != me.peer.id else { throw RelayFailure.unauthorized }
        try library.stageForward(forward.id.uuidString, origin: sender.id, peer: inner.recipient, wire: forward.wire)
        didReceive?()
        return try Envelope.seal(Data(forward.id.uuidString.utf8), from: me, to: sender, purpose: "forward-ack")
    }
    func refreshDirectory(at address: NWEndpoint? = nil) async throws {
        let id = try library.directoryOwner()
        guard !id.isEmpty, let owner = try library.directPeers().first(where: { $0.id == id }),
              let endpoint = address ?? endpoint(for: owner) else { return }
        let nonce = UUID()
        let request = try Envelope.seal(Data(nonce.uuidString.utf8), from: me, to: owner, purpose: "directory-request")
        let wire = try await exchange(request, endpoint: endpoint, pairing: false, timeout: 2)
        guard wire.count <= 16_384 else { throw RelayFailure.tooLarge }
        let (data, _) = try Codec.read(Envelope.self, wire).open(me, peers: [owner], purpose: "directory-update")
        let update = try Codec.read(MemberDirectory.self, data)
        guard update.nonce == nonce else { throw RelayFailure.unauthorized }
        try library.applyDirectory(update, from: owner, selfID: me.peer.id)
    }
    func accept(_ wire:Data)throws -> (Clip,Peer) {
        guard wire.count<=Envelope.maxWire else {throw RelayFailure.tooLarge}
        let envelope=try Codec.read(Envelope.self,wire)
        let (data,peer)=try envelope.open(me,peers:library.peers())
        return (try save(data, from: peer), peer)
    }
    private func save(_ data: Data, from peer: Peer) throws -> Clip {
        let clip=try Codec.read(Clip.self,data)
        try library.save(clip,source:peer.name,received:true)
        didReceive?()
        return clip
    }
    private func write(_ data:Data,on c:NWConnection,pairing:Bool,done:@escaping (NWError?)->Void) {
        var n=(UInt32(data.count) | (pairing ? Self.pairingFlag : 0)).bigEndian
        c.send(content:withUnsafeBytes(of:&n){Data($0)}+data,completion:.contentProcessed(done))
    }
    private func read(_ c:NWConnection,done:@escaping(Data?, Bool)->Void) {
        c.receive(minimumIncompleteLength:4,maximumLength:4){ header,_,_,error in
            guard error==nil,let header,header.count==4 else {done(nil,false);return}
            let frame=header.reduce(UInt32(0)){$0*256+UInt32($1)}
            let pairing=frame & Self.pairingFlag != 0
            let size=Int(frame & ~Self.pairingFlag)
            guard size>0,size<=(pairing ? 4096 : Self.maxLANFrame) else {done(nil,pairing);return}
            c.receive(minimumIncompleteLength:size,maximumLength:size){body,_,_,error in
                done(error==nil && body?.count==size ? body:nil,pairing)
            }
        }
    }
    func sendLAN(_ wire:Data,id:String,to peer:Peer,at address:NWEndpoint?=nil,purpose:String="ack") async throws {
        guard let endpoint=address ?? endpoint(for:peer) else {throw RelayFailure.unavailable}
        let ack = try await exchange(wire, endpoint: endpoint, pairing: false, timeout: purpose == "ack" && wire.count < 65_536 ? 2 : 8)
        let (receipt,_) = try Codec.read(Envelope.self,ack).open(me,peers:[peer],purpose:purpose)
        guard receipt == Data(id.utf8) else {throw RelayFailure.invalid}
    }
    func pullLAN(from peer: Peer) async throws -> Int {
        guard try library.peers().contains(peer) else { throw RelayFailure.unauthorized }
        guard let endpoint = endpoint(for: peer) else { throw RelayFailure.unavailable }
        var receipt = Data()
        for count in 0..<30 {
            try Task.checkCancellation()
            let request = try Envelope.seal(receipt, from: me, to: peer, purpose: "lan-pull")
            let wire = try await exchange(request, endpoint: endpoint, pairing: false, timeout: 8)
            let reply = try Codec.read(Envelope.self, wire)
            if let (done, _) = try? reply.open(me, peers: [peer], purpose: "lan-pull-done"), done.isEmpty { return count }
            let (body, sender) = try reply.open(me, peers: [peer])
            let clip = try save(body, from: sender)
            receipt = Data(clip.id.uuidString.utf8)
        }
        try await sendLAN(Envelope.seal(receipt, from: me, to: peer, purpose: "lan-pull-ack"),
                          id: String(decoding: receipt, as: UTF8.self), to: peer, at: endpoint, purpose: "lan-pull-done")
        return 30
    }
    private func exchange(_ wire: Data, endpoint: NWEndpoint, pairing: Bool, timeout: TimeInterval) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let c=NWConnection(to:endpoint,using:.tcp)
            var finished=false
            func finish(_ data:Data?) {
                guard !finished else{return}; finished=true; c.stateUpdateHandler=nil; c.cancel()
                if let data {continuation.resume(returning:data)} else {continuation.resume(throwing:RelayFailure.unavailable)}
            }
            c.stateUpdateHandler={state in
                switch state {
                case .ready: self.write(wire,on:c,pairing:pairing){error in
                    if error != nil {finish(nil)} else {self.read(c){ data, responsePairing in finish(responsePairing == pairing ? data : nil) }}
                }
                case .failed, .cancelled:finish(nil)
                default: break
                }
            }
            c.start(queue:self.io)
            self.io.asyncAfter(deadline:.now()+timeout){finish(nil)}
        }
    }
    func sendRelay(_ wire: Data, id: String, via hub: Peer, at address: NWEndpoint? = nil) async throws {
        guard let uuid = UUID(uuidString: id) else { throw RelayFailure.invalid }
        let packet = try Envelope.seal(Codec.pack(Forward(id: uuid, wire: wire)), from: me, to: hub, purpose: "forward")
        try await sendLAN(packet, id: id, to: hub, at: address, purpose: "forward-ack")
    }
    func queue(_ clip:Clip) throws {
        try library.save(clip,source:"Local")
        for peer in try library.peers() {
            if try library.pending(clip.id.uuidString,peer:peer) == nil {
                try library.queue(clip.id.uuidString,peer:peer,wire:Envelope.seal(Codec.pack(clip),from:me,to:peer))
            }
        }
    }
    @discardableResult func flush(to peer:Peer, cloud:Cloud?, address:NWEndpoint?=nil, only idFilter:String?=nil) async throws -> [String] {
        guard try library.peers().contains(peer) else { throw RelayFailure.unauthorized }
        var routes:[String]=[]
        for id in try idFilter.map({[$0]}) ?? library.pendingIDs(peer) {
            guard let wire=try library.pending(id,peer:peer) else {continue}
            do {try await sendLAN(wire,id:id,to:peer,at:address);routes.append("LAN")}
            catch {
                if address == nil, await relay(wire, id: id, destination: peer) {
                    routes.append("LAN Relay")
                } else {
                    guard let cloud else {throw error}
                    try await cloud.put(wire,peer.box,id);routes.append("Cloud")
                }
            }
            try library.delivered(id,peer:peer)
        }
        return routes
    }
    private func relay(_ wire: Data, id: String, destination: Peer) async -> Bool {
        let local = Set(discovered())
        guard let peers = try? library.peers() else { return false }
        for hub in peers where hub.id != destination.id && local.contains(hub.service) {
            do {
                try await sendRelay(wire, id: id, via: hub)
                return true
            } catch { continue }
        }
        return false
    }
    @discardableResult func flushForwarded(to peer: Peer, cloud: Cloud?, address: NWEndpoint? = nil) async throws -> [String] {
        guard forwardingAllowed() else { return [] }
        guard try library.peers().contains(peer) else { throw RelayFailure.unauthorized }
        var routes: [String] = []
        for job in try library.forwards(to: peer) {
            guard let wire = try library.forward(job.id, origin: job.origin, to: peer) else { continue }
            do {
                guard let uuid = UUID(uuidString: job.id) else { throw RelayFailure.invalid }
                let packet = try Envelope.seal(Codec.pack(Forward(id: uuid, wire: wire)), from: me, to: peer, purpose: "relay-delivery")
                try await sendLAN(packet, id: job.id, to: peer, at: address, purpose: "relay-delivery-ack")
                routes.append("LAN")
            } catch {
                guard let cloud else { throw error }
                try await cloud.put(wire, peer.box, job.id)
                routes.append("Cloud")
            }
            try library.forwarded(job.id, origin: job.origin, to: peer)
        }
        return routes
    }
    func pull(_ cloud:Cloud) async throws -> Int {
        var count=0, cursor:String?
        repeat {
            let page=try await cloud.list(me,cursor)
            for id in page.ids {
                guard let uuid=UUID(uuidString:id), let wire = try await cloud.read(me,id) else { continue }
                let peers = try library.peers()
                guard let envelope = try? Codec.read(Envelope.self,wire),
                      let (data, peer) = try? envelope.open(me,peers:peers),
                      let clip = try? Codec.read(Clip.self,data), uuid == clip.id,
                      (try? clip.validate()) != nil else { continue }
                try library.save(clip,source:peer.name,received:true)
                try await cloud.remove(me,id);count+=1;didReceive?()
            }
            cursor=page.cursor
        } while cursor != nil
        return count
    }
}

final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping(URLRequest?)->Void) {completionHandler(nil)}
}
struct Cloud {
    private enum HTTPFailure: Error { case missing }
    let base:URL, token:String
    static let session=URLSession(configuration:.ephemeral,delegate:NoRedirect(),delegateQueue:nil)
    init(_ address:String,_ token:String)throws {
        guard let u=URL(string:address),u.scheme=="https",u.host != nil,u.user==nil,u.password==nil,u.query==nil,u.fragment==nil,!token.isEmpty else {throw RelayFailure.invalid}
        self.base=u;self.token=token
    }
    private func request(_ method:String,_ box:String,_ id:String?,_ reader:String?,body:Data?=nil,cursor:String?=nil) async throws ->Data {
        var url=base.appendingPathComponent("v1/box").appendingPathComponent(box)
        if let id {url.appendPathComponent(id.lowercased())}
        if let cursor {url.append(queryItems:[URLQueryItem(name:"cursor",value:cursor)])}
        var req=URLRequest(url:url,timeoutInterval:30);req.httpMethod=method;req.httpBody=body
        req.setValue("Bearer "+token,forHTTPHeaderField:"Authorization")
        req.setValue(reader,forHTTPHeaderField:"X-ClipRelay-Reader")
        let (data,response)=try await Self.session.data(for:req)
        guard let http=response as? HTTPURLResponse else { throw RelayFailure.unavailable }
        if http.statusCode == 404 && method == "GET" && id != nil { throw HTTPFailure.missing }
        guard (200..<300).contains(http.statusCode) else { throw RelayFailure.unavailable }
        guard data.count<=Envelope.maxWire else {throw RelayFailure.tooLarge}
        return data
    }
    struct Page:Decodable {let ids:[String];let cursor:String?}
    func list(_ me:Identity,_ cursor:String?) async throws ->Page {try JSONDecoder().decode(Page.self,from:await request("GET",me.peer.box,nil,me.reader,cursor:cursor))}
    func read(_ me:Identity,_ id:String) async throws ->Data? {
        do { return try await request("GET",me.peer.box,id,me.reader) }
        catch HTTPFailure.missing { return nil }
        catch RelayFailure.tooLarge { return nil }
    }
    func remove(_ me:Identity,_ id:String) async throws {_ = try await request("DELETE",me.peer.box,id,me.reader)}
    func put(_ wire:Data,_ box:String,_ id:String) async throws {_ = try await request("PUT",box,id,nil,body:wire)}
}
