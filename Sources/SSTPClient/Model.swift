import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications
import SSTPKit

// MARK: model

struct Sample: Identifiable {
    let id: Int
    let rx: Double, tx: Double
}

/// Shows banners even while our window is frontmost, and runs the buttons on them.
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationPresenter()
    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive r: UNNotificationResponse) async {
        let action = r.actionIdentifier
        await MainActor.run { VPNModel.shared.notificationAction(action) }
    }
}

@MainActor
final class VPNModel: ObservableObject {
    static let shared = VPNModel() // one model for the app and the delegate that receives links
    @Published var status = Status()
    @Published var logs: [String] = []
    @Published var history: [Sample] = [] // last 60 s of speeds
    @Published var helperReachable = false
    @Published var helperOutdated = false
    @Published var installError: String?
    @Published var profiles: [Profile] { didSet { saveProfiles(old: oldValue) } }
    @Published var selectedID: UUID { didSet { defaults.set(selectedID.uuidString, forKey: "selectedProfile") } }
    @Published var connectOnLaunch: Bool { didSet { defaults.set(connectOnLaunch, forKey: "connectOnLaunch") } }
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var autoConnectUntrusted: Bool {
        didSet {
            defaults.set(autoConnectUntrusted, forKey: "autoConnectUntrusted")
            if autoConnectUntrusted { network.requestWiFiName() }
            handledNetwork = nil // judge the network we are on now
            autoConnectIfUntrusted()
        }
    }
    @Published var trustedNetworks: String { didSet { defaults.set(trustedNetworks, forKey: "trustedNetworks") } }
    @Published var currentSSID: String?
    @Published var wifiNameHidden = false // on Wi-Fi, but macOS hides the name (no Location permission)
    @Published var sessions: [Session] = [] // kept by the helper, newest first

    private let defaults = UserDefaults.standard
    private let link = DaemonLink()
    private var replaceLogs = true // the first event of each daemon connection carries its whole backlog
    private var seenStatus = false // no notifications for the state we find on (re)connecting to the daemon
    private var dropped = false // the last connection fell over on its own; the next "connected" is a reconnect
    private var certWarned = false
    private var autoConnectPending: Bool
    private var sampleID = 0
    private let network = NetworkWatcher()
    private var handledNetwork: String? // auto-connect acts once per network, so a manual disconnect sticks
    private var hotKey: HotKey?
    private var offeredHelperUpdate = false // once per launch

