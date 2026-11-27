import Foundation
import Security
import SSTPKit
import SystemConfiguration

/// Unix-socket control server and session supervisor. One session at a time; every client sees every status
/// change and log line. A session may span several tunnels when it reconnects after a drop.
final class Server {
    private let q = DispatchQueue(label: "sstpd")
    private var listener: DispatchSourceRead?
    private var signals: [DispatchSourceSignal] = []
    private var clients: [Int32: DispatchSourceRead] = [:]
    private var status = Status()
    private var backlog: [String] = [] // recent log lines for GUIs that connect later
    private static let logFile = "/var/log/sekisho.log" // StandardErrorPath in the launchd plist

    private var session: Profile? // what the user asked for; nil = stay disconnected
    private var tunnel: Tunnel?
    private var retry: DispatchWorkItem?
    private var attempts = 0
    private var lastServerIP: String? // set once the session has been connected
    private let killSwitch = KillSwitch()
    private var killSwitchPausedUntil: Date? // network login page (captive portal) in progress
    private var pauseEnd: DispatchWorkItem?
    private let clientRequirement: SecRequirement?
    private var history: [Session] = [] // newest first, at most 200
    private var connectedStatus: Status? // latest status of the tunnel while it is up, for its history entry
    private static let historyFile = "/var/db/sekisho.sessions.json"

    init(clientRequirement: String?) {
        var req: SecRequirement?
        if let s = clientRequirement, SecRequirementCreateWithString(s as CFString, [], &req) != errSecSuccess {
            fputs("invalid --client-requirement: \(s)\n", stderr)
            exit(1) // fail closed rather than accept any client
        }
        self.clientRequirement = req
    }

