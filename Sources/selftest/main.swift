import Foundation
@testable import SSTPKit


var failures = 0
func check(_ ok: Bool, _ what: String = "", line: Int = #line) {
    if !ok { failures += 1; print("FAIL line \(line) \(what)") }
}

private func hex(_ s: String) -> [UInt8] {
    var out: [UInt8] = []
    var it = s.makeIterator()
    while let a = it.next(), let b = it.next() { out.append(UInt8(String([a, b]), radix: 16)!) }
    return out
}

func md4Vectors() {
    check(md4([]) == hex("31d6cfe0d16ae931b73c59d7e0c089c0"))
    check(md4(Array("abc".utf8)) == hex("a448017aaf21d8525fc10ae87aa6729d"))
    check(md4(Array("12345678901234567890123456789012345678901234567890123456789012345678901234567890".utf8))
            == hex("e33b4ddc9c38f2199c3e7b164fcc0536"))
}

// RFC 2759 section 9.2 / RFC 3079 section 3.5.3 test vectors
func msChapV2Vectors() {
    let auth = hex("5B5D7C7D7B3F2F3E3C2C602132262628")
    let peer = hex("21402324255E262A28295F2B3A337C7E")
    let ch = MSCHAPv2.challengeHash(peer: peer, auth: auth, user: "User")
    check(ch == hex("D02E4386BCE91226"))
    let nt = MSCHAPv2.ntResponse(challenge: ch, password: "clientPass")
    check(nt == hex("82309ECD8D708B5EA08FAA3981CD83544233114A3D85D6DF"))
    check(MSCHAPv2.authenticatorResponse(password: "clientPass", ntResponse: nt, peer: peer, auth: auth, user: "User")
            == "S=407A5589115FD0D6209F510FE9C04566932CDA56")
    check(MSCHAPv2.masterKey(password: "clientPass", ntResponse: nt) == hex("FDECE3717A8C838CB388E527AE3CDD31"))
    check(MSCHAPv2.hlak(password: "clientPass", ntResponse: nt).count == 32)
}

func sstpFraming() {
    // sample from [MS-SSTP] "Crypto Binding" section
    check(SSTP.control(SSTP.Msg.connectRequest, [(1, [0, 1])]) == hex("10010 00E 0001 0001 00010006 0001".replacingOccurrences(of: " ", with: "")))

    let cc = SSTP.callConnected(nonce: [UInt8](repeating: 7, count: 32), cert: [1, 2, 3], bitmask: 2, hlak: [UInt8](repeating: 9, count: 32))
    check(cc.count == 112)
    check(Array(cc[..<12]) == hex("100100700004000100030068"))

    var buf = SSTP.data([0xFF, 0x03]) + SSTP.control(SSTP.Msg.echoRequest) + [0x10]
    guard case .data(let d)? = SSTP.parse(&buf), d == [0xFF, 0x03] else { return check(false, "data") }
    guard case .control(let t, let a)? = SSTP.parse(&buf), t == SSTP.Msg.echoRequest, a.isEmpty else { return check(false, "control") }
    check(SSTP.parse(&buf) == nil) // trailing partial header stays buffered
    check(buf == [0x10])
}

