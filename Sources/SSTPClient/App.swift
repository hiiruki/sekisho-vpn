import Charts
import ServiceManagement
import Sparkle
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications
import SSTPKit

@main
struct SSTPClientApp: App {
    @StateObject private var vpn = VPNModel.shared
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // feed and EdDSA key come from Info.plist (SUFeedURL, SUPublicEDKey: scripts/build-app.sh)
    private let updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    var body: some Scene {
        Window("Sekisho", id: "main") {
            ContentView().environmentObject(vpn)
        }
        .windowResizability(.contentSize)

        Window("Session History", id: "history") {
            HistoryView().environmentObject(vpn)
        }
        .defaultSize(width: 760, height: 420)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Import Profile…") { vpn.importProfile() }
                Button("Export Profile…") { vpn.exportProfile() }
            }
            CommandGroup(replacing: .appInfo) {
                Button("About Sekisho") { showAbout() }
                Button("Check for Updates…") { updater.checkForUpdates(nil) }
                Divider()
                Button("Uninstall Helper…") { vpn.uninstallHelper() }.disabled(!vpn.helperReachable)
            }
        }

        // a panel, not an NSMenu: the menu would be rebuilt every second (live speeds) and jump while open
        MenuBarExtra {
            MenuPanel().environmentObject(vpn)
        } label: {
            if vpn.status.state == .connected {
                Image(nsImage: menuBarSpeedImage(rx: vpn.status.rxRate, tx: vpn.status.txRate))
            } else {
                Image(systemName: "lock.shield")
            }
        }
        .menuBarExtraStyle(.window)
    }
}

/// Standard About panel (name, version, copyright come from Info.plist) plus a line and the website.
func showAbout() {
    let center = NSMutableParagraphStyle()
    center.alignment = .center
    let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
    let credits = NSMutableAttributedString(string: String(localized: "SSTP VPN client for macOS") + "\n", attributes: [
        .font: font, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: center,
    ])
    credits.append(NSAttributedString(string: "hiiruki.moe", attributes: [
        .font: font, .link: URL(string: "https://hiiruki.moe")!, .paragraphStyle: center,
    ]))
    NSApp.activate(ignoringOtherApps: true)
    NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
}

// MARK: formatting

/// "0 B", "12.3 KB", "1.2 MB" (decimal units, like network speeds usually are).
func bytes(_ v: Double) -> String {
    let units = ["B", "KB", "MB", "GB", "TB"]
    var x = v, i = 0
    while x >= 1000, i < units.count - 1 { x /= 1000; i += 1 }
    return i == 0 ? "\(Int(x)) B" : String(format: "%.1f %@", x, units[i])
}

func speed(_ v: Double) -> String { bytes(v) + "/s" }

/// At most 4 characters: "0B", "999B", "1.2K", "85K", "9.9M", "120M".
func compactRate(_ v: Double) -> String {
    let units = ["B", "K", "M", "G"]
    var x = v, i = 0
    while x >= 999.5, i < units.count - 1 { x /= 1000; i += 1 }
    return (i > 0 && x < 9.95 ? String(format: "%.1f", x) : String(format: "%.0f", x)) + units[i]
}

func duration(since: Double) -> String { duration(Date().timeIntervalSince1970 - since) }

func duration(_ seconds: Double) -> String {
    let s = max(0, Int(seconds))
    return String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
}

func latency(_ ms: Double) -> String { "\(Int(ms.rounded())) ms" }

/// "AB:CD:…" like Keychain Access shows certificate fingerprints.
func fingerprint(_ hex: String) -> String {
    stride(from: 0, to: hex.count, by: 2).map { i in
        String(hex.dropFirst(i).prefix(2)).uppercased()
    }.joined(separator: ":")
}

