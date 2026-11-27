import Darwin
import Foundation

struct SysError: Error, CustomStringConvertible {
    let description: String
}

@discardableResult
func run(_ path: String, _ args: [String], input: String? = nil) throws -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let out = Pipe(), inp = Pipe()
    p.standardOutput = out
    p.standardError = out
    if input != nil { p.standardInput = inp }
    try p.run()
    if let input {
        inp.fileHandleForWriting.write(Data(input.utf8))
        try? inp.fileHandleForWriting.close()
    }
    let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    p.waitUntilExit()
    guard p.terminationStatus == 0 else {
        throw SysError(description: "\(path) \(args.joined(separator: " ")): \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
    return text
}

func resolveIPv4(_ host: String) -> String? {
    var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                         ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
    var res: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, nil, &hints, &res) == 0, let ai = res else { return nil }
    defer { freeaddrinfo(res) }
    var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
    return ai.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
        var addr = sin.pointee.sin_addr
        return inet_ntop(AF_INET, &addr, &buf, socklen_t(buf.count)).map { String(cString: $0) }
    }
}

/// Current route to `ip`: gateway (nil if on-link) and outgoing interface.
func routeTo(_ ip: String) throws -> (gateway: String?, interface: String) {
    var gw: String?, iface: String?
    for line in try run("/sbin/route", ["-n", "get", ip]).split(separator: "\n") {
        let kv = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard kv.count == 2 else { continue }
        if kv[0] == "gateway" { gw = kv[1] }
        if kv[0] == "interface" { iface = kv[1] }
    }
    guard let iface else { throw SysError(description: "no route to \(ip)") }
    return (gw, iface)
}

/// Opens a utun interface (no entitlement needed, but requires root). Non-blocking fd.
/// Packets carry a 4-byte address-family header in both directions.
func openUtun() throws -> (fd: Int32, name: String) {
    func fail(_ what: String) -> SysError { SysError(description: "\(what): \(String(cString: strerror(errno)))") }

    let fd = socket(PF_SYSTEM, SOCK_DGRAM, SYSPROTO_CONTROL)
    guard fd >= 0 else { throw fail("socket(PF_SYSTEM)") }

    var info = ctl_info()
    withUnsafeMutableBytes(of: &info.ctl_name) { p in
        for (i, b) in "com.apple.net.utun_control".utf8.enumerated() { p[i] = b }
    }
    let CTLIOCGINFO: UInt = 0xC064_4E03 // _IOWR('N', 3, struct ctl_info); macro not importable
    guard ioctl(fd, CTLIOCGINFO, &info) == 0 else { close(fd); throw fail("CTLIOCGINFO") }

    var addr = sockaddr_ctl()
    addr.sc_len = UInt8(MemoryLayout<sockaddr_ctl>.size)
    addr.sc_family = UInt8(AF_SYSTEM)
    addr.ss_sysaddr = UInt16(AF_SYS_CONTROL)
    addr.sc_id = info.ctl_id
    addr.sc_unit = 0 // kernel picks the next free utunN
    let rc = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_ctl>.size)) }
    }
    guard rc == 0 else { close(fd); throw fail("connect utun_control") }

    var name = [CChar](repeating: 0, count: 32)
    var len = socklen_t(name.count)
    guard getsockopt(fd, SYSPROTO_CONTROL, 2 /* UTUN_OPT_IFNAME */, &name, &len) == 0 else { close(fd); throw fail("UTUN_OPT_IFNAME") }
    _ = fcntl(fd, F_SETFL, O_NONBLOCK)
    return (fd, String(cString: name))
}

/// mDNSResponder keeps answers (including negative ones) for their TTL even after the resolver changes;
/// flush so names resolve through the new DNS servers right away.
public func flushDNSCache() {
    _ = try? run("/usr/bin/dscacheutil", ["-flushcache"])
    _ = try? run("/usr/bin/killall", ["-HUP", "mDNSResponder"])
}

/// Commands that revert system changes (routes, DNS keys, pf), journaled to disk so a daemon restarted
/// after a crash can still revert them. `scutil set` keys and pf rules outlive the process that made them.
final class UndoLog {
    private struct Cmd: Codable { let path: String; let args: [String]; let input: String? }
    private let file: String
    private var cmds: [Cmd] = []