/// Plays the server side of LCP -> MS-CHAPv2 -> IPCP against PPP.
func pppNegotiation() {
    let ppp = PPP(username: "User", password: "clientPass", queue: DispatchQueue(label: "t"))
    var sent: [[UInt8]] = []
    var hlak: [UInt8]?
    var up: PPP.IPConfig?
    ppp.send = { sent.append($0) }
    ppp.onAuthenticated = { hlak = $0 }
    ppp.onUp = { up = $0 }
    ppp.onFail = { check(false, $0) }
    defer { ppp.stop() }

    func frame(_ proto: UInt16, _ code: UInt8, _ id: UInt8, _ data: [UInt8]) -> [UInt8] {
        let n = data.count + 4
        return [0xFF, 0x03, UInt8(proto >> 8), UInt8(proto & 0xFF), code, id, UInt8(n >> 8), UInt8(n & 0xFF)] + data
    }
    func last() -> (proto: UInt16, code: UInt8, id: UInt8, data: [UInt8]) {
        let f = sent.last!
        return (UInt16(f[2]) << 8 | UInt16(f[3]), f[4], f[5], Array(f[8...]))
    }

    ppp.start()
    check(last().proto == 0xC021 && last().code == 1)
    let ourLCP = last().id

    // server: MRU + CHAP-MSv2 + magic + an option we must reject (PFC)
    ppp.receive(frame(0xC021, 1, 7, [1, 4, 5, 0x78, 3, 5, 0xC2, 0x23, 0x81, 5, 6, 1, 2, 3, 4, 7, 2]))
    check(last().code == 4)
    check(last().data == [7, 2])
    ppp.receive(frame(0xC021, 1, 8, [1, 4, 5, 0x78, 3, 5, 0xC2, 0x23, 0x81, 5, 6, 1, 2, 3, 4]))
    check(last().code == 2)
    ppp.receive(frame(0xC021, 2, ourLCP, []))

    let auth = (0..<16).map { UInt8($0) }
    ppp.receive(frame(0xC223, 1, 1, [16] + auth + Array("srv".utf8)))
    let resp = last()
    check(resp.proto == 0xC223 && resp.code == 2)
    check(resp.data.count == 1 + 49 + 4)
    let peer = Array(resp.data[1..<17]), nt = Array(resp.data[25..<49])
    check(nt == MSCHAPv2.ntResponse(challenge: MSCHAPv2.challengeHash(peer: peer, auth: auth, user: "User"), password: "clientPass"))
    let ok = MSCHAPv2.authenticatorResponse(password: "clientPass", ntResponse: nt, peer: peer, auth: auth, user: "User")
    ppp.receive(frame(0xC223, 3, 1, Array((ok + " M=hi").utf8)))
    check(hlak?.count == 32)
    check(last().proto == 0x8021)

    ppp.receive(frame(0x8021, 1, 3, [3, 6, 10, 0, 0, 1]))
    check(last().code == 2)
    let ipcpID = sent.last { $0[2] == 0x80 && $0[4] == 1 }![5]
    ppp.receive(frame(0x8021, 3, ipcpID, [3, 6, 10, 0, 0, 2, 129, 6, 8, 8, 8, 8, 131, 6, 1, 1, 1, 1]))
    check(last().code == 1)
    check(up == nil)
    ppp.receive(frame(0x8021, 2, last().id, last().data))
    check(up?.local == [10, 0, 0, 2])
    check(up?.remote == [10, 0, 0, 1])
    check(up?.dns == [[8, 8, 8, 8], [1, 1, 1, 1]])
}

// VPN DNS selection keeps internal resolvers only
check([[10, 10, 5, 1], [172, 16, 0, 1], [172, 31, 9, 9], [192, 168, 1, 1], [100, 64, 0, 1]].allSatisfy(isPrivateIPv4))
check(![[8, 8, 8, 8], [172, 32, 0, 1], [172, 15, 0, 1], [100, 128, 0, 1], [192, 169, 0, 1]].contains(where: isPrivateIPv4))

// Profile validation: values from the socket reach `route` argv and `scutil` stdin as root
check(parseCIDR("192.168.212.0/24") == "192.168.212.0/24")
check(parseCIDR("10.1.2.3") == "10.1.2.3/32")
check(["", "10.0.0.0/0", "10.0.0.0/33", "-net", "10.0.0/8", "10.0.0.0/8/1", "1.2.3.4/+", "::1"].allSatisfy { parseCIDR($0) == nil })
check(isDomainName("collega.co.id") && isDomainName("a-b.example"))
check(!["", "-a.com", "a..b", "a.com\nremove State:/Network/Global/DNS", "a b", "ü.com", String(repeating: "a", count: 64) + ".com"]
        .contains(where: isDomainName))
var profile = Profile()
profile.server = "vpn.example.com"
check(profile.problem == nil && profile.isFullTunnel)
profile.routes = "192.168.212.0/24, 10.0.0.0/8"
profile.dnsDomains = "collega.co.id"
check(profile.problem == nil && !profile.isFullTunnel && profile.routeList.count == 2)
profile.dnsDomains = "x.com\nset State:/Network/Global/DNS"
check(profile.problem != nil)
profile.dnsDomains = ""
profile.routes = "0.0.0.0/0"
check(profile.problem != nil)