/// Shield + two-line ↑/↓ readout, drawn at a fixed width so the status item never shifts as numbers change.
func menuBarSpeedImage(rx: Double, tx: Double) -> NSImage {
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium),
                                                .foregroundColor: NSColor.black]
    let textWidth = ("↓ 888M" as NSString).size(withAttributes: attrs).width.rounded(.up) // widest possible line
    let shield = NSImage(systemSymbolName: "lock.shield.fill", accessibilityDescription: "VPN connected")!
        .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))!
    let size = NSSize(width: shield.size.width + 3 + textWidth, height: 22)
    let image = NSImage(size: size, flipped: false) { _ in
        shield.draw(in: NSRect(x: 0, y: (size.height - shield.size.height) / 2, width: shield.size.width, height: shield.size.height))
        for (arrow, value, y) in [("↑", compactRate(tx), 11.0), ("↓", compactRate(rx), 1.0)] {
            (arrow as NSString).draw(at: NSPoint(x: shield.size.width + 3, y: y), withAttributes: attrs) // fixed column
            let s = value as NSString
            s.draw(at: NSPoint(x: size.width - s.size(withAttributes: attrs).width, y: y), withAttributes: attrs)
        }
        return true
    }
    image.isTemplate = true // follows light/dark menu bar
    return image
}

// MARK: model

struct Sample: Identifiable {
    let id: Int
    let rx: Double, tx: Double
}

/// One connected stretch: from "connected" until the tunnel went down (dropped) or the user disconnected.
struct Session: Codable, Identifiable {
    var id = UUID()
    var profile: String
    var start: Double, end: Double // epoch seconds
    var rx: UInt64, tx: UInt64
    var dropped: Bool
    var reason: String
}

/// Shows banners even while our window is frontmost.
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationPresenter()
    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}