    init() {
        // settings of builds from before the Sekisho rename live in the old bundle id's domain (left untouched)
        let src = defaults.object(forKey: "profiles") != nil ? defaults : UserDefaults(suiteName: "com.sstpvpn.client") ?? defaults
        var ps = src.data(forKey: "profiles").flatMap { try? JSONDecoder().decode([Profile].self, from: $0) } ?? []
        if ps.isEmpty { // first run, or migrating the single-profile settings of 0.1
            var p = Profile()
            p.server = src.string(forKey: "server") ?? ""
            p.name = p.server.isEmpty ? "VPN" : p.server
            p.port = UInt16(clamping: src.object(forKey: "port") as? Int ?? 443)
            p.username = src.string(forKey: "username") ?? ""
            p.password = Keychain.get("password") ?? ""
            ps = [p]
            if !p.password.isEmpty { Keychain.set(p.id.uuidString, p.password) }
            Keychain.delete("password")
        } else {
            for i in ps.indices { ps[i].password = Keychain.get(ps[i].id.uuidString) ?? "" }
        }
        profiles = ps
        selectedID = src.string(forKey: "selectedProfile").flatMap(UUID.init).flatMap { id in ps.first { $0.id == id }?.id } ?? ps[0].id
        connectOnLaunch = src.bool(forKey: "connectOnLaunch")
        autoConnectUntrusted = defaults.bool(forKey: "autoConnectUntrusted")
        trustedNetworks = defaults.string(forKey: "trustedNetworks") ?? ""
        defaults.removeObject(forKey: "sessions") // 1.1 kept the history in the app; the helper keeps it now
        autoConnectPending = src.bool(forKey: "connectOnLaunch")
        saveProfiles(old: profiles) // persists migrated profiles here; passwords are already in the Keychain
        defaults.set(selectedID.uuidString, forKey: "selectedProfile")
        defaults.set(connectOnLaunch, forKey: "connectOnLaunch")

        UNUserNotificationCenter.current().delegate = NotificationPresenter.shared
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: "retry", actions: [
                UNNotificationAction(identifier: "connect", title: String(localized: "Connect Again")),
            ], intentIdentifiers: []),
            UNNotificationCategory(identifier: "portal", actions: [
                UNNotificationAction(identifier: "loginPage", title: String(localized: "Open Login Page")),
            ], intentIdentifiers: []),
        ])

        link.onEvent = { [weak self] e in
            Task { @MainActor in self?.apply(e) }
        }
        link.start()

        network.onChange = { [weak self] in
            Task { @MainActor in self?.networkChanged() }
        }
        if autoConnectUntrusted { network.requestWiFiName() }
        hotKey = HotKey { [weak self] in
            Task { @MainActor in self?.toggleVPN() }
        }
    }

    /// Profiles go to UserDefaults without passwords; changed passwords go to the Keychain, unless the profile asks for
    /// its password on every connect: then none is kept.
    private func saveProfiles(old: [Profile]) {
        for p in profiles {
            let before = old.first { $0.id == p.id }
            if !p.savePassword {
                if before?.savePassword != false { Keychain.delete(p.id.uuidString) }
            } else if before?.password != p.password || before?.savePassword == false {
                Keychain.set(p.id.uuidString, p.password)
            }
        }
        let stripped = profiles.map { p -> Profile in
            var p = p
            p.password = ""
            return p
        }
        defaults.set(try? JSONEncoder().encode(stripped), forKey: "profiles")
    }

    private var index: Int { profiles.firstIndex { $0.id == selectedID } ?? 0 }
    var current: Profile { profiles[index] }
    /// The profile of the running session (status carries only its name).
    var sessionProfile: Profile? { profiles.first { $0.name == status.profileName } }
    var currentBinding: Binding<Profile> {
        Binding(get: { self.profiles[self.index] }, set: { self.profiles[self.index] = $0 })
    }

    func addProfile() {
        var p = Profile()
        p.name = "VPN \(profiles.count + 1)"
        profiles.append(p)
        selectedID = p.id
    }

    func removeCurrentProfile() {
        guard profiles.count > 1 else { return }
        Keychain.delete(current.id.uuidString)
        profiles.remove(at: index)
        selectedID = profiles[0].id
    }

    // MARK: daemon events

    private func apply(_ e: Event?) {
        helperReachable = e != nil
        guard let e else {
            status = Status()
            replaceLogs = true
            seenStatus = false
            helperOutdated = false
            return
        }
        helperOutdated = e.v != protocolVersion
        if helperOutdated, !offeredHelperUpdate {
            offeredHelperUpdate = true
            DispatchQueue.main.async { self.offerHelperUpdate() } // a modal alert, so not from inside event handling
        }
        if let s = e.status {
            if seenStatus { notifyTransition(from: status, to: s) }
            seenStatus = true
            status = s
            if s.state == .connected, !certWarned, let w = certWarning { // once per session, not per reconnect
                certWarned = true
                notify(w, certAdvice, id: "cert")
            } else if s.state == .disconnected {
                certWarned = false
            }
            if s.state == .connected {
                sampleID += 1
                history.append(Sample(id: sampleID, rx: s.rxRate, tx: s.txRate))
                if history.count > 60 { history.removeFirst(history.count - 60) }
            } else {
                history.removeAll()
            }
            if autoConnectPending {
                autoConnectPending = false
                if s.state == .disconnected, canConnect { connect() }
            }
            if s.state == .disconnected, quitting { finishQuit() }
            if s.state == .disconnected, let id = pendingSwitch { // the old tunnel is down: bring up the new one
                pendingSwitch = nil
                connect(id)
            }
            autoConnectIfUntrusted() // also covers networks seen before the helper answered
        }
        if let ss = e.sessions { sessions = ss }
        if let l = e.log {
            if replaceLogs { logs = l } else { logs += l }
            replaceLogs = false
            if logs.count > 1000 { logs.removeFirst(logs.count - 1000) }
        }
    }

    func clearHistory() { link.send(Request(.clearHistory)) }

    private func notifyTransition(from a: Status, to b: Status) {
        guard a.state != b.state else { return }
        let name = b.profileName ?? a.profileName ?? current.name // statuses after a session ends carry no profile
        let server = profiles.first { $0.name == name }?.server ?? name
        switch b.state {
        case .connected:
            notify(dropped ? String(localized: "Reconnected to \(server)") : String(localized: "Connected to \(server)"),
                   b.localIP.map { String(localized: "VPN address \($0)") } ?? "")
            dropped = false
        case .connecting where a.state == .connected:
            dropped = true
            let guarded = profiles.first { $0.name == name }.map { $0.killSwitch && $0.isFullTunnel } == true
            notify(String(localized: "Connection to \(server) lost"), b.message, category: guarded ? "portal" : nil)
        case .disconnected:
            dropped = false
            if b.untrustedCert != nil {
                notify(String(localized: "Couldn't connect to \(server)"),
                       String(localized: "The server's certificate is not trusted. Open Sekisho to review it."))
            } else if b.message.isEmpty || a.state == .connected { // user-requested, or an established tunnel ended
                notify(String(localized: "Disconnected from \(server)"), b.message, category: b.message.isEmpty ? nil : "retry")
            } else { // ended before ever connecting: resolve, TLS, auth, timeout…
                notify(String(localized: "Couldn't connect to \(server)"), b.message, category: "retry")
            }
        default:
            break
        }
    }

    /// One identifier per topic: a newer notification replaces the previous one in Notification Center. The category
    /// adds a button: "retry" connects again, "portal" opens a Wi-Fi login page past the kill switch.
    private func notify(_ title: String, _ body: String, id: String = "vpn-state", category: String? = nil) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        if let category { c.categoryIdentifier = category }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
    }

    func notificationAction(_ action: String) {
        switch action {
        case "connect": if !busy, canConnect { connect() }
        case "loginPage": if killSwitchHolding { pauseKillSwitch() }
        default: break // the notification itself was clicked
        }
    }

    /// The session's server certificate expires within 14 days (or has: then only a pin still accepts it).
    var certWarning: String? {
        guard status.state == .connected, let t = status.certExpires else { return nil }
        let days = Int(((t - Date().timeIntervalSince1970) / 86400).rounded(.down))
        guard days <= 14 else { return nil }
        return days < 0 ? String(localized: "The server certificate has expired")
            : String(localized: "The server certificate expires in \(days) days")
    }

    var certAdvice: String {
        sessionProfile?.pinnedCert != nil
            ? String(localized: "It is pinned: when the server renews it, Sekisho will refuse the new one. Ask your VPN administrator for its fingerprint.")
            : String(localized: "Tell your VPN administrator before it stops working.")
    }

    // MARK: actions

    var busy: Bool { status.state != .disconnected }
    var canConnect: Bool { helperReachable && !helperOutdated && current.problem == nil }

    var statusLine: String {
        guard helperReachable else { return String(localized: "Helper not running") }
        guard !helperOutdated else { return String(localized: "Helper needs an update") }
        switch status.state {
        case .connected: return status.localIP.map { String(localized: "Connected — \($0)") } ?? String(localized: "Connected")
        case .connecting, .disconnecting: return status.message
        case .disconnected: return status.message.isEmpty ? String(localized: "Disconnected") : status.message
        }
    }

    func connect() {
        var p = current
        p.server = p.server.trimmingCharacters(in: .whitespaces)
        if !p.savePassword || p.askCode {
            guard let entered = askCredentials(p) else { return }
            if !p.savePassword { p.password = entered.password }
            p.password += entered.code // RADIUS OTP: the code follows the password
        }
        link.send(Request(.connect, profile: p))
    }

    /// The password (when not remembered) and the one-time code, asked right before connecting; nil when cancelled.
    private func askCredentials(_ p: Profile) -> (password: String, code: String)? {
        let pass = NSSecureTextField(), code = NSTextField()
        pass.placeholderString = String(localized: "Password")
        code.placeholderString = String(localized: "One-time code")
        let fields: [NSTextField] = (p.savePassword ? [] : [pass]) + (p.askCode ? [code] : [])
        let stack = NSStackView(views: fields)
        stack.orientation = .vertical
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 260, height: CGFloat(fields.count) * 22 + CGFloat(fields.count - 1) * 8)
        for f in fields { f.widthAnchor.constraint(equalToConstant: 260).isActive = true }
        let a = NSAlert()
        a.messageText = String(localized: "Connect to “\(p.name)”")
        a.informativeText = p.askCode ? String(localized: "The code is sent right after the password, so an automatic reconnect cannot reuse it.") : ""
        a.accessoryView = stack
        a.addButton(withTitle: String(localized: "Connect"))
        a.addButton(withTitle: String(localized: "Cancel"))
        a.window.initialFirstResponder = fields.first
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        return (pass.stringValue, code.stringValue.trimmingCharacters(in: .whitespaces))
    }

    func connect(_ id: UUID) {
        selectedID = id
        connect()
    }

    private var pendingSwitch: UUID?
    private var quitting = false

    /// Quitting takes the VPN down too: a tunnel left running without its app kept routing everything (a full tunnel
    /// carried even Discord's voice over TCP) with no visible way to stop it. True when quitting has to wait for the
    /// helper; it gets 5 s, then the app quits anyway.
    func disconnectForQuit() -> Bool {
        guard helperReachable, busy else { return false }
        quitting = true
        disconnect()
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self.finishQuit() }
        return true
    }

    private func finishQuit() {
        guard quitting else { return }
        quitting = false
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    /// Another profile while connected (menu bar): disconnect, then connect to it once the tunnel is down.
    func switchTo(_ id: UUID) {
        if busy {
            pendingSwitch = id
            disconnect()
        } else {
            connect(id)
        }
    }

    func disconnect() { link.send(Request(.disconnect)) }

    /// Session history as CSV (oldest first) for reports. Reasons can carry server text, so fields that a spreadsheet
    /// would run as a formula are prefixed with an apostrophe.
    func exportHistory() {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Sekisho-history-\(stamp.string(from: Date())).csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let iso = ISO8601DateFormatter()
        func field(_ s: String) -> String {
            let safe = s.first.map { "=+-@".contains($0) } == true ? "'" + s : s
            return safe.contains(where: { ",\"\n\r".contains($0) }) ? "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : safe
        }
        var csv = "started,ended,profile,seconds,bytes_down,bytes_up,ended_by,reason\n"
        for s in sessions.reversed() {
            csv += [iso.string(from: Date(timeIntervalSince1970: s.start)), iso.string(from: Date(timeIntervalSince1970: s.end)),
                    field(s.profile), String(Int(s.end - s.start)), String(s.rx), String(s.tx),
                    s.dropped ? "dropped" : "disconnected", field(s.reason)].joined(separator: ",") + "\n"
        }
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            installError = String(localized: "Export failed: \(error.localizedDescription)")
        }
    }

    /// Reconnecting behind the kill switch: a Wi-Fi login page (captive portal) cannot load, so a pause is offered.
    var killSwitchHolding: Bool {
        dropped && status.state == .connecting && status.killSwitchPausedUntil == nil
            && sessionProfile.map { $0.killSwitch && $0.isFullTunnel } == true
    }

    func pauseKillSwitch() {
        link.send(Request(.pauseKillSwitch))
        // plain HTTP, so the Wi-Fi's portal can redirect it to its login page
        NSWorkspace.shared.open(URL(string: "http://captive.apple.com")!)
    }

    /// Global hotkey: one key to bring the VPN up or down.
    func toggleVPN() {
        if busy { disconnect() } else if canConnect { connect() }
    }

    /// sekisho://connect[?profile=Name], sekisho://disconnect, sekisho://toggle: for Shortcuts, Raycast, Focus filters.
    /// Links only switch between configured profiles; they cannot add a server.
    func open(_ url: URL) {
        if url.isFileURL { return importProfile(from: url) } // a double-clicked .sekisho file
        guard url.scheme?.lowercased() == "sekisho" else { return }
        let name = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "profile" }?.value
        switch url.host?.lowercased() {
        case "connect":
            if let name {
                guard let p = profiles.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                    return notify(String(localized: "Unknown profile"), String(localized: "No profile named “\(name)”."))
                }
                if !busy { selectedID = p.id }
            }
            if !busy, canConnect { connect() }
        case "disconnect":
            if busy, linkMayDisconnect() { disconnect() }
        case "toggle":
            if !busy || linkMayDisconnect() { toggleVPN() }
        default:
            notify(String(localized: "Unknown link"), url.absoluteString)
        }
    }

    /// Any web page can open a sekisho:// link (the browser asks once), and a disconnect also drops the kill switch's
    /// protection; ask first, unless the user chose not to be asked (for Shortcuts and Focus automations).
    private func linkMayDisconnect() -> Bool {
        if defaults.bool(forKey: "linksMayDisconnect") { return true }
        let a = NSAlert()
        a.messageText = String(localized: "Disconnect the VPN?")
        a.informativeText = String(localized: "A link (from a browser, Shortcuts or another app) asks Sekisho to disconnect.")
        a.addButton(withTitle: String(localized: "Disconnect"))
        a.addButton(withTitle: String(localized: "Cancel"))
        a.showsSuppressionButton = true
        a.suppressionButton?.title = String(localized: "Don't ask again for links")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return false }
        if a.suppressionButton?.state == .on { defaults.set(true, forKey: "linksMayDisconnect") }
        return true
    }

    // MARK: profile files

    static let profileType = UTType(filenameExtension: "sekisho", conformingTo: .json) ?? .json

    /// Writes the selected profile as a .sekisho file for colleagues: server and settings, never the password.
    func exportProfile() {
        var p = current
        p.password = ""
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (p.name.isEmpty ? "VPN" : p.name) + ".sekisho"
        panel.allowedContentTypes = [Self.profileType]
        panel.message = String(localized: "Contains the server and settings of “\(p.name)”, not the password.")
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try enc.encode(p).write(to: url, options: .atomic)
        } catch {
            installError = String(localized: "Export failed: \(error.localizedDescription)")
        }
    }

    /// Adds a profile from a .sekisho file after the user confirms; a pinned certificate is shown, since importing it
    /// means trusting that server.
    func importProfile(from file: URL? = nil) {
        let url: URL
        if let file {
            url = file
        } else {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [Self.profileType]
            NSApp.activate(ignoringOtherApps: true)
            guard panel.runModal() == .OK, let picked = panel.url else { return }
            url = picked
        }
        NSApp.activate(ignoringOtherApps: true)
        guard let data = try? Data(contentsOf: url), data.count < 64 << 10,
              var p = try? JSONDecoder().decode(Profile.self, from: data) else {
            alert(String(localized: "Cannot import “\(url.lastPathComponent)”"), String(localized: "The file is not a Sekisho profile."))
            return
        }
        if let problem = p.problem {
            alert(String(localized: "Cannot import “\(p.name)”"), problem)
            return
        }
        let address = "\(p.server):\(p.port)"
        var info = String(localized: "Server: \(address)")
        if let pin = p.pinnedCert {
            let sha = fingerprint(pin.replacingOccurrences(of: ":", with: ""))
            info += "\n\n" + String(localized: "This profile trusts a server certificate that macOS does not:\nSHA-256 \(sha)\n\nImport it only if the file comes from your VPN administrator.")
        }
        guard alert(String(localized: "Import “\(p.name)”?"), info, confirm: String(localized: "Import")) else { return }
        p.id = UUID()
        p.password = ""
        if profiles.contains(where: { $0.name == p.name }) { p.name += " (imported)" } // sessions are matched by name
        profiles.append(p)
        if !busy { selectedID = p.id }
    }

    /// Modal alert; with `confirm`, also a Cancel button, and true when confirmed.
    @discardableResult
    private func alert(_ title: String, _ text: String, confirm: String? = nil) -> Bool {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        if let confirm {
            a.addButton(withTitle: confirm)
            a.addButton(withTitle: String(localized: "Cancel"))
        }
        return a.runModal() == .alertFirstButtonReturn
    }

    // MARK: auto-connect outside trusted Wi-Fi

    // shortcut: comma-separated, so a Wi-Fi name containing a comma cannot be trusted; switch to a list editor if that matters
    var trustedList: Set<String> {
        Set(trustedNetworks.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    func trustCurrentNetwork() {
        guard let s = currentSSID else { return }
        trustedNetworks = trustedList.isEmpty ? s : trustedNetworks.trimmingCharacters(in: .whitespaces) + ", " + s
    }

    private func networkChanged() {
        currentSSID = network.ssid
        wifiNameHidden = network.onWiFi && network.ssid == nil
        autoConnectIfUntrusted()
    }

    /// Connects once per newly joined network unless it is a trusted Wi-Fi, with the profile that lists this Wi-Fi, else
    /// the selected one. A Wi-Fi whose name macOS hides is skipped (it may be a trusted one) and judged again when
    /// Location permission reveals the name.
    private func autoConnectIfUntrusted() {
        guard autoConnectUntrusted, seenStatus, helperReachable, !helperOutdated, let key = network.key, key != handledNetwork,
              !(network.onWiFi && network.ssid == nil) else { return }
        handledNetwork = key
        guard status.state == .disconnected, !trustedList.contains(network.ssid ?? "") else { return }
        if let ssid = network.ssid, let p = profiles.first(where: { $0.wifiList.contains(ssid) }) { selectedID = p.id }
        if canConnect { connect() }
    }

    func trustAndConnect(_ certificate: String) {
        currentBinding.wrappedValue.pinnedCert = certificate
        connect()
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            installError = String(localized: "Launch at login: \(error.localizedDescription)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Save panel for "Sekisho[-what]-2026-11-28_04-30-15.log"; `contents` runs off the main thread.
    private func saveLog(_ what: String? = nil, message: String? = nil, contents: @escaping @Sendable () -> String) {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (["Sekisho", what, stamp.string(from: Date())].compactMap { $0 }).joined(separator: "-") + ".log"
        panel.allowedContentTypes = [UTType(filenameExtension: "log") ?? .plainText]
        panel.isExtensionHidden = false // macOS hides it by default with Finder's setting; the user wants to see .log
        if let message { panel.message = message }
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task.detached {
            do {
                try contents().write(to: url, atomically: true, encoding: .utf8)
            } catch {
                await MainActor.run { self.installError = String(localized: "Export failed: \(error.localizedDescription)") }
            }
        }
    }

    func exportLogs() {
        let text = logs.joined(separator: "\n") + "\n"
        saveLog { text }
    }

    /// Log plus the Mac's view of the network (routes, DNS, interfaces) for a VPN administrator. No passwords.
    func exportDiagnostics() {
        let info = Bundle.main.infoDictionary ?? [:]
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        var profile = sessionProfile ?? current
        profile.password = ""
        let head = """
        Sekisho \(info["CFBundleShortVersionString"] ?? "?") (\(info["CFBundleVersion"] ?? "?")), \
        macOS \(ProcessInfo.processInfo.operatingSystemVersionString), \(Date())
        Helper: \(helperReachable ? (helperOutdated ? "outdated" : "running") : "not running")

        == Status
        \(String(decoding: (try? enc.encode(status)) ?? Data(), as: UTF8.self))

        == Profile (password removed)
        \(String(decoding: (try? enc.encode(profile)) ?? Data(), as: UTF8.self))
        """
        let log = logs.joined(separator: "\n")
        saveLog("diagnostics", message: String(localized: "Contains the server, username, addresses, routes and DNS settings; no passwords.")) {
            var out = head
            for (path, args) in [("/usr/sbin/netstat", ["-rn", "-f", "inet"]), ("/usr/sbin/scutil", ["--dns"]), ("/sbin/ifconfig", [])] {
                out += "\n\n== \(([path] + args).joined(separator: " "))\n" + commandOutput(path, args)
            }
            return out + "\n\n== Log\n" + log + "\n"
        }
    }

    func installHelper() { runAsRoot("install-daemon.sh", "sstpd") }

    func uninstallHelper() {
        let a = NSAlert()
        a.messageText = String(localized: "Uninstall the helper?")
        a.informativeText = String(localized: "This disconnects the VPN and removes the root helper (sstpd). Sekisho cannot connect until you install it again. Your profiles are kept.")
        a.addButton(withTitle: String(localized: "Uninstall")).hasDestructiveAction = true
        a.addButton(withTitle: String(localized: "Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        runAsRoot("uninstall-daemon.sh")
    }

    /// Runs a bundled script as root via the standard macOS admin password prompt; arguments are bundled files too.
    private func runAsRoot(_ script: String, _ files: String...) {
        guard let dir = Bundle.main.resourceURL?.path else { return }
        func shq(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let cmd = "/bin/sh " + ([script] + files).map { shq(dir + "/" + $0) }.joined(separator: " ")
        let escaped = cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let osa = "do shell script \"\(escaped)\" with administrator privileges"
        installError = nil
        Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", osa]
            let err = Pipe()
            p.standardError = err
            try? p.run()
            let text = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
            if p.terminationStatus != 0 {
                await MainActor.run { self.installError = text.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
        }
    }

    /// After an app update with a new helper protocol the VPN cannot connect until the helper is updated too; ask
    /// right away instead of leaving it to the banner in the window.
    private func offerHelperUpdate() {
        NSApp.activate(ignoringOtherApps: true)
        let ok = alert(String(localized: "Update the helper?"),
                       String(localized: "Sekisho was updated and its root helper (sstpd) is now older than the app, so the VPN cannot connect until it is updated too. This asks for an admin password and drops an active VPN."),
                       confirm: String(localized: "Update Helper"))
        if ok { installHelper() }
    }
}

/// stdout and stderr of a command, or why it could not run.
func commandOutput(_ path: String, _ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = out
    do { try p.run() } catch { return "(\(error.localizedDescription))" }
    let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    p.waitUntilExit()
    return text
}

