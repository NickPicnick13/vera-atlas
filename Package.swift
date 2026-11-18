// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "VeraDesktopWidget",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "VeraDesktopWidget",
            path: "Sources/VeraDesktopWidget"
        )
    ]
)
