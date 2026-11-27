import Foundation
import Security
import SSTPKit

/// Reconnecting socket client for sstpd. `onEvent(nil)` means the daemon is unreachable.
final class DaemonLink: @unchecked Sendable {
    var onEvent: (Event?) -> Void = { _ in }
    private let lock = NSLock()
    private var fd: Int32 = -1

    func start() {
        Thread.detachNewThread { [self] in
            while true {
                let s = connectSocket()
                guard s >= 0 else {
                    onEvent(nil)
                    sleep(2)
                    continue
                }
                lock.withLock { fd = s }
                var lines = LineBuffer()
                var buf = [UInt8](repeating: 0, count: 65536)
                while true {
                    let n = read(s, &buf, buf.count)
                    if n <= 0 { break }
                    for l in lines.feed(Array(buf[..<n])) {
                        if let e = try? JSONDecoder().decode(Event.self, from: l) { onEvent(e) }
                    }
                }
                lock.withLock { fd = -1 }
                close(s)
                onEvent(nil)
            }
        }
    }

    func send(_ r: Request) {
        let line = encodeLine(r)
        lock.withLock { if fd >= 0 { _ = write(fd, line, line.count) } }
    }

    private func connectSocket() -> Int32 {
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = unixAddress(daemonSocketPath)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if rc != 0 { close(s); return -1 }
        var one: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        return s
    }
}

enum Keychain {
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.sstpvpn.client", // pre-rename name, kept so saved passwords stay readable
         kSecAttrAccount as String: account]
    }

    static func get(_ account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func delete(_ account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }

    static func set(_ account: String, _ value: String) {
        delete(account)
        var q = query(account)
        q[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(q as CFDictionary, nil)
    }
}
