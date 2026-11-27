import Foundation

private func opt(_ t: UInt8, _ v: [UInt8]) -> [UInt8] { [t, UInt8(v.count + 2)] + v }
private func be16(_ v: Int) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xFF)] }
private func be32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: v >> (24 - 8 * UInt32($0))) } }

private func options(_ d: [UInt8]) -> [(t: UInt8, v: [UInt8])] {
    var out: [(t: UInt8, v: [UInt8])] = []
    var i = 0
    while i + 2 <= d.count {
        let l = Int(d[i + 1])
        guard l >= 2, i + l <= d.count else { break }
        out.append((d[i], Array(d[i + 2..<i + l])))
        i += l
    }
    return out
}

private struct Pkt {
    var code: UInt8, id: UInt8, data: [UInt8]
    init?(_ b: [UInt8]) {
        guard b.count >= 4 else { return nil }
        let len = Int(b[2]) << 8 | Int(b[3])
        guard len >= 4 else { return nil }
        code = b[0]; id = b[1]; data = Array(b[4..<min(len, b.count)])
    }
}

private enum Verdict { case ack, nak([UInt8]), reject }

private let zeroIP = [UInt8](repeating: 0, count: 4)

/// Client-side PPP over SSTP: LCP, MS-CHAPv2, IPCP. Everything runs on `queue`.
/// Anything else the server proposes (CCP, IPv6CP, compression, ...) is rejected.
final class PPP {
    struct IPConfig { var local: [UInt8]; var remote: [UInt8]; var dns: [[UInt8]]; var mtu: Int }

    var send: ([UInt8]) -> Void = { _ in }
    var onAuthenticated: ([UInt8]) -> Void = { _ in } // HLAK for SSTP crypto binding
    var onUp: (IPConfig) -> Void = { _ in }
    var onIP: ([UInt8]) -> Void = { _ in }
    var onFail: (String) -> Void = { _ in }
    var onAuthFailed: (String) -> Void = { _ in } // retrying would fail the same way (and may lock the account)

    private let queue: DispatchQueue
    private let username: String
    private let password: String
    private let magic = UInt32.random(in: 1...UInt32.max)
    private var timer: DispatchSourceTimer?

    private var mru = 1400
    private var sendMRU = true
    private var peerMRU = 1500
    private var lcpID: UInt8 = 0
    private var lcpReq: [UInt8] = []
    private var lcpOurAcked = false, lcpPeerAcked = false, lcpOpen = false
    private var peerAuth = false
    private var chap: (auth: [UInt8], peer: [UInt8], nt: [UInt8])?
    private var miscID: UInt8 = 0

    private var ipcpID: UInt8 = 0
    private var ipcpStarted = false, ipcpOurAcked = false, ipcpPeerAcked = false, ipcpOpen = false
    private var ourIP = zeroIP, peerIP = zeroIP
    private var dns = [zeroIP, zeroIP]
    private var wantDNS = [true, true]

    init(username: String, password: String, queue: DispatchQueue) {
        self.username = username
        self.password = password
        self.queue = queue
    }

