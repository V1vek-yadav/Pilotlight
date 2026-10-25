// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Pilotlight",
    platforms: [.macOS(.v14)],
    targets: [
        // the menu bar app
        .executableTarget(name: "Pilotlight", path: "Sources/Pilotlight"),
        // the hook command Claude Code runs; Darwin only, so it starts in a few milliseconds
        .executableTarget(name: "pilot", path: "Sources/pilot"),
    ]
)
