import Foundation

// GUI <-> daemon protocol: newline-delimited JSON over a unix socket.
// GUI sends Request; daemon sends Event (status and/or log lines) on connect and on every change.

public let daemonSocketPath = ProcessInfo.processInfo.environment["SSTPD_SOCKET"] ?? "/var/run/sekisho.sock"
/// Bump when Event/Status or helper behavior change, so the GUI asks to update the installed helper.
public let protocolVersion = 8

public struct Profile: Codable, Equatable, Identifiable {
    public var id = UUID()
    public var name = "VPN"
    public var server = ""
    public var port: UInt16 = 443
    public var username = ""
    public var password = "" // travels to the daemon only; the GUI stores it in the Keychain
    /// SHA-256 (hex) of a server certificate the user chose to trust although macOS does not (pinned: others are refused).
    public var pinnedCert: String?
    /// Split tunnel: subnets or hostnames sent through the VPN ("192.168.212.0/24, intranet.example.com"). Empty = all traffic.
    /// Hostnames are resolved by the VPN's DNS and routed by address.
    public var routes = ""
    /// Split DNS (split tunnel only): domains answered by the VPN's DNS servers ("collega.co.id").
    public var dnsDomains = ""
    public var killSwitch = false // full tunnel only
    public var autoReconnect = true
    /// Internal "host" or "host:port" (default 443) that must accept TCP connections through the tunnel. Empty = no check.
    public var healthCheck = ""
    /// false: the password is not kept in the Keychain but asked for on every connect (shared Macs, office policy)
    public var savePassword = true
    /// Ask for a one-time code on connect and send it right after the password (RADIUS servers with OTP)
    public var askCode = false
    /// Wi-Fi names (comma-separated) on which auto-connect uses this profile instead of the selected one
    public var wifiNetworks = ""

    public init() {}

    /// Missing keys take their defaults: the synthesized decoder rejects them, and a field added in a later version
    /// would then make every saved profile (and older shared files) fail to load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Profile()
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? d.id
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? d.name
        server = try c.decodeIfPresent(String.self, forKey: .server) ?? d.server
        port = try c.decodeIfPresent(UInt16.self, forKey: .port) ?? d.port
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? d.username
        password = try c.decodeIfPresent(String.self, forKey: .password) ?? d.password
        pinnedCert = try c.decodeIfPresent(String.self, forKey: .pinnedCert)
        routes = try c.decodeIfPresent(String.self, forKey: .routes) ?? d.routes
        dnsDomains = try c.decodeIfPresent(String.self, forKey: .dnsDomains) ?? d.dnsDomains
        killSwitch = try c.decodeIfPresent(Bool.self, forKey: .killSwitch) ?? d.killSwitch
        autoReconnect = try c.decodeIfPresent(Bool.self, forKey: .autoReconnect) ?? d.autoReconnect
        healthCheck = try c.decodeIfPresent(String.self, forKey: .healthCheck) ?? d.healthCheck
        savePassword = try c.decodeIfPresent(Bool.self, forKey: .savePassword) ?? d.savePassword
        askCode = try c.decodeIfPresent(Bool.self, forKey: .askCode) ?? d.askCode
        wifiNetworks = try c.decodeIfPresent(String.self, forKey: .wifiNetworks) ?? d.wifiNetworks
    }

    /// Wi-Fi names may contain spaces, so only commas separate them
    public var wifiList: [String] {
        wifiNetworks.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    public var routeList: [String] { tokens(routes) }
    public var routeSubnets: [String] { routeList.compactMap(parseCIDR) }
    public var routeHosts: [String] { routeList.filter { parseCIDR($0) == nil } }
    public var domainList: [String] { tokens(dnsDomains) }
    public var isFullTunnel: Bool { routeList.isEmpty }

    public var healthTarget: (host: String, port: UInt16)? {
        let parts = healthCheck.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard (1...2).contains(parts.count), isHostname(parts[0]) || parseCIDR(parts[0]) == parts[0] + "/32",
              let port = parts.count == 2 ? UInt16(parts[1]) : 443, port > 0 else { return nil }
        return (parts[0], port)
    }

    /// Checked by the root daemon (trust boundary): routes and domains end up in `route` and `scutil` input.
    public var problem: String? {
        if server.isEmpty || server.contains(where: { $0.isWhitespace || $0 == "/" }) { return "Server is required" }
        if port == 0 { return "Port is required" }
        if let bad = routeList.first(where: { parseCIDR($0) == nil && !isHostname($0) }) { return "Invalid subnet or hostname: \(bad)" }
        if let bad = domainList.first(where: { !isDomainName($0) }) { return "Invalid domain: \(bad)" }
        if !healthCheck.trimmingCharacters(in: .whitespaces).isEmpty, healthTarget == nil { return "Invalid health check: \(healthCheck)" }
        if let pin = pinnedCert?.replacingOccurrences(of: ":", with: ""), pin.count != 64 || !pin.allSatisfy(\.isHexDigit) {
            return "Invalid pinned certificate"
        }
        return nil
    }
}

