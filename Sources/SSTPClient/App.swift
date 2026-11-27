import SwiftUI
import Sparkle

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
                    .accessibilityLabel(Text("VPN connected, down \(speed(vpn.status.rxRate)), up \(speed(vpn.status.txRate))"))
            } else {
                Image(systemName: "lock.shield").accessibilityLabel(Text("VPN disconnected"))
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

/// Receives sekisho:// links (Launch Services delivers them as "open URLs").
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { VPNModel.shared.open(url) }
    }
}

