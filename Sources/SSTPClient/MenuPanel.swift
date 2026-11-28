import SwiftUI
import SSTPKit

/// Menu bar panel: live status and speeds, one switch to connect/disconnect.
struct MenuPanel: View {
    @EnvironmentObject var vpn: VPNModel
    @Environment(\.openWindow) private var openWindow

    private var connected: Bool { vpn.status.state == .connected }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: connected ? "lock.shield.fill" : "lock.shield")
                    .accessibilityHidden(true) // the status line next to it says the same
                    .font(.title2)
                    .foregroundStyle(connected ? Color.green : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(vpn.status.profileName ?? vpn.current.name).font(.headline)
                    Text(vpn.statusLine).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Toggle("VPN", isOn: Binding(get: { vpn.busy }, set: { $0 ? vpn.connect() : vpn.disconnect() }))
                    .toggleStyle(.switch)
                    .help(vpn.shortcut.map { String(localized: "Connect or disconnect (\($0.label) from any app)") } ?? String(localized: "Connect or disconnect"))
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
                if vpn.profiles.count > 1 {
                    Menu("Switch to") {
                        ForEach(vpn.profiles.filter { $0.id != vpn.sessionProfile?.id }) { p in
                            Button(p.name.isEmpty ? p.server : p.name) { vpn.switchTo(p.id) }
                        }
                    }
                    .fixedSize()
                }
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
                Button("Quit") { NSApp.terminate(nil) } // disconnects first (AppDelegate.applicationShouldTerminate)
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(width: 300)
    }
}