private func tokens(_ s: String) -> [String] {
    s.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
}

/// "10.1.0.0/16" or "10.1.2.3" (as /32) -> "10.1.0.0/16"; nil unless a strict dotted quad with prefix 1...32.
public func parseCIDR(_ s: String) -> String? {
    let parts = s.split(separator: "/", omittingEmptySubsequences: false)
    var a = in_addr()
    guard parts.count <= 2, inet_pton(AF_INET, String(parts[0]), &a) == 1 else { return nil }
    guard let prefix = parts.count == 2 ? Int(parts[1]) : 32, (1...32).contains(prefix) else { return nil }
    return "\(parts[0])/\(prefix)"
}

public func isDomainName(_ s: String) -> Bool {
    s.count <= 253 && s.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { l in
        (1...63).contains(l.count) && l.first != "-" && l.last != "-"
            && l.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }
}

/// A domain name whose last label has a letter: "10.1.2" would otherwise pass and resolve as the address 10.1.0.2.
public func isHostname(_ s: String) -> Bool {
    isDomainName(s) && s.split(separator: ".").last.map { $0.contains(where: \.isLetter) } == true
}

public enum State: String, Codable {
    case disconnected, connecting, connected, disconnecting
}

public struct Status: Codable, Equatable {
    public var state: State = .disconnected
    public var message = ""
    public var interface: String?
    public var localIP: String?
    public var dns: [String] = []
    public var since: Double? // epoch seconds when connected
    public var rxBytes: UInt64 = 0, txBytes: UInt64 = 0 // IP bytes through the tunnel
    public var rxRate: Double = 0, txRate: Double = 0 // bytes per second
    public var profileName: String?
    public var untrustedCert: String? // SHA-256 of a server certificate macOS rejected, for the GUI to offer pinning
    public var latency: Double? // ms, round trip of the last SSTP echo to the server
    public var reachable: Bool? // health check result; nil = none configured or not checked yet
    public var killSwitchPausedUntil: Double? // epoch seconds; kill switch off so a Wi-Fi login page can load
    public var certExpires: Double? // epoch seconds: notAfter of the server certificate

    public init() {}
}

/// One connected stretch: from "connected" until the tunnel went down on its own (dropped) or was disconnected.
public struct Session: Codable, Identifiable, Equatable {
    public var id = UUID()
    public var profile: String
    public var start: Double, end: Double // epoch seconds
    public var rx: UInt64, tx: UInt64
    public var dropped: Bool
    public var reason: String

    public init(profile: String, start: Double, end: Double, rx: UInt64, tx: UInt64, dropped: Bool, reason: String) {
        self.profile = profile
        self.start = start
        self.end = end
        self.rx = rx
        self.tx = tx
        self.dropped = dropped
        self.reason = reason
    }
}

public struct Event: Codable {
    public var v: Int? // nil from helpers older than protocolVersion 2
    public var status: Status?
    public var log: [String]?
    public var sessions: [Session]? // newest first; on connect and whenever the history changes

    public init(status: Status? = nil, log: [String]? = nil, sessions: [Session]? = nil) {
        v = protocolVersion
        self.status = status
        self.log = log
        self.sessions = sessions
    }
}

public struct Request: Codable {
    public enum Cmd: String, Codable { case connect, disconnect, status, pauseKillSwitch, clearHistory }
    public var cmd: Cmd
    public var profile: Profile?

    public init(_ cmd: Cmd, profile: Profile? = nil) {
        self.cmd = cmd
        self.profile = profile
    }
}

public func encodeLine<T: Encodable>(_ value: T) -> [UInt8] {
    (try? JSONEncoder().encode(value)).map { Array($0) + [10] } ?? []
}

public struct LineBuffer {
    private var buf: [UInt8] = []
    public init() {}

    public mutating func feed(_ bytes: [UInt8]) -> [Data] {
        buf += bytes
        var out: [Data] = []
        while let i = buf.firstIndex(of: 10) {
            out.append(Data(buf[..<i]))
            buf.removeSubrange(0...i)
        }
        if buf.count > 1 << 20 { buf.removeAll() } // peer never sends a newline
        return out
    }
}

public func unixAddress(_ path: String) -> sockaddr_un {
    var a = sockaddr_un()
    a.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    a.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &a.sun_path) { p in
        for (i, b) in path.utf8.prefix(p.count - 1).enumerated() { p[i] = b }
    }
    return a
}

/// Receives every log line (the daemon forwards them to the GUI).
nonisolated(unsafe) public var logSink: ((String) -> Void)?

private let logTime: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f
}()

public func log(_ s: String) {
    let line = "\(logTime.string(from: Date())) \(s)"
    fputs(line + "\n", stderr)
    logSink?(line)
}
