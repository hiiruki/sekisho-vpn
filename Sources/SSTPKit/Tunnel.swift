import CryptoKit
import Foundation
import Network
import Security

/// One VPN connection attempt: TLS -> SSTP -> PPP -> utun. All state and callbacks live on `queue`.
public final class Tunnel {
    static let undoFile = "/var/run/sekisho.tunnel.undo"

    public var onStatus: (Status) -> Void = { _ in }
    /// `message` nil = ended on request. `retryable` false = reconnecting would fail the same way (auth, certificate).
    public var onEnded: (_ message: String?, _ retryable: Bool) -> Void = { _, _ in }
    /// Address actually used; a reconnect falls back to it when DNS is unavailable (e.g. behind the kill switch).
    public private(set) var serverIP: String?
    /// SHA-256 of the server certificate when macOS rejected it (and it is not pinned).
    public private(set) var untrustedCert: String?

    private let profile: Profile
    private let q: DispatchQueue
    private let fallbackIP: String?
    private var status = Status()
    private var ended = false

    private var conn: NWConnection?
    private var rx: [UInt8] = []
    private var httpDone = false
    private var serverCert: [UInt8] = []
    private var nonce: [UInt8] = []
    private var hashBitmask: UInt8 = 2
    private var ppp: PPP?

    private var utunFD: Int32 = -1
    private var utunSource: DispatchSourceRead?
    private var utunBuf = [UInt8](repeating: 0, count: 4096)
    private let undo = UndoLog(file: Tunnel.undoFile)
    private var dnsApplied = false

    private var tick: DispatchSourceTimer?
    private var statsTimer: DispatchSourceTimer?
    private let started = Date()
    private var lastRx = Date()
    private var rxBytes: UInt64 = 0, txBytes: UInt64 = 0 // IP bytes through the tunnel
    private var lastSample = Date()
    private var echoSent: Date? // pending SSTP echo, for the latency readout
    private var ticks = 0
    private var routedHosts: Set<String> = [] // addresses of split-tunnel hostnames already routed
    private var unresolvedHosts: Set<String> = [] // retried every tick: the VPN's DNS can be slow right after connecting
    private var resolving = false
    private var healthFailures = 0

    private static let serviceKey = "State:/Network/Service/Sekisho"
    private static let ipv6Anchor = "com.apple/sekisho.ipv6"

    public init(profile: Profile, queue: DispatchQueue, fallbackIP: String? = nil) {
        self.profile = profile
        self.q = queue
        self.fallbackIP = fallbackIP
        status.profileName = profile.name
    }

