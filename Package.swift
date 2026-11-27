// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Sekisho",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        // SSTP + PPP + utun + IPC types, shared by daemon and GUI
        .target(name: "SSTPKit"),
        // Root launchd daemon: owns the tunnel
        .executableTarget(name: "sstpd", dependencies: ["SSTPKit"]),
        // SwiftUI menu bar app: talks to the daemon over a unix socket; Sparkle for updates from GitHub Releases
        .executableTarget(name: "SSTPClient", dependencies: ["SSTPKit", .product(name: "Sparkle", package: "Sparkle")]),
        // `swift run selftest`: RFC vectors + scripted PPP exchange (XCTest/Testing are not in plain Command Line Tools)
        .executableTarget(name: "selftest", dependencies: ["SSTPKit"]),
    ]
)