/// Receives sekisho:// links (Launch Services delivers them as "open URLs").
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { VPNModel.shared.open(url) }
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
    @Published var sessions: [Session] { // newest first
        didSet { defaults.set(try? JSONEncoder().encode(sessions), forKey: "sessions") }
    }

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
        sessions = defaults.data(forKey: "sessions").flatMap { try? JSONDecoder().decode([Session].self, from: $0) } ?? []
        autoConnectPending = src.bool(forKey: "connectOnLaunch")
        saveProfiles(old: profiles) // persists migrated profiles here; passwords are already in the Keychain
        defaults.set(selectedID.uuidString, forKey: "selectedProfile")
        defaults.set(connectOnLaunch, forKey: "connectOnLaunch")

        UNUserNotificationCenter.current().delegate = NotificationPresenter.shared
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }

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

    /// Profiles go to UserDefaults without passwords; changed passwords go to the Keychain.
    private func saveProfiles(old: [Profile]) {
        for p in profiles where old.first(where: { $0.id == p.id })?.password != p.password {
            Keychain.set(p.id.uuidString, p.password)
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
            if seenStatus { recordSession(from: status, to: Status()) } // helper stopped (update, uninstall)
            status = Status()
            replaceLogs = true
            seenStatus = false
            helperOutdated = false
            return
        }
        helperOutdated = e.v != protocolVersion
        if let s = e.status {
            if seenStatus {
                notifyTransition(from: status, to: s)
                recordSession(from: status, to: s)
            }
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
            autoConnectIfUntrusted() // also covers networks seen before the helper answered
        }
        if let l = e.log {
            if replaceLogs { logs = l } else { logs += l }
            replaceLogs = false
            if logs.count > 1000 { logs.removeFirst(logs.count - 1000) }
        }
    }

    // shortcut: the app records sessions, so those while it is not running are missing; move this into the helper if needed
    private func recordSession(from a: Status, to b: Status) {
        guard a.state == .connected, b.state != .connected, let since = a.since else { return }
        sessions.insert(Session(profile: a.profileName ?? "", start: since, end: Date().timeIntervalSince1970,
                                rx: a.rxBytes, tx: a.txBytes, dropped: b.state == .connecting, reason: b.message), at: 0)
        if sessions.count > 200 { sessions.removeLast(sessions.count - 200) }
    }

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
            notify(String(localized: "Connection to \(server) lost"), b.message)
        case .disconnected:
            dropped = false
            if b.untrustedCert != nil {
                notify(String(localized: "Couldn't connect to \(server)"),
                       String(localized: "The server's certificate is not trusted. Open Sekisho to review it."))
            } else if b.message.isEmpty || a.state == .connected { // user-requested, or an established tunnel ended
                notify(String(localized: "Disconnected from \(server)"), b.message)
            } else { // ended before ever connecting: resolve, TLS, auth, timeout…
                notify(String(localized: "Couldn't connect to \(server)"), b.message)
            }
        default:
            break
        }
    }

    /// One identifier per topic: a newer notification replaces the previous one in Notification Center.
    private func notify(_ title: String, _ body: String, id: String = "vpn-state") {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
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
        link.send(Request(.connect, profile: p))
    }

    func connect(_ id: UUID) {
        selectedID = id
        connect()
    }

    func disconnect() { link.send(Request(.disconnect)) }

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
            if busy { disconnect() }
        case "toggle":
            toggleVPN()
        default:
            notify(String(localized: "Unknown link"), url.absoluteString)
        }
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

    /// Connects once per newly joined network unless it is a trusted Wi-Fi. A Wi-Fi whose name macOS hides is skipped
    /// (it may be a trusted one) and judged again when Location permission reveals the name.
    private func autoConnectIfUntrusted() {
        guard autoConnectUntrusted, seenStatus, canConnect, let key = network.key, key != handledNetwork,
              !(network.onWiFi && network.ssid == nil) else { return }
        handledNetwork = key
        guard status.state == .disconnected, !trustedList.contains(network.ssid ?? "") else { return }
        connect()
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

// MARK: views

struct ContentView: View {
    @EnvironmentObject var vpn: VPNModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !vpn.helperReachable || vpn.helperOutdated {
                VStack(alignment: .leading, spacing: 6) {
                    Text(vpn.helperOutdated
                         ? "The installed root helper (sstpd) is older than this app. Update it to connect (this drops an active VPN)."
                         : "The root helper (sstpd) is not running. It creates the VPN interface and needs an admin password to install once.")
                        .font(.callout)
                    Button(vpn.helperOutdated ? "Update Helper…" : "Install Helper…") { vpn.installHelper() }
                }
            }
            if let e = vpn.installError { Text(e).font(.caption).foregroundStyle(.red) }

            HStack {
                Picker("Profile", selection: $vpn.selectedID) {
                    ForEach(vpn.profiles) { p in Text(p.name.isEmpty ? p.server : p.name).tag(p.id) }
                }
                Button { vpn.addProfile() } label: { Image(systemName: "plus") }.help("Add profile")
                Button { vpn.removeCurrentProfile() } label: { Image(systemName: "minus") }
                    .help("Remove this profile").disabled(vpn.profiles.count < 2)
                Menu {
                    Button("Import Profile…") { vpn.importProfile() }
                    Button("Export Profile…") { vpn.exportProfile() }
                } label: {
                    Image(systemName: "square.and.arrow.up.on.square")
                }
                .menuStyle(.borderlessButton).fixedSize()
                .help("Share profiles as .sekisho files (without passwords)")
            }
            .disabled(vpn.busy)

            ProfileForm(p: vpn.currentBinding).disabled(vpn.busy)

            KillSwitchPauseBanner()
            CertExpiryWarning()

            if let cert = vpn.status.untrustedCert, vpn.status.state == .disconnected {
                CertificatePrompt(sha256: cert)
            }

            HStack {
                if vpn.status.state == .connecting || vpn.status.state == .disconnecting { ProgressView().controlSize(.small) }
                Text(vpn.statusLine).foregroundStyle(.secondary).lineLimit(2)
                if let ok = vpn.status.reachable, let host = vpn.sessionProfile?.healthCheck { HealthBadge(host: host, ok: ok) }
                Spacer()
                if vpn.busy {
                    Button("Disconnect") { vpn.disconnect() }.disabled(vpn.status.state == .disconnecting)
                } else {
                    Button("Connect") { vpn.connect() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!vpn.canConnect)
                }
            }

            if vpn.status.state == .connected { TrafficView() }

            LogView(lines: vpn.logs, export: vpn.exportLogs, diagnostics: vpn.exportDiagnostics)

            HStack(spacing: 20) {
                Toggle("Launch at login", isOn: Binding(get: { vpn.launchAtLogin }, set: { vpn.setLaunchAtLogin($0) }))
                Toggle("Connect when the app starts", isOn: $vpn.connectOnLaunch)
                Spacer()
                Button("Session History") { openWindow(id: "history") }
            }
            .font(.callout)

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Connect automatically when not on a trusted Wi-Fi", isOn: $vpn.autoConnectUntrusted)
                if vpn.autoConnectUntrusted {
                    HStack {
                        TextField("Trusted Wi-Fi", text: $vpn.trustedNetworks, prompt: Text("Trusted Wi-Fi names, e.g. Office, Office-5G"))
                        if let ssid = vpn.currentSSID, !vpn.trustedList.contains(ssid) {
                            Button("Trust “\(ssid)”") { vpn.trustCurrentNetwork() }
                        }
                    }
                    .labelsHidden()
                    if vpn.wifiNameHidden {
                        Text("macOS hides the Wi-Fi name, so this network is skipped. Allow Sekisho in System Settings → Privacy & Security → Location Services.")
                            .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .font(.callout)
        }
        .padding()
        .frame(width: 540)
    }
}

struct ProfileForm: View {
    @Binding var p: Profile

    var body: some View {
        Form {
            TextField("Name", text: $p.name)
            TextField("Server", text: $p.server, prompt: Text("vpn.example.com"))
            TextField("Port", value: $p.port, format: .number.grouping(.never))
            TextField("Username", text: $p.username)
            SecureField("Password", text: $p.password)
            TextField("Split tunnel", text: $p.routes, prompt: Text("empty = all traffic; or 192.168.212.0/24, intranet.example.com"))
                .help("Subnets or hostnames to send through the VPN. Hostnames are resolved by the VPN's DNS and refreshed every 5 minutes.")
            TextField("DNS domains", text: $p.dnsDomains, prompt: Text(p.isFullTunnel ? "all DNS uses the VPN" : "e.g. collega.co.id"))
                .disabled(p.isFullTunnel)
            Toggle("Kill switch: block internet while the VPN is down", isOn: $p.killSwitch)
                .disabled(!p.isFullTunnel)
                .help("Full tunnel only. Stays on through reconnects until you disconnect.")
            Toggle("Reconnect automatically", isOn: $p.autoReconnect)
            TextField("Health check", text: $p.healthCheck, prompt: Text("optional: intranet.example.com or host:8080"))
                .help("An internal host that must accept connections through the VPN. Checked every 30 s; after 90 s unreachable the VPN reconnects (with Reconnect automatically).")
            if let pin = p.pinnedCert {
                LabeledContent("Pinned certificate") {
                    HStack {
                        Text(fingerprint(pin).prefix(23) + "…").font(.caption.monospaced()).help(fingerprint(pin))
                        Button("Forget") { p.pinnedCert = nil }
                    }
                }
            }
            if !p.server.isEmpty, let problem = p.problem {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
        }
    }
}

struct CertificatePrompt: View {
    @EnvironmentObject var vpn: VPNModel
    let sha256: String

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Label("macOS does not trust this server's certificate", systemImage: "exclamationmark.shield").bold()
                Text("SHA-256  " + fingerprint(sha256))
                    .font(.caption.monospaced()).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true) // the whole fingerprint must be comparable
                Text("Trust it only if this fingerprint matches the one from your VPN administrator. It will be pinned: if the server later presents a different certificate, the connection is refused.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Trust This Certificate and Connect") { vpn.trustAndConnect(sha256) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct TrafficView: View {
    @EnvironmentObject var vpn: VPNModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 18) {
                Label("\(speed(vpn.status.rxRate))  (\(bytes(Double(vpn.status.rxBytes))))", systemImage: "arrow.down.circle")
                    .foregroundStyle(.blue)
                Label("\(speed(vpn.status.txRate))  (\(bytes(Double(vpn.status.txBytes))))", systemImage: "arrow.up.circle")
                    .foregroundStyle(.green)
                Spacer()
                if let ms = vpn.status.latency { Label(latency(ms), systemImage: "stopwatch").help("Round trip to the VPN server") }
                if let since = vpn.status.since { Label(duration(since: since), systemImage: "clock") }
            }
            .monospacedDigit()
            .help("Current speed (total this session)")

            Chart(vpn.history) { s in
                LineMark(x: .value("Time", s.id), y: .value("Speed", s.rx), series: .value("Direction", "Download"))
                    .foregroundStyle(.blue)
                LineMark(x: .value("Time", s.id), y: .value("Speed", s.tx), series: .value("Direction", "Upload"))
                    .foregroundStyle(.green)
            }
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { v in
                    AxisGridLine()
                    AxisValueLabel { if let d = v.as(Double.self) { Text(compactRate(d)) } }
                }
            }
            .frame(height: 70)
        }
    }
}