    public func start() {
        set(.connecting, "Resolving \(profile.server)…")
        let host = profile.server, fallback = fallbackIP
        DispatchQueue.global().async { [weak self] in
            let ip = resolveIPv4(host)
            self?.q.async {
                guard let self else { return }
                if let ip {
                    self.connect(ip)
                } else if let fallback {
                    log("Cannot resolve \(host); using last known address \(fallback)")
                    self.connect(fallback)
                } else {
                    self.finish("Cannot resolve \(host)")
                }
            }
        }
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + 10, repeating: 10)
        t.setEventHandler { [weak self] in self?.onTick() }
        t.resume()
        tick = t
    }

    public func stop() {
        q.async { [self] in
            guard !ended else { return }
            set(.disconnecting, "Disconnecting…")
            guard httpDone else { return finish(nil) }
            send(SSTP.control(SSTP.Msg.disconnect, [(2, [UInt8](repeating: 0, count: 8))])) { [weak self] in self?.finish(nil) }
            q.asyncAfter(deadline: .now() + 2) { [weak self] in self?.finish(nil) }
        }
    }

    // MARK: connection

    private func set(_ s: State, _ message: String) {
        status.state = s
        status.message = message
        log(message)
        onStatus(status)
    }

    private func connect(_ ip: String) {
        guard !ended, let port = NWEndpoint.Port(rawValue: profile.port) else { return finish("Invalid port", retryable: false) }
        serverIP = ip
        set(.connecting, "Connecting to \(ip):\(profile.port)…")

        let tls = NWProtocolTLS.Options()
        let sec = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)
        if resolveIPv4Literal(profile.server) == nil { sec_protocol_options_set_tls_server_name(sec, profile.server) }
        sec_protocol_options_set_verify_block(sec, { [weak self] _, trust, complete in
            guard let self else { return complete(false) }
            let t = sec_trust_copy_ref(trust).takeRetainedValue()
            guard let leaf = (SecTrustCopyCertificateChain(t) as? [SecCertificate])?.first else { return complete(false) }
            let der = SecCertificateCopyData(leaf) as Data
            self.serverCert = Array(der) // the Crypto Binding needs the exact cert the server presented
            self.status.certExpires = certNotAfter(leaf)
            SecTrustSetPolicies(t, SecPolicyCreateSSL(true, self.profile.server as CFString))
            if SecTrustEvaluateWithError(t, nil) { return complete(true) }
            let fingerprint = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
            let pinned = self.profile.pinnedCert?.lowercased().replacingOccurrences(of: ":", with: "")
            if fingerprint == pinned { return complete(true) }
            self.untrustedCert = fingerprint
            complete(false)
        }, q)

        let c = NWConnection(host: NWEndpoint.Host(ip), port: port, using: NWParameters(tls: tls))
        c.stateUpdateHandler = { [weak self] s in
            guard let self else { return }
            switch s {
            case .ready: self.onReady()
            case .failed(let e), .waiting(let e):
                if let fp = self.untrustedCert {
                    let why = self.profile.pinnedCert == nil ? "is not trusted by macOS" : "does not match the pinned certificate"
                    self.finish("Server certificate \(why) (SHA-256 \(fp.prefix(16))…)", retryable: false)
                } else {
                    self.finish("Cannot reach server: \(e)")
                }
            default: break
            }
        }
        conn = c
        c.start(queue: q)
    }

    private func onReady() {
        guard !ended else { return }
        set(.connecting, "Negotiating SSTP…")
        let host = profile.port == 443 ? profile.server : "\(profile.server):\(profile.port)"
        let req = "SSTP_DUPLEX_POST /sra_{BA195980-CD49-458b-9E23-C84EE0ADCD75}/ HTTP/1.1\r\n"
            + "Host: \(host)\r\nContent-Length: 18446744073709551615\r\n"
            + "SSTPCORRELATIONID: {\(UUID().uuidString)}\r\n\r\n"
        send(Array(req.utf8))
        receive()
    }

    private func send(_ b: [UInt8], then done: (() -> Void)? = nil) {
        conn?.send(content: Data(b), completion: .contentProcessed { [weak self] err in
            if let err { self?.finish("Send failed: \(err)") }
            done?()
        })
    }

    private func receive() {
        conn?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self, !self.ended else { return }
            if let data, !data.isEmpty {
                self.rx += data
                self.lastRx = Date()
                self.process()
            }
            if let error { return self.finish("Connection error: \(error)") }
            if isComplete { return self.finish("Server closed the connection") }
            self.receive()
        }
    }

    private func process() {
        if !httpDone {
            guard let end = rx.indices.dropLast(3).first(where: { rx[$0] == 13 && rx[$0 + 1] == 10 && rx[$0 + 2] == 13 && rx[$0 + 3] == 10 }) else { return }
            let head = String(decoding: rx[..<end], as: UTF8.self)
            rx.removeFirst(end + 4)
            let line = head.components(separatedBy: "\r\n").first ?? ""
            guard line.hasPrefix("HTTP/1.1 200") else { return finish("Server rejected SSTP handshake: \(line)") }
            httpDone = true
            send(SSTP.control(SSTP.Msg.connectRequest, [(1, [0, 1])])) // encapsulated protocol: PPP
        }
        while !ended, let pkt = SSTP.parse(&rx) { handle(pkt) }
    }

    private func handle(_ pkt: SSTP.Packet) {
        switch pkt {
        case .invalid:
            finish("Malformed SSTP packet")
        case .data(let d):
            ppp?.receive(d)
        case .control(let type, let attrs):
            switch type {
            case SSTP.Msg.connectAck:
                guard let v = attrs[4], v.count >= 36 else { return finish("Malformed Call Connect Ack") }
                hashBitmask = v[3] & 2 != 0 ? 2 : 1
                nonce = Array(v[4..<36])
                startPPP()
            case SSTP.Msg.connectNak: finish("Server refused the SSTP call")
            case SSTP.Msg.abort: finish("Server aborted the call")
            case SSTP.Msg.disconnect:
                send(SSTP.control(SSTP.Msg.disconnectAck))
                finish("Server closed the session")
            case SSTP.Msg.disconnectAck: finish(nil)
            case SSTP.Msg.echoRequest: send(SSTP.control(SSTP.Msg.echoResponse))
            case SSTP.Msg.echoResponse:
                if let t = echoSent { status.latency = Date().timeIntervalSince(t) * 1000 } // published with the next rate sample
                echoSent = nil
            default: break
            }
        }
    }

    /// Every 10 s: keepalive, plus dead-peer detection (e.g. after sleep or a Wi-Fi change the TCP socket can hang silently).
    private func onTick() {
        guard !ended else { return }
        if status.state == .connecting, Date().timeIntervalSince(started) > 45 { return finish("Connection timed out") }
        guard httpDone else { return }
        sendEcho()
        ticks += 1
        // every 5 min: follow DNS changes of split-tunnel hostnames; every tick while one could not be resolved yet
        if ticks % 30 == 0 || !unresolvedHosts.isEmpty { routeHosts() }
        if ticks % 3 == 0 { checkHealth() }
        if Date().timeIntervalSince(lastRx) > 45 { finish("Server stopped responding") }
    }

    private func sendEcho() {
        echoSent = Date()
        send(SSTP.control(SSTP.Msg.echoRequest))
    }

    // MARK: PPP + network

    private func startPPP() {
        set(.connecting, "Authenticating…")
        let p = PPP(username: profile.username, password: profile.password, queue: q)
        p.send = { [weak self] in self?.send(SSTP.data($0)) }
        p.onAuthenticated = { [weak self] hlak in
            guard let self else { return }
            guard !self.serverCert.isEmpty else { return self.finish("No server certificate for crypto binding") }
            log("Authenticated; sending crypto binding")
            self.send(SSTP.callConnected(nonce: self.nonce, cert: self.serverCert, bitmask: self.hashBitmask, hlak: hlak))
        }
        p.onUp = { [weak self] in self?.bringUp($0) }
        p.onIP = { [weak self] in self?.writeUtun($0) }
        p.onFail = { [weak self] in self?.finish($0) }
        p.onAuthFailed = { [weak self] in self?.finish($0, retryable: false) }
        ppp = p
        p.start()
    }

    /// Runs a system command and journals how to revert it.
    private func sys(_ path: String, _ args: [String], input: String? = nil, undo u: [String], undoInput: String? = nil) throws {
        try run(path, args, input: input)
        undo.add(path, u, input: undoInput)
    }

    private func bringUp(_ cfg: PPP.IPConfig) {
        func str(_ a: [UInt8]) -> String { a.map { String($0) }.joined(separator: ".") }
        let local = str(cfg.local), remote = str(cfg.remote)
        // macOS upgrades a resolver to DNS-over-HTTPS when any of its servers advertises it (DDR: 8.8.8.8 -> dns.google),
        // and that public resolver then answers every lookup without seeing internal names. Keep the VPN's private
        // servers when it offers any.
        let privateDNS = cfg.dns.filter(isPrivateIPv4)
        let dns = (privateDNS.isEmpty ? cfg.dns : privateDNS).map(str)
        if dns.count < cfg.dns.count {
            log("Ignoring public DNS \(cfg.dns.filter { !isPrivateIPv4($0) }.map(str).joined(separator: ", ")) from server")
        }
        do {
            let (fd, name) = try openUtun()
            utunFD = fd
            let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: q)
            src.setEventHandler { [weak self] in self?.pumpUtun() }
            src.setCancelHandler { close(fd) }
            src.resume()
            utunSource = src

            try run("/sbin/ifconfig", [name, "inet", local, remote, "netmask", "255.255.255.255", "mtu", String(cfg.mtu), "up"])

            // keep the tunnel's own TLS traffic off the tunnel
            if let ip = serverIP, let r = try? routeTo(ip) {
                try? sys("/sbin/route", ["-n", "add", "-host", ip] + (r.gateway.map { [$0] } ?? ["-interface", r.interface]),
                         undo: ["-n", "delete", "-host", ip])
            }

            if profile.isFullTunnel {
                for net in ["0.0.0.0/1", "128.0.0.0/1"] { // beats the default route without replacing it
                    try sys("/sbin/route", ["-n", "add", "-net", net, "-interface", name],
                            undo: ["-n", "delete", "-net", net, "-interface", name])
                }
                do { try PF.load(Self.ipv6Anchor, PF.blockIPv6, undo: undo) } catch { log("IPv6 leak protection failed: \(error)") }
            } else {
                for net in profile.routeSubnets {
                    try sys("/sbin/route", ["-n", "add", "-net", net, "-interface", name],
                            undo: ["-n", "delete", "-net", net, "-interface", name])
                }
            }

            try applyDNS(dns, interface: name, local: local)

            let mode = profile.isFullTunnel ? "all traffic" : "split: \(profile.routeList.joined(separator: ", "))"
            log("\(name): \(local) → \(remote), mtu \(cfg.mtu), \(mode), DNS \(dnsApplied ? dns.joined(separator: ", ") : "unchanged")")

            status.interface = name
            status.localIP = local
            status.dns = dnsApplied ? dns : []
            status.since = Date().timeIntervalSince1970
            set(.connected, "Connected")

            let t = DispatchSource.makeTimerSource(queue: q)
            t.schedule(deadline: .now() + 1, repeating: 1)
            t.setEventHandler { [weak self] in self?.sampleRates() }
            t.resume()
            statsTimer = t
            sendEcho() // a latency reading right away instead of after the first 10 s tick
            routeHosts()
            q.asyncAfter(deadline: .now() + 3) { [weak self] in self?.checkHealth() } // after hostname routes are in
        } catch {
            finish("Network setup failed: \(error)")
        }
    }

    private func applyDNS(_ dns: [String], interface name: String, local: String) throws {
        guard !dns.isEmpty else { return }
        let servers = "d.init\nd.add ServerAddresses * \(dns.joined(separator: " "))\n"
        let script: String
        if profile.isFullTunnel {
            // A "supplemental" resolver without domains is not used as the default one, so publish the tunnel as
            // the primary network service (same as openconnect's vpnc-script): its DNS then answers every name.
            script = servers + "set \(Self.serviceKey)/DNS\n"
                + "d.init\nd.add Addresses * \(local)\nd.add SubnetMasks * 255.255.255.255\nd.add InterfaceName \(name)\n"
                + "d.add Router \(local)\nd.add OverridePrimary # 1\nset \(Self.serviceKey)/IPv4\n"
        } else if !(profile.domainList + profile.routeHosts).isEmpty {
            // split DNS: only these domains (and their subdomains) go to the VPN's DNS servers; split-tunnel hostnames
            // too, so they resolve to their internal addresses
            script = servers + "d.add SupplementalMatchDomains * \((profile.domainList + profile.routeHosts).joined(separator: " "))\n"
                + "d.add SupplementalMatchDomainsNoSearch # 1\nset \(Self.serviceKey)/DNS\n"
        } else {
            return // split tunnel without DNS domains: keep the system DNS
        }
        try sys("/usr/sbin/scutil", [], input: script, undo: [],
                undoInput: "remove \(Self.serviceKey)/DNS\nremove \(Self.serviceKey)/IPv4\n")
        dnsApplied = true
        flushDNSCache()
    }

    /// Split-tunnel hostnames: resolve (through the VPN's DNS, see applyDNS) and route each new address into the tunnel.
    /// Addresses that disappear keep their route until disconnect.
    private func routeHosts() {
        let hosts = profile.routeHosts, server = serverIP
        guard !hosts.isEmpty, !resolving, let name = status.interface else { return }
        resolving = true // a lookup can take 30 s to time out, longer than a tick
        DispatchQueue.global().async { [weak self] in
            let resolved = hosts.map { ($0, resolveAllIPv4($0)) }
            self?.q.async {
                guard let self, !self.ended else { return }
                self.resolving = false
                for (host, ips) in resolved {
                    if ips.isEmpty {
                        if self.unresolvedHosts.insert(host).inserted { log("Cannot resolve \(host); retrying every 10 s") }
                        continue
                    }
                    self.unresolvedHosts.remove(host)
                    // never the VPN server itself: its route must stay outside the tunnel
                    let new = ips.filter { $0 != server && !self.routedHosts.contains($0) }
                    guard !new.isEmpty else { continue }
                    for ip in new {
                        do {
                            try self.sys("/sbin/route", ["-n", "add", "-host", ip, "-interface", name],
                                         undo: ["-n", "delete", "-host", ip, "-interface", name])
                            self.routedHosts.insert(ip)
                        } catch {
                            log("Route to \(ip) failed: \(error)")
                        }
                    }
                    log("\(host) → \(new.joined(separator: ", "))")
                }
            }
        }
    }

    /// Health check: a TCP connection to the profile's internal host proves routes and DNS work, not just the tunnel.
    /// Three failures in a row (90 s) reconnect, when auto-reconnect is on.
    private func checkHealth() {
        guard !ended, status.state == .connected, let target = profile.healthTarget,
              let port = NWEndpoint.Port(rawValue: target.port) else { return }
        let c = NWConnection(host: NWEndpoint.Host(target.host), port: port, using: .tcp)
        var done = false
        let result = { [weak self] (ok: Bool) in
            guard !done else { return }
            done = true
            c.stateUpdateHandler = nil // breaks the connection -> handler -> connection cycle
            c.cancel()
            self?.healthResult(ok)
        }
        c.stateUpdateHandler = { s in
            switch s {
            case .ready: result(true)
            case .failed, .waiting: result(false)
            default: break
            }
        }
        c.start(queue: q)
        q.asyncAfter(deadline: .now() + 5) { result(false) }
    }

    private func healthResult(_ ok: Bool) {
        guard !ended else { return }
        if ok, healthFailures > 0 { log("Health check: \(profile.healthCheck) reachable again") }
        if !ok, healthFailures == 0 { log("Health check: cannot reach \(profile.healthCheck)") }
        healthFailures = ok ? 0 : healthFailures + 1
        status.reachable = ok // published with the next rate sample
        if healthFailures >= 3, profile.autoReconnect { finish("Health check failed: \(profile.healthCheck) unreachable for 90 s") }
    }

    private func sampleRates() {
        let now = Date(), dt = max(now.timeIntervalSince(lastSample), 0.001)
        status.rxRate = Double(rxBytes - status.rxBytes) / dt
        status.txRate = Double(txBytes - status.txBytes) / dt
        status.rxBytes = rxBytes
        status.txBytes = txBytes
        lastSample = now
        onStatus(status)
    }

    private func pumpUtun() {
        while true {
            let n = read(utunFD, &utunBuf, utunBuf.count)
            guard n > 4 else { return }
            if utunBuf[4] >> 4 == 4, ppp != nil { // IPv4 only
                txBytes += UInt64(n - 4)
                ppp?.sendIP(Array(utunBuf[4..<n]))
            }
        }
    }

    private func writeUtun(_ ip: [UInt8]) {
        guard utunFD >= 0, let first = ip.first, first >> 4 == 4 else { return }
        let frame: [UInt8] = [0, 0, 0, UInt8(AF_INET)] + ip
        rxBytes += UInt64(ip.count)
        _ = frame.withUnsafeBytes { write(utunFD, $0.baseAddress, frame.count) }
    }

    private func finish(_ message: String?, retryable: Bool = true) {
        guard !ended else { return }
        ended = true
        tick?.cancel()
        statsTimer?.cancel()
        ppp?.stop()
        ppp = nil
        undo.runAll()
        if dnsApplied { flushDNSCache() }
        utunSource?.cancel()
        utunSource = nil
        utunFD = -1
        conn?.cancel()
        conn = nil
        if let message { log(message) }
        onEnded(message, retryable)
    }
}

/// Expiry (notAfter) of a certificate as epoch seconds.
func certNotAfter(_ cert: SecCertificate) -> Double? {
    let key = kSecOIDX509V1ValidityNotAfter as String
    guard let values = SecCertificateCopyValues(cert, [key] as CFArray, nil) as? [String: Any],
          let entry = values[key] as? [String: Any],
          let t = (entry[kSecPropertyKeyValue as String] as? NSNumber)?.doubleValue else { return nil }
    return t + kCFAbsoluteTimeIntervalSince1970
}

private func resolveIPv4Literal(_ s: String) -> String? {
    var a = in_addr()
    return inet_pton(AF_INET, s, &a) == 1 ? s : nil
}

/// RFC 1918 + CGNAT (100.64/10): where VPN-internal resolvers live.
func isPrivateIPv4(_ a: [UInt8]) -> Bool {
    a[0] == 10 || (a[0] == 172 && a[1] & 0xF0 == 16) || (a[0] == 192 && a[1] == 168) || (a[0] == 100 && a[1] & 0xC0 == 64)
}
