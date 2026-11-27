import CryptoKit
import Foundation

/// SSTP wire format ([MS-SSTP]): 4-byte header (0x10, C flag, 12-bit length), then data (PPP) or control.
enum SSTP {
    enum Msg {
        static let connectRequest: UInt16 = 1, connectAck: UInt16 = 2, connectNak: UInt16 = 3, connected: UInt16 = 4
        static let abort: UInt16 = 5, disconnect: UInt16 = 6, disconnectAck: UInt16 = 7
        static let echoRequest: UInt16 = 8, echoResponse: UInt16 = 9
    }

    enum Packet {
        case control(UInt16, [UInt8: [UInt8]]) // message type, attribute id -> value
        case data([UInt8])
        case invalid
    }

    static func control(_ type: UInt16, _ attrs: [(UInt8, [UInt8])] = []) -> [UInt8] {
        let len = 8 + attrs.reduce(0) { $0 + 4 + $1.1.count }
        var p: [UInt8] = [0x10, 0x01, UInt8(len >> 8), UInt8(len & 0xFF),
                          UInt8(type >> 8), UInt8(type & 0xFF), 0, UInt8(attrs.count)]
        for (id, v) in attrs {
            let l = v.count + 4
            p += [0, id, UInt8(l >> 8), UInt8(l & 0xFF)] + v
        }
        return p
    }

    static func data(_ payload: [UInt8]) -> [UInt8] {
        let len = payload.count + 4
        return [0x10, 0x00, UInt8(len >> 8), UInt8(len & 0xFF)] + payload
    }

    /// Consumes one packet from the front of `b`; nil if incomplete.
    static func parse(_ b: inout [UInt8]) -> Packet? {
        guard b.count >= 4 else { return nil }
        guard b[0] == 0x10 else { return .invalid }
        let len = Int(b[2] & 0x0F) << 8 | Int(b[3])
        guard len >= 4 else { return .invalid }
        guard b.count >= len else { return nil }
        let body = Array(b[4..<len])
        let isControl = b[1] & 1 == 1
        b.removeFirst(len)
        guard isControl else { return .data(body) }
        guard body.count >= 4 else { return .invalid }
        var attrs: [UInt8: [UInt8]] = [:]
        var o = 4
        while o + 4 <= body.count {
            let l = Int(body[o + 2] & 0x0F) << 8 | Int(body[o + 3])
            guard l >= 4, o + l <= body.count else { return .invalid }
            attrs[body[o + 1]] = Array(body[o + 4..<o + l])
            o += l
        }
        return .control(UInt16(body[0]) << 8 | UInt16(body[1]), attrs)
    }

    /// Call Connected with Crypto Binding: ties the TLS server cert to the PPP auth keys.
    static func callConnected(nonce: [UInt8], cert: [UInt8], bitmask: UInt8, hlak: [UInt8]) -> [UInt8] {
        let sha256 = bitmask == 2
        let certHash: [UInt8] = sha256
            ? Array(SHA256.hash(data: cert))
            : Array(Insecure.SHA1.hash(data: cert)) + [UInt8](repeating: 0, count: 12)
        let value: [UInt8] = [0, 0, 0, bitmask] + nonce + certHash + [UInt8](repeating: 0, count: 32)
        var pkt = control(Msg.connected, [(3, value)])

        // CMK = HMAC(HLAK, seed | outlen(LE16) | 0x01); MAC covers the whole packet with the MAC field zeroed
        let seed = Array("SSTP inner method derived CMK".utf8) + [sha256 ? 0x20 : 0x14, 0, 1]
        let cmk = hmac(sha256: sha256, key: hlak, data: seed)
        var mac = hmac(sha256: sha256, key: cmk, data: pkt)
        mac += [UInt8](repeating: 0, count: 32 - mac.count)
        pkt.replaceSubrange((pkt.count - 32)..., with: mac)
        return pkt
    }
}