struct LogView: View {
    let lines: [String]
    let export: () -> Void
    let diagnostics: () -> Void

    var body: some View {
        GroupBox {
            ScrollViewReader { proxy in
                ScrollView {
                    // one Text, so a selection can span lines (separate Texts select one line at a time)
                    Text(lines.joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(4)
                    Color.clear.frame(height: 1).id("end")
                }
                .frame(height: 150)
                .onAppear { proxy.scrollTo("end", anchor: .bottom) }
                .onChange(of: lines.count) { _ in proxy.scrollTo("end", anchor: .bottom) } // follow new lines
            }
        } label: {
            HStack {
                Text("Log")
                Spacer()
                Button("Copy All") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(lines.joined(separator: "\n") + "\n", forType: .string)
                }
                .controlSize(.small).disabled(lines.isEmpty)
                Button("Export…", action: export).controlSize(.small).disabled(lines.isEmpty)
                Button("Diagnostics…", action: diagnostics).controlSize(.small)
                    .help("Save the log with routes, DNS and interface details for your VPN administrator")
            }
        }
    }
}

/// Menu bar panel: live status and speeds, one switch to connect/disconnect.
struct MenuPanel: View {
    @EnvironmentObject var vpn: VPNModel
    @Environment(\.openWindow) private var openWindow

