// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacPulse",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MacPulseCore", targets: ["MacPulseCore"]),
        .executable(name: "macpulsed", targets: ["macpulsed"]),
        .executable(name: "MacPulseApp", targets: ["MacPulseApp"]),
    ],
    targets: [
        // Shared by the root daemon and the menu bar app. Keep this free of
        // anything privileged -- the app links it too.
        .target(
            name: "MacPulseCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "macpulsed",
            dependencies: ["MacPulseCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "MacPulseApp",
            dependencies: ["MacPulseCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