    func start() {
        sendLCPRequest()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 3, repeating: 3)
        t.setEventHandler { [weak self] in self?.retransmit() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    func sendIP(_ ip: [UInt8]) {
        guard ipcpOpen else { return }
        send([0xFF, 0x03, 0x00, 0x21] + ip)
    }

    func receive(_ f: [UInt8]) {
        var i = 0
        if f.count >= 2, f[0] == 0xFF, f[1] == 0x03 { i = 2 }
        guard f.count >= i + 2 else { return }
        let proto = UInt16(f[i]) << 8 | UInt16(f[i + 1])
        let body = Array(f[(i + 2)...])
        switch proto {
        case 0x0021: if ipcpOpen { onIP(body) }
        case 0xC021: lcp(body)
        case 0xC223: chapPacket(body)
        case 0x8021: ipcp(body)
        default:
            miscID &+= 1
            tx(0xC021, 8, miscID, be16(Int(proto)) + body.prefix(64)) // Protocol-Reject
        }
    }

    // MARK: framing

    private func tx(_ proto: UInt16, _ code: UInt8, _ id: UInt8, _ data: [UInt8] = []) {
        let len = data.count + 4
        send([0xFF, 0x03, UInt8(proto >> 8), UInt8(proto & 0xFF), code, id, UInt8(len >> 8), UInt8(len & 0xFF)] + data)
    }

    /// Answers a peer Configure-Request: Reject beats Nak beats Ack. Returns true if we Acked.
    private func answer(_ proto: UInt16, _ p: Pkt, _ judge: (UInt8, [UInt8]) -> Verdict) -> Bool {
        var nak: [UInt8] = [], rej: [UInt8] = []
        for (t, v) in options(p.data) {
            switch judge(t, v) {
            case .ack: break
            case .nak(let o): nak += o
            case .reject: rej += opt(t, v)
            }
        }
        if !rej.isEmpty { tx(proto, 4, p.id, rej); return false }
        if !nak.isEmpty { tx(proto, 3, p.id, nak); return false }
        tx(proto, 2, p.id, p.data)
        return true
    }

    private func retransmit() {
        if !lcpOurAcked {
            tx(0xC021, 1, lcpID, lcpReq)
        } else if ipcpStarted, !ipcpOurAcked {
            tx(0x8021, 1, ipcpID, ipcpRequest())
        }
    }

    // MARK: LCP

    private func sendLCPRequest() {
        lcpID &+= 1
        lcpOurAcked = false
        lcpReq = (sendMRU ? opt(1, be16(mru)) : []) + opt(5, be32(magic))
        tx(0xC021, 1, lcpID, lcpReq)
    }

    private func lcp(_ b: [UInt8]) {
        guard let p = Pkt(b) else { return }
        switch p.code {
        case 1:
            lcpPeerAcked = answer(0xC021, p) { t, v in
                switch t {
                case 1 where v.count == 2:
                    peerMRU = Int(v[0]) << 8 | Int(v[1])
                    return .ack
                case 5 where v.count == 4:
                    return .ack
                case 3:
                    if v == [0xC2, 0x23, 0x81] { peerAuth = true; return .ack } // CHAP, MS-CHAPv2 only
                    return .nak(opt(3, [0xC2, 0x23, 0x81]))
                default:
                    return .reject
                }
            }
            lcpMaybeOpen()
        case 2:
            if p.id == lcpID { lcpOurAcked = true; lcpMaybeOpen() }
        case 3:
            for (t, v) in options(p.data) where t == 1 && v.count == 2 {
                mru = min(max(Int(v[0]) << 8 | Int(v[1]), 576), 1500)
            }
            sendLCPRequest()
        case 4:
            if options(p.data).contains(where: { $0.t == 1 }) { sendMRU = false }
            sendLCPRequest()
        case 5:
            tx(0xC021, 6, p.id)
            onFail("Server closed the PPP link")
        case 9:
            tx(0xC021, 10, p.id, be32(magic) + p.data.dropFirst(4))
        default:
            break
        }
    }

    private func lcpMaybeOpen() {
        guard lcpOurAcked, lcpPeerAcked, !lcpOpen else { return }
        lcpOpen = true
        if !peerAuth { // no auth required: HLAK is 32 zero bytes
            onAuthenticated([UInt8](repeating: 0, count: 32))
            startIPCP()
        }
    }

    // MARK: MS-CHAPv2

    private func chapPacket(_ b: [UInt8]) {
        guard peerAuth, let p = Pkt(b) else { return }
        switch p.code {
        case 1:
            guard p.data.count >= 17, p.data[0] == 16 else { return onFail("Malformed CHAP challenge") }
            let auth = Array(p.data[1..<17])
            let peer = (0..<16).map { _ in UInt8.random(in: 0...255) }
            let nt = MSCHAPv2.ntResponse(challenge: MSCHAPv2.challengeHash(peer: peer, auth: auth, user: username), password: password)
            chap = (auth, peer, nt)
            tx(0xC223, 2, p.id, [49] + peer + [UInt8](repeating: 0, count: 8) + nt + [0] + Array(username.utf8))
        case 3:
            guard let c = chap else { return }
            let expected = MSCHAPv2.authenticatorResponse(password: password, ntResponse: c.nt, peer: c.peer, auth: c.auth, user: username)
            guard String(decoding: p.data, as: UTF8.self).uppercased().hasPrefix(expected) else {
                return onAuthFailed("Server failed mutual authentication")
            }
            onAuthenticated(MSCHAPv2.hlak(password: password, ntResponse: c.nt))
            startIPCP()
        case 4:
            onAuthFailed("Authentication failed: " + String(decoding: p.data, as: UTF8.self))
        default:
            break
        }
    }

    // MARK: IPCP

    private func startIPCP() {
        ipcpStarted = true
        sendIPCPRequest()
    }

    private func ipcpRequest() -> [UInt8] {
        opt(3, ourIP) + (wantDNS[0] ? opt(129, dns[0]) : []) + (wantDNS[1] ? opt(131, dns[1]) : [])
    }

    private func sendIPCPRequest() {
        ipcpID &+= 1
        ipcpOurAcked = false
        tx(0x8021, 1, ipcpID, ipcpRequest())
    }

    private func ipcp(_ b: [UInt8]) {
        guard let p = Pkt(b) else { return }
        switch p.code {
        case 1:
            ipcpPeerAcked = answer(0x8021, p) { t, v in
                guard t == 3, v.count == 4 else { return .reject }
                peerIP = v
                return .ack
            }
            ipcpMaybeOpen()
        case 2:
            if p.id == ipcpID { ipcpOurAcked = true; ipcpMaybeOpen() }
        case 3:
            for (t, v) in options(p.data) where v.count == 4 {
                switch t {
                case 3: ourIP = v
                case 129: dns[0] = v
                case 131: dns[1] = v
                default: break
                }
            }
            sendIPCPRequest()
        case 4:
            for (t, _) in options(p.data) {
                if t == 3 { return onFail("Server rejected IP address negotiation") }
                if t == 129 { wantDNS[0] = false }
                if t == 131 { wantDNS[1] = false }
            }
            sendIPCPRequest()
        case 5:
            tx(0x8021, 6, p.id)
            onFail("Server closed the PPP link")
        default:
            break
        }
    }

    private func ipcpMaybeOpen() {
        guard ipcpOurAcked, ipcpPeerAcked, !ipcpOpen else { return }
        guard ourIP != zeroIP else { return onFail("Server did not assign an IP address") }
        ipcpOpen = true
        stop()
        onUp(IPConfig(local: ourIP, remote: peerIP == zeroIP ? ourIP : peerIP,
                      dns: dns.enumerated().filter { wantDNS[$0.offset] && $0.element != zeroIP }.map(\.element),
                      mtu: min(mru, peerMRU)))
    }
}