    private var connected: Bool { vpn.status.state == .connected }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: connected ? "lock.shield.fill" : "lock.shield")
                    .font(.title2)
                    .foregroundStyle(connected ? Color.green : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(vpn.status.profileName ?? vpn.current.name).font(.headline)
                    Text(vpn.statusLine).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Toggle("VPN", isOn: Binding(get: { vpn.busy }, set: { $0 ? vpn.connect() : vpn.disconnect() }))
                    .toggleStyle(.switch)
                    .help("Connect or disconnect (⌃⌥⌘V from any app)")
                    .labelsHidden()
                    .disabled(vpn.busy ? vpn.status.state == .disconnecting : !vpn.canConnect)
            }

            KillSwitchPauseBanner()
            CertExpiryWarning()

            if connected {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow {
                        Label(speed(vpn.status.rxRate), systemImage: "arrow.down").foregroundStyle(.blue)
                        Text(bytes(Double(vpn.status.rxBytes))).foregroundStyle(.secondary)
                    }
                    GridRow {
                        Label(speed(vpn.status.txRate), systemImage: "arrow.up").foregroundStyle(.green)
                        Text(bytes(Double(vpn.status.txBytes))).foregroundStyle(.secondary)
                    }
                    if let since = vpn.status.since {
                        GridRow {
                            Label(duration(since: since), systemImage: "clock")
                            Text(vpn.status.localIP ?? "").foregroundStyle(.secondary)
                        }
                    }
                    if let ms = vpn.status.latency {
                        GridRow {
                            Label(latency(ms), systemImage: "stopwatch")
                            Text("latency").foregroundStyle(.secondary)
                        }
                    }
                    if let ok = vpn.status.reachable, let host = vpn.sessionProfile?.healthCheck {
                        GridRow {
                            HealthBadge(host: host, ok: ok)
                            Text("health check").foregroundStyle(.secondary)
                        }
                    }
                }
                .font(.callout.monospacedDigit())
            } else if vpn.profiles.count > 1 {
                Picker("Profile", selection: $vpn.selectedID) {
                    ForEach(vpn.profiles) { p in Text(p.name.isEmpty ? p.server : p.name).tag(p.id) }
                }
                .disabled(vpn.busy)
            }

            Divider()
            HStack {
                Button("Open Sekisho") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                Button("About") { showAbout() }
                Button("Quit") { NSApp.terminate(nil) } // the VPN stays up; only the GUI exits
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(width: 300)
    }
}