    init(file: String) { self.file = file }

    func add(_ path: String, _ args: [String], input: String? = nil) {
        cmds.append(Cmd(path: path, args: args, input: input))
        try? JSONEncoder().encode(cmds).write(to: URL(fileURLWithPath: file), options: .atomic)
    }

    /// Runs everything newest-first (loading the journal if this instance has none) and clears it.
    @discardableResult func runAll() -> Bool {
        if cmds.isEmpty, let d = FileManager.default.contents(atPath: file) {
            cmds = (try? JSONDecoder().decode([Cmd].self, from: d)) ?? []
        }
        let had = !cmds.isEmpty
        for c in cmds.reversed() { _ = try? run(c.path, c.args, input: c.input) }
        cmds = []
        unlink(file)
        return had
    }
}

/// Reverts what a previous daemon instance left behind when it died without cleaning up.
public func recoverAfterCrash() {
    var had = false
    // also the journals of the helper from before the Sekisho rename, should it have died with changes in place
    let journals = [Tunnel.undoFile, KillSwitch.undoFile, "/var/run/sstpd.tunnel.undo", "/var/run/sstpd.killswitch.undo"]
    for f in journals { had = UndoLog(file: f).runAll() || had }
    if had {
        flushDNSCache()
        log("Reverted network changes left by a previous run")
    }
}

/// pf rules in a sub-anchor of "com.apple/*", which macOS's stock /etc/pf.conf evaluates; pf.conf stays untouched.
enum PF {
    static func load(_ anchor: String, _ rules: String, undo: UndoLog) throws {
        try reload(anchor, rules)
        undo.add("/sbin/pfctl", ["-a", anchor, "-F", "all"])
        // -E counts a reference so pf stays enabled while we need it; -X releases only our reference
        let out = try run("/sbin/pfctl", ["-E"])
        if let token = out.components(separatedBy: "Token : ").dropFirst().first?.prefix(while: \.isNumber), !token.isEmpty {
            undo.add("/sbin/pfctl", ["-X", String(token)])
        }
    }

    static func reload(_ anchor: String, _ rules: String) throws {
        try run("/sbin/pfctl", ["-a", anchor, "-f", "-"], input: rules)
    }

    /// Full tunnel: IPv6 is not tunnelled, so block it (link-local stays for AirDrop/Continuity) instead of leaking it.
    static let blockIPv6 = """
    pass out quick on lo0 all
    pass out quick inet6 from any to { fe80::/10, ff00::/8 }
    block return out quick inet6 all

    """

    /// Kill switch: only the tunnel, the VPN server itself, the local network (incl. its DNS/DHCP) and link-local IPv6.
    static func killSwitchRules(server: String, port: UInt16, tunnel: String?) -> String {
        """
        pass out quick on lo0 all
        \(tunnel.map { "pass out quick on \($0) all" } ?? "")
        pass out quick inet proto tcp from any to \(server) port \(port)
        pass out quick inet from any to { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, 224.0.0.0/4, 255.255.255.255 }
        pass out quick inet6 from any to { fe80::/10, ff00::/8 }
        block return out quick all

        """
    }
}

/// Blocks traffic outside the tunnel for the whole session: it stays through reconnects and is removed only
/// when the user disconnects (or the daemon stops).
public final class KillSwitch {
    static let undoFile = "/var/run/sekisho.killswitch.undo"
    private static let anchor = "com.apple/sekisho.killswitch"
    private let undo = UndoLog(file: KillSwitch.undoFile)
    private var active = false

    public init() {}

    /// `tunnel` nil while reconnecting: then only the server and the local network are reachable.
    public func update(server: String, port: UInt16, tunnel: String?) {
        let rules = PF.killSwitchRules(server: server, port: port, tunnel: tunnel)
        do {
            if active { try PF.reload(Self.anchor, rules) } else { try PF.load(Self.anchor, rules, undo: undo) }
            if !active { log("Kill switch on") }
            active = true
        } catch {
            log("Kill switch failed: \(error)")
        }
    }

    public func disable() {
        guard active || FileManager.default.fileExists(atPath: Self.undoFile) else { return }
        undo.runAll()
        if active { log("Kill switch off") }
        active = false
    }
}