    func run() {
        logSink = { [weak self] line in self?.q.async { self?.appendLog(line) } }
        recoverAfterCrash()
        history = (try? JSONDecoder().decode([Session].self, from: Data(contentsOf: URL(fileURLWithPath: Self.historyFile)))) ?? []

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        unlink(daemonSocketPath)
        var addr = unixAddress(daemonSocketPath)
        umask(0o117) // socket mode 0660; group is set to admin below
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0, listen(fd, 8) == 0 else {
            fputs("cannot listen on \(daemonSocketPath): \(String(cString: strerror(errno)))\n", stderr)
            exit(1)
        }
        chown(daemonSocketPath, 0, getgrnam("admin")?.pointee.gr_gid ?? 80)

        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: q)
        src.setEventHandler { [self] in
            let c = accept(fd, nil, nil)
            if c >= 0 { addClient(c) }
        }
        src.resume()
        listener = src

        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let s = DispatchSource.makeSignalSource(signal: sig, queue: q)
            s.setEventHandler { [self] in
                session = nil
                retry?.cancel()
                recordSession(dropped: false, reason: "Helper stopped")
                let quit = { [self] in killSwitch.disable(); exit(0) }
                guard let t = tunnel else { return quit() }
                t.onEnded = { _, _ in quit() } // tear routes/DNS down first
                t.stop()
                q.asyncAfter(deadline: .now() + 3) { quit() }
            }
            s.resume()
            signals.append(s)
        }
        log("sstpd listening on \(daemonSocketPath)" + (clientRequirement == nil ? " (no client requirement: any process of the console user may connect)" : ""))
    }

    // MARK: clients

    private func addClient(_ c: Int32) {
        // the socket is admin-group only; also require the logged-in console user (or root), not any admin process,
        // and that user's process must be the Sekisho app itself (code signature), not any program they run
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(c, &uid, &gid) == 0, uid == 0 || (uid == consoleUID() && isTrustedClient(c)) else {
            log("Rejected control connection from uid \(uid)")
            close(c)
            return
        }
        _ = fcntl(c, F_SETFL, O_NONBLOCK)
        var one: Int32 = 1
        setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        // a full backlog can exceed the default socket buffer; the client drop below assumes whole writes
        var size: Int32 = 1 << 20
        setsockopt(c, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))

        var lines = LineBuffer()
        let s = DispatchSource.makeReadSource(fileDescriptor: c, queue: q)
        s.setEventHandler { [self] in
            var buf = [UInt8](repeating: 0, count: 4096)
            let n = read(c, &buf, buf.count)
            if n < 0, errno == EAGAIN { return }
            guard n > 0 else { return s.cancel() }
            for line in lines.feed(Array(buf[..<n])) { handle(line, from: c) }
        }
        s.setCancelHandler { [self] in
            close(c)
            clients[c] = nil
        }
        s.resume()
        clients[c] = s
        write(encodeLine(Event(status: status, log: backlog, sessions: history)), to: c)
    }

    private func consoleUID() -> uid_t? {
        var uid: uid_t = 0
        return SCDynamicStoreCopyConsoleUser(nil, &uid, nil) != nil ? uid : nil
    }

    private func isTrustedClient(_ c: Int32) -> Bool {
        guard let req = clientRequirement else { return true }
        var token = audit_token_t()
        var len = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(c, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &len) == 0 else { return false }
        // audit token, not pid: a pid can be reused by another process between connect and this check
        let attrs = [kSecGuestAttributeAudit: Data(bytes: &token, count: Int(len))] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &code) == errSecSuccess, let code else { return false }
        return SecCodeCheckValidity(code, [], req) == errSecSuccess
    }

    private func handle(_ line: Data, from c: Int32) {
        guard let req = try? JSONDecoder().decode(Request.self, from: line) else { return }
        switch req.cmd {
        case .status:
            write(encodeLine(Event(status: status)), to: c)
        case .disconnect:
            guard session != nil || tunnel != nil else { return }
            session = nil
            if let t = tunnel { t.stop() } else { endSession(nil) }
        case .connect:
            guard session == nil, tunnel == nil, let p = req.profile else { return }
            if let problem = p.problem { return endSession(problem) }
            session = p
            attempts = 0
            lastServerIP = nil
            startTunnel()
        case .pauseKillSwitch:
            // a Wi-Fi login page (captive portal) cannot load behind the kill switch; offered only while reconnecting
            guard let p = session, p.killSwitch, p.isFullTunnel, status.state != .connected, let ip = lastServerIP else { return }
            killSwitch.disable()
            killSwitchPausedUntil = Date().addingTimeInterval(120)
            log("Kill switch paused for 2 minutes for a network login page")
            let w = DispatchWorkItem { [weak self] in
                guard let self, self.session != nil else { return }
                self.clearPause()
                self.killSwitch.update(server: ip, port: p.port, tunnel: nil)
                self.publish(self.status)
            }
            pauseEnd?.cancel()
            pauseEnd = w
            q.asyncAfter(deadline: .now() + 120, execute: w)
            publish(status)
        case .clearHistory:
            history = []
            saveHistory()
            broadcast(Event(sessions: history))
        }
    }

    private func clearPause() {
        pauseEnd?.cancel()
        pauseEnd = nil
        killSwitchPausedUntil = nil
    }

    // MARK: session

    private func startTunnel() {
        guard let p = session else { return }
        let t = Tunnel(profile: p, queue: q, fallbackIP: lastServerIP)
        let guarded = p.killSwitch && p.isFullTunnel
        t.onStatus = { [weak self, weak t] s in
            guard let self else { return }
            if s.state == .connected, self.status.state != .connected, let ip = t?.serverIP {
                self.attempts = 0
                self.lastServerIP = ip
                if guarded {
                    self.clearPause() // back up: block again right away
                    self.killSwitch.update(server: ip, port: p.port, tunnel: s.interface)
                }
            }
            self.publish(s)
        }
        t.onEnded = { [weak self, weak t] message, retryable in
            guard let self else { return }
            let cert = t?.untrustedCert
            self.tunnel = nil
            self.recordSession(dropped: message != nil, reason: message ?? "") // nil = ended on request
            // reconnect only a session that was up and dropped on its own; first-attempt errors go to the user
            guard let message, retryable, let p = self.session, p.autoReconnect, let ip = self.lastServerIP else {
                return self.endSession(message, untrustedCert: cert)
            }
            if guarded, self.killSwitchPausedUntil == nil { self.killSwitch.update(server: ip, port: p.port, tunnel: nil) } // keep blocking, minus the dead tunnel
            self.attempts += 1
            let delay = min(60, 1 << min(self.attempts, 6)) // 2, 4, 8, … 60 s
            var s = Status()
            s.state = .connecting
            s.profileName = p.name
            s.message = "Reconnecting in \(delay)s: \(message)"
            log(s.message)
            self.publish(s)
            let w = DispatchWorkItem { [weak self] in
                self?.retry = nil
                self?.startTunnel()
            }
            self.retry = w
            self.q.asyncAfter(deadline: .now() + .seconds(delay), execute: w)
        }
        tunnel = t
        t.start()
    }

    private func endSession(_ message: String?, untrustedCert: String? = nil) {
        session = nil
        retry?.cancel()
        retry = nil
        killSwitch.disable()
        clearPause()
        var s = Status()
        s.message = message ?? ""
        s.untrustedCert = untrustedCert
        publish(s)
    }

    // MARK: output

    private func publish(_ s: Status) {
        var s = s
        s.killSwitchPausedUntil = killSwitchPausedUntil?.timeIntervalSince1970
        if s.state == .connected { connectedStatus = s }
        status = s
        broadcast(Event(status: s))
    }

    /// History entry for the tunnel that just ended, if it had been up. Kept by the helper in a root-owned file, so
    /// sessions are recorded while no GUI runs.
    private func recordSession(dropped: Bool, reason: String) {
        guard let c = connectedStatus, let since = c.since else { return }
        connectedStatus = nil
        history.insert(Session(profile: c.profileName ?? "", start: since, end: Date().timeIntervalSince1970,
                               rx: c.rxBytes, tx: c.txBytes, dropped: dropped, reason: reason), at: 0)
        if history.count > 200 { history.removeLast(history.count - 200) }
        saveHistory()
        broadcast(Event(sessions: history))
    }

    private func saveHistory() {
        guard let data = try? JSONEncoder().encode(history) else { return }
        FileManager.default.createFile(atPath: Self.historyFile, contents: data, attributes: [.posixPermissions: 0o600])
    }

    /// Keeps the log under 1 MB plus one previous file. Done here rather than by newsyslog because
    /// launchd holds the file open as our stderr, so an external rename would leave us writing to the old file.
    private func rotateLogIfNeeded() {
        var cur = stat(), file = stat()
        guard fstat(fileno(stderr), &cur) == 0, cur.st_size > 1 << 20,
              stat(Self.logFile, &file) == 0, cur.st_ino == file.st_ino else { return } // stderr really is the log file
        rename(Self.logFile, Self.logFile + ".1")
        _ = freopen(Self.logFile, "a", stderr)
    }

    private func appendLog(_ line: String) {
        rotateLogIfNeeded()
        backlog.append(line)
        if backlog.count > 500 { backlog.removeFirst(backlog.count - 500) }
        broadcast(Event(log: [line]))
    }

    private func broadcast(_ e: Event) {
        let line = encodeLine(e)
        for c in clients.keys { write(line, to: c) }
    }

    private func write(_ bytes: [UInt8], to c: Int32) {
        // small messages on a local socket; a client too slow to take them gets dropped
        if Darwin.write(c, bytes, bytes.count) != bytes.count { clients[c]?.cancel() }
    }
}
