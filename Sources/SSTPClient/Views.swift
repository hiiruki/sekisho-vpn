import Charts
import SwiftUI
import SSTPKit

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

