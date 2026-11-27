import Carbon.HIToolbox
import CoreLocation
import CoreWLAN
import Network

/// ⌃⌥⌘V from any app. Carbon hot keys need no Accessibility permission (an NSEvent global monitor would).
final class HotKey {
    nonisolated(unsafe) private static var action: () -> Void = {}
    private var ref: EventHotKeyRef?

    init(action: @escaping () -> Void) {
        HotKey.action = action // the C callback cannot capture, so it reaches the action through a static
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in HotKey.action(); return noErr }, 1, &spec, nil, nil)
        RegisterEventHotKey(UInt32(kVK_ANSI_V), UInt32(controlKey | optionKey | cmdKey),
                            EventHotKeyID(signature: 0x534B_5348, id: 1), GetApplicationEventTarget(), 0, &ref) // 'SKSH'
    }
}

/// The physical network the Mac is on, for auto-connect. The VPN's own utun interface is ignored, so connecting
/// or disconnecting never looks like a network change. Callbacks arrive on the main queue.
final class NetworkWatcher: NSObject, CLLocationManagerDelegate {
    var onChange: () -> Void = {}
    /// Changes only when the network does; nil = offline.
    private(set) var key: String?
    private(set) var onWiFi = false
    /// Wi-Fi name; nil off Wi-Fi, and on Wi-Fi while macOS hides it (no Location permission).
    private(set) var ssid: String?

    private let monitor = NWPathMonitor()
    private let location = CLLocationManager()
    private var path: NWPath?

    override init() {
        super.init()
        location.delegate = self
        monitor.pathUpdateHandler = { [weak self] in
            self?.path = $0
            self?.refresh()
        }
        monitor.start(queue: .main)
    }

    /// Shows the Location prompt once; macOS reveals Wi-Fi names only to apps it allows.
    func requestWiFiName() {
        if location.authorizationStatus == .notDetermined { location.requestWhenInUseAuthorization() }
    }

    func locationManagerDidChangeAuthorization(_: CLLocationManager) { refresh() }

    private func refresh() {
        let iface = path?.status == .satisfied ? path?.availableInterfaces.first { $0.type != .other && $0.type != .loopback } : nil
        onWiFi = iface?.type == .wifi
        ssid = onWiFi ? CWWiFiClient.shared().interface()?.ssid() : nil
        key = iface.map { "\($0.name) \(ssid ?? "")" }
        onChange()
    }
}
