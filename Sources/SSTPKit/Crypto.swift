import CommonCrypto
import CryptoKit
import Foundation

// CryptoKit has no MD4 or DES, which MS-CHAPv2 needs.
func md4(_ message: [UInt8]) -> [UInt8] {
    var m = message + [0x80]
    while m.count % 64 != 56 { m.append(0) }
    let bits = UInt64(message.count) * 8
    for i in 0..<8 { m.append(UInt8(truncatingIfNeeded: bits >> (8 * UInt64(i)))) }

    var h: [UInt32] = [0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476]
    let order3 = [0, 8, 4, 12, 2, 10, 6, 14, 1, 9, 5, 13, 3, 11, 7, 15]
    for chunk in stride(from: 0, to: m.count, by: 64) {
        var x = [UInt32](repeating: 0, count: 16)
        for i in 0..<16 {
            for j in 0..<4 { x[i] |= UInt32(m[chunk + 4 * i + j]) << (8 * UInt32(j)) }
        }
        var v = h
        for i in 0..<48 {
            let r = i % 4
            let a = (4 - r) % 4, b = (a + 1) % 4, c = (a + 2) % 4, d = (a + 3) % 4
            let f: UInt32, k: Int, s: UInt32, add: UInt32
            switch i / 16 {
            case 0:
                f = (v[b] & v[c]) | (~v[b] & v[d]); k = i; s = [3, 7, 11, 19][r]; add = 0
            case 1:
                let j = i - 16
                f = (v[b] & v[c]) | (v[b] & v[d]) | (v[c] & v[d]); k = (j % 4) * 4 + j / 4; s = [3, 5, 9, 13][r]; add = 0x5a827999
            default:
                f = v[b] ^ v[c] ^ v[d]; k = order3[i - 32]; s = [3, 9, 11, 15][r]; add = 0x6ed9eba1
            }
            let t = v[a] &+ f &+ x[k] &+ add
            v[a] = (t << s) | (t >> (32 - s))
        }
        for i in 0..<4 { h[i] = h[i] &+ v[i] }
    }
    return h.flatMap { w in (0..<4).map { UInt8(truncatingIfNeeded: w >> (8 * UInt32($0))) } }
}

func hmac(sha256: Bool, key: [UInt8], data: [UInt8]) -> [UInt8] {
    let k = SymmetricKey(data: key)
    return sha256
        ? Array(HMAC<SHA256>.authenticationCode(for: data, using: k))
        : Array(HMAC<Insecure.SHA1>.authenticationCode(for: data, using: k))
}

private func sha1(_ d: [UInt8]) -> [UInt8] { Array(Insecure.SHA1.hash(data: d)) }

private func desEncrypt(key7 k: [UInt8], block: [UInt8]) -> [UInt8] {
    // 56-bit key -> 64-bit DES key (parity bits left unset; CommonCrypto ignores them)
    let key: [UInt8] = [
        k[0],
        k[0] << 7 | k[1] >> 1, k[1] << 6 | k[2] >> 2, k[2] << 5 | k[3] >> 3,
        k[3] << 4 | k[4] >> 4, k[4] << 3 | k[5] >> 5, k[5] << 2 | k[6] >> 6,
        k[6] << 1,
    ]
    var out = [UInt8](repeating: 0, count: 8)
    var moved = 0
    let rc = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmDES), CCOptions(kCCOptionECBMode),
                     key, 8, nil, block, 8, &out, 8, &moved)
    precondition(rc == kCCSuccess, "DES failed")
    return out
}

/// MS-CHAPv2 (RFC 2759) and the MPPE-derived key SSTP uses for crypto binding (RFC 3079).
enum MSCHAPv2 {
    static func ntHash(_ password: String) -> [UInt8] {
        md4(password.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
    }

    static func challengeHash(peer: [UInt8], auth: [UInt8], user: String) -> [UInt8] {
        var name = user
        if let i = user.lastIndex(of: "\\") { name = String(user[user.index(after: i)...]) } // strip DOMAIN\
        return Array(sha1(peer + auth + Array(name.utf8)).prefix(8))
    }

    static func ntResponse(challenge: [UInt8], password: String) -> [UInt8] {
        let key = ntHash(password) + [UInt8](repeating: 0, count: 5)
        return (0..<3).flatMap { desEncrypt(key7: Array(key[$0 * 7..<$0 * 7 + 7]), block: challenge) }
    }

    static func authenticatorResponse(password: String, ntResponse: [UInt8], peer: [UInt8], auth: [UInt8], user: String) -> String {
        let digest = sha1(md4(ntHash(password)) + ntResponse + Array("Magic server to client signing constant".utf8))
        let r = sha1(digest + challengeHash(peer: peer, auth: auth, user: user) + Array("Pad to make it do more than one iteration".utf8))
        return "S=" + r.map { String(format: "%02X", $0) }.joined()
    }

    static func masterKey(password: String, ntResponse: [UInt8]) -> [UInt8] {
        Array(sha1(md4(ntHash(password)) + ntResponse + Array("This is the MPPE Master Key".utf8)).prefix(16))
    }

    /// SSTP client HLAK = MasterSendKey | MasterReceiveKey ([MS-SSTP] 3.2.5.2.1).
    static func hlak(password: String, ntResponse: [UInt8]) -> [UInt8] {
        let master = masterKey(password: password, ntResponse: ntResponse)
        func key(_ magic: String) -> [UInt8] {
            Array(sha1(master + [UInt8](repeating: 0, count: 40) + Array(magic.utf8) + [UInt8](repeating: 0xF2, count: 40)).prefix(16))
        }
        return key("On the client side, this is the send key; on the server side, it is the receive key.")
            + key("On the client side, this is the receive key; on the server side, it is the send key.")
    }
}
