import Charts
import ServiceManagement
import Sparkle
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications
import SSTPKit

@main
struct SSTPClientApp: App {
    @StateObject private var vpn = VPNModel()
    // feed and EdDSA key come from Info.plist (SUFeedURL, SUPublicEDKey: scripts/build-app.sh)
    private let updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    var body: some Scene {
        Window("Sekisho", id: "main") {
            ContentView().environmentObject(vpn)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Sekisho") { showAbout() }
                Button("Check for Updates…") { updater.checkForUpdates(nil) }
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
    let credits = NSMutableAttributedString(string: "SSTP VPN client for macOS\n", attributes: [
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

func duration(since: Double) -> String {
    let s = max(0, Int(Date().timeIntervalSince1970 - since))
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

/// Shows banners even while our window is frontmost.
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationPresenter()
    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}

@MainActor
final class VPNModel: ObservableObject {
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

    private let defaults = UserDefaults.standard
    private let link = DaemonLink()
    private var replaceLogs = true // the first event of each daemon connection carries its whole backlog
    private var seenStatus = false // no notifications for the state we find on (re)connecting to the daemon
    private var dropped = false // the last connection fell over on its own; the next "connected" is a reconnect
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
            status = Status()
            replaceLogs = true
            seenStatus = false
            helperOutdated = false
            return
        }
        helperOutdated = e.v != protocolVersion
        if let s = e.status {
            if seenStatus { notifyTransition(from: status, to: s) }
            seenStatus = true
            status = s
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

    private func notifyTransition(from a: Status, to b: Status) {
        guard a.state != b.state else { return }
        let name = b.profileName ?? a.profileName ?? current.name // statuses after a session ends carry no profile
        let server = profiles.first { $0.name == name }?.server ?? name
        switch b.state {
        case .connected:
            notify(dropped ? "Reconnected to \(server)" : "Connected to \(server)", b.localIP.map { "VPN address \($0)" } ?? "")
            dropped = false
        case .connecting where a.state == .connected:
            dropped = true
            notify("Connection to \(server) lost", b.message)
        case .disconnected:
            dropped = false
            if b.untrustedCert != nil {
                notify("Couldn't connect to \(server)", "The server's certificate is not trusted. Open Sekisho to review it.")
            } else if b.message.isEmpty || a.state == .connected { // user-requested, or an established tunnel ended
                notify("Disconnected from \(server)", b.message)
            } else { // ended before ever connecting: resolve, TLS, auth, timeout…
                notify("Couldn't connect to \(server)", b.message)
            }
        default:
            break
        }
    }

    private func notify(_ title: String, _ body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        // one identifier: each state replaces the previous one in Notification Center instead of piling up
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "vpn-state", content: c, trigger: nil))
    }

    // MARK: actions

    var busy: Bool { status.state != .disconnected }
    var canConnect: Bool { helperReachable && !helperOutdated && current.problem == nil }

    var statusLine: String {
        guard helperReachable else { return "Helper not running" }
        guard !helperOutdated else { return "Helper needs an update" }
        switch status.state {
        case .connected: return "Connected" + (status.localIP.map { " — \($0)" } ?? "")
        case .connecting, .disconnecting: return status.message
        case .disconnected: return status.message.isEmpty ? "Disconnected" : status.message
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

    /// Global hotkey: one key to bring the VPN up or down.
    func toggleVPN() {
        if busy { disconnect() } else if canConnect { connect() }
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
            installError = "Launch at login: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func exportLogs() {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Sekisho-\(stamp.string(from: Date())).log"
        panel.allowedContentTypes = [UTType(filenameExtension: "log") ?? .plainText]
        panel.isExtensionHidden = false // macOS hides it by default with Finder's setting; the user wants to see .log
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try (logs.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        } catch {
            installError = "Export failed: \(error.localizedDescription)"
        }
    }

    /// Runs the bundled installer as root via the standard macOS admin password prompt.
    func installHelper() {
        guard let dir = Bundle.main.resourceURL?.path else { return }
        func shq(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let cmd = "/bin/sh \(shq(dir + "/install-daemon.sh")) \(shq(dir + "/sstpd"))"
        let escaped = cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        installError = nil
        Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", script]
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

// MARK: views

struct ContentView: View {
    @EnvironmentObject var vpn: VPNModel

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
            }
            .disabled(vpn.busy)

            ProfileForm(p: vpn.currentBinding).disabled(vpn.busy)

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

            LogView(lines: vpn.logs) { vpn.exportLogs() }

            HStack(spacing: 20) {
                Toggle("Launch at login", isOn: Binding(get: { vpn.launchAtLogin }, set: { vpn.setLaunchAtLogin($0) }))
                Toggle("Connect when the app starts", isOn: $vpn.connectOnLaunch)
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