// Profiles saved by older versions lack newer keys; they must still load with defaults
let old = try! JSONDecoder().decode(Profile.self, from: Data(#"{"name":"Old","server":"vpn.example.com","port":8783}"#.utf8))
check(old.name == "Old" && old.port == 8783 && old.autoReconnect && !old.killSwitch && old.pinnedCert == nil)

// Split tunnel accepts hostnames; an all-numeric name would resolve as an address, so it is rejected
profile.routes = "192.168.212.0/24, intranet.example.com"
check(profile.problem == nil && profile.routeSubnets == ["192.168.212.0/24"] && profile.routeHosts == ["intranet.example.com"])
for bad in ["10.1.2", "intra_net.example", "-bad.example", "a.com;reboot"] {
    profile.routes = bad
    check(profile.problem != nil, bad)
}
profile.routes = ""

// Health check target: host or host:port, default 443
profile.healthCheck = "intranet.example.com"
check(profile.healthTarget?.host == "intranet.example.com" && profile.healthTarget?.port == 443 && profile.problem == nil)
profile.healthCheck = "10.0.0.5:8080"
check(profile.healthTarget?.host == "10.0.0.5" && profile.healthTarget?.port == 8080)
for bad in ["host:0", "host:99999", "a:b:c", "10.0.0.0/8", "x;y"] {
    profile.healthCheck = bad
    check(profile.healthTarget == nil && profile.problem != nil, bad)
}
profile.healthCheck = ""

// Pinned certificates (also from imported files) must be SHA-256 hex, with or without colons
profile.pinnedCert = String(repeating: "ab", count: 32)
check(profile.problem == nil)
profile.pinnedCert = Array(repeating: "AB", count: 32).joined(separator: ":")
check(profile.problem == nil)
for bad in ["", "abc", String(repeating: "zz", count: 32)] {
    profile.pinnedCert = bad
    check(profile.problem != nil, bad)
}
profile.pinnedCert = nil

// Wi-Fi names for per-network auto-connect keep their spaces; only commas separate them
profile.wifiNetworks = " Home Wi-Fi , iPhone,, Kantor 5G "
check(profile.wifiList == ["Home Wi-Fi", "iPhone", "Kantor 5G"])
profile.wifiNetworks = ""

// Bypass list: full tunnel only, subnets or hostnames, never together with the kill switch
profile.bypass = "162.159.128.0/19, discord.media"
check(profile.problem == nil && profile.bypassSubnets == ["162.159.128.0/19"] && profile.bypassHosts == ["discord.media"])
profile.killSwitch = true
check(profile.problem != nil, "kill switch + bypass")
profile.killSwitch = false
for bad in ["10.1.2", "a.com;reboot", "10.0.0.0/33"] {
    profile.bypass = bad
    check(profile.problem != nil, bad)
}
profile.routes = "192.168.212.0/24"
profile.bypass = "a.com;reboot" // ignored in split tunnel, where everything else already bypasses the VPN
check(profile.bypassList.isEmpty && profile.problem == nil)
profile.routes = ""
profile.bypass = ""

// Server certificate expiry: notAfter Dec 27 22:48:23 2026 GMT
let certDER = Data(base64Encoded: "MIIB/DCCAaICCQC4EwBrm+xH/TAKBggqhkjOPQQDAjAMMQowCAYDVQQDDAF0MB4XDTI2MTEyNzIyNDgyM1oXDTI2MTIyNzIyNDgyM1owDDEKMAgGA1UEAwwBdDCCAUswggEDBgcqhkjOPQIBMIH3AgEBMCwGByqGSM49AQECIQD/////AAAAAQAAAAAAAAAAAAAAAP///////////////zBbBCD/////AAAAAQAAAAAAAAAAAAAAAP///////////////AQgWsY12Ko6k+ez671VdpiGvGUdBrDMU7D2O848PifSYEsDFQDEnTYIhucEk2pmeOETnSa3gZ9+kARBBGsX0fLhLEJH+Lzm5WOkQPJ3A32BLeszoPShOUXYmMKWT+NC4v4af5uO5+tKfA+eFivOM1drMV7Oy7ZAaDe/UfUCIQD/////AAAAAP//////////vOb6racXnoTzucrC/GMlUQIBAQNCAARMuSmp6Ix0ddOM8NSHhxHP0No3Qj78D2HtpvBjj+8TAJ76X5yWCoLj9Yi9o246GgGs3KQ6j3RUDBhQCJ52ai9VMAoGCCqGSM49BAMCA0gAMEUCIDECZXNAKxM3tGUndlab8WBNjDb9N+z+0NahLWQUJ1trAiEA/ina27JS1oKWOY3P8r1aPD9jLfI96n+GvDckAU9y18M=")!
let testCert = SecCertificateCreateWithData(nil, certDER as CFData)!
check(certNotAfter(testCert) == 1798411703, "certNotAfter \(String(describing: certNotAfter(testCert)))")

md4Vectors()
msChapV2Vectors()
sstpFraming()
pppNegotiation()
print(failures == 0 ? "all checks passed" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
