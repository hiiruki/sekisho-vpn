import AppKit

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

