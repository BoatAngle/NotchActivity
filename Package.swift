// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NotchActivity",
    platforms: [.macOS(.v14)],
    targets: [
        // The menu bar app. `make app` wraps the binary in NotchActivity.app.
        .executableTarget(name: "NotchActivity", path: "Sources/NotchActivity"),
        // `notch`: command-line client that drives the island through its URL scheme.
        .executableTarget(name: "notch", path: "Sources/notch"),
    ]
)
