import AppKit
import Carbon.HIToolbox
import CoreLocation
import CoreWLAN
import Network

/// A global shortcut as recorded: key code, modifiers (NSEvent flags) and how it was shown.
struct Shortcut: Codable, Equatable {
    var keyCode: UInt16
    var modifiers: UInt
    var label: String

    static let standard = Shortcut(keyCode: UInt16(kVK_ANSI_V),
                                   modifiers: NSEvent.ModifierFlags([.control, .option, .command]).rawValue, label: "⌃⌥⌘V")

    /// From a key press; nil without ⌘, ⌥ or ⌃ (a plain key would fire while typing anywhere).
    init?(_ e: NSEvent) {
        let m = e.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !m.isDisjoint(with: [.command, .option, .control]) else { return nil }
        let key: String
        switch Int(e.keyCode) {
        case kVK_Space: key = "Space"
        case kVK_Return: key = "↩"
        case kVK_Tab: key = "⇥"
        default:
            let c = e.characters(byApplyingModifiers: [])?.uppercased() ?? ""
            // function and arrow keys come as private-use characters
            key = c.unicodeScalars.contains { (0xF700...0xF8FF).contains($0.value) } || c.isEmpty ? "#\(e.keyCode)" : c
        }
        let mods = (m.contains(.control) ? "⌃" : "") + (m.contains(.option) ? "⌥" : "") + (m.contains(.shift) ? "⇧" : "") + (m.contains(.command) ? "⌘" : "")
        self.init(keyCode: e.keyCode, modifiers: m.rawValue, label: mods + key)
    }

    init(keyCode: UInt16, modifiers: UInt, label: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.label = label
    }
}

/// The global shortcut. Carbon hot keys need no Accessibility permission (an NSEvent global monitor would).
final class HotKey {
    nonisolated(unsafe) private static var action: () -> Void = {}
    private var ref: EventHotKeyRef?

    init(action: @escaping () -> Void) {
        HotKey.action = action // the C callback cannot capture, so it reaches the action through a static
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in HotKey.action(); return noErr }, 1, &spec, nil, nil)
    }

    /// nil turns it off; false when the system refuses the combination.
    @discardableResult
    func set(_ s: Shortcut?) -> Bool {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        guard let s else { return true }
        let m = NSEvent.ModifierFlags(rawValue: s.modifiers)
        let carbon = (m.contains(.command) ? cmdKey : 0) | (m.contains(.option) ? optionKey : 0)
            | (m.contains(.control) ? controlKey : 0) | (m.contains(.shift) ? shiftKey : 0)
        return RegisterEventHotKey(UInt32(s.keyCode), UInt32(carbon), EventHotKeyID(signature: 0x534B_5348, id: 1), // 'SKSH'
                                   GetApplicationEventTarget(), 0, &ref) == noErr
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