/// ✓/✗ for the health check host of the running session.
struct HealthBadge: View {
    let host: String
    let ok: Bool

    var body: some View {
        Label(host, systemImage: ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
            .foregroundStyle(ok ? .green : .red)
            .lineLimit(1)
            .help(ok ? "Reachable through the VPN" : "Not reachable through the VPN")
    }
}

/// While reconnecting behind the kill switch: offers a 2-minute pause so a Wi-Fi login page can load.
struct KillSwitchPauseBanner: View {
    @EnvironmentObject var vpn: VPNModel

    var body: some View {
        if let until = vpn.status.killSwitchPausedUntil {
            Label("Kill switch paused until \(Date(timeIntervalSince1970: until).formatted(date: .omitted, time: .shortened)) for the network login page",
                  systemImage: "pause.circle")
                .font(.caption).foregroundStyle(.orange)
        } else if vpn.killSwitchHolding {
            VStack(alignment: .leading, spacing: 4) {
                Text("Can't reach the VPN server. If this Wi-Fi needs a login page (hotel, café), the kill switch is blocking it.")
                    .font(.caption).fixedSize(horizontal: false, vertical: true)
                Button("Open Login Page (pause kill switch for 2 min)") { vpn.pauseKillSwitch() }.controlSize(.small)
            }
        }
    }
}

struct CertExpiryWarning: View {
    @EnvironmentObject var vpn: VPNModel

    var body: some View {
        if let warning = vpn.certWarning {
            VStack(alignment: .leading, spacing: 2) {
                Label(warning, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(vpn.certAdvice).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption)
        }
    }
}

struct HistoryView: View {
    @EnvironmentObject var vpn: VPNModel

    var body: some View {
        VStack(alignment: .leading) {
            Table(vpn.sessions) {
                TableColumn("Started") { s in Text(Date(timeIntervalSince1970: s.start).formatted(date: .abbreviated, time: .shortened)) }
                TableColumn("Profile", value: \.profile)
                TableColumn("Duration") { s in Text(duration(s.end - s.start)).monospacedDigit() }
                TableColumn("Down") { s in Text(bytes(Double(s.rx))).monospacedDigit() }
                TableColumn("Up") { s in Text(bytes(Double(s.tx))).monospacedDigit() }
                TableColumn("Ended") { s in ending(s).help(s.reason) }
            }
            HStack {
                let drops = vpn.sessions.filter(\.dropped).count
                Text("\(vpn.sessions.count) sessions, \(drops) dropped, ↓ \(bytes(Double(vpn.sessions.map(\.rx).reduce(0, +)))) ↑ \(bytes(Double(vpn.sessions.map(\.tx).reduce(0, +))))")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear History") { vpn.sessions.removeAll() }.disabled(vpn.sessions.isEmpty)
            }
        }
        .padding()
        .frame(minWidth: 640, minHeight: 300)
    }

    private func ending(_ s: Session) -> Text {
        if s.dropped { return Text("Dropped: \(s.reason)") }
        return s.reason.isEmpty ? Text("Disconnected") : Text(s.reason)
    }
}
