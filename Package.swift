// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Tiler",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure logic: layout tree, geometry, config, key parsing. No AppKit, no AX.
        .target(name: "TilerCore"),
        // The menu bar app: AX, SkyLight, hotkeys, status item, Settings, shortcuts overlay.
        .executableTarget(
            name: "Tiler",
            dependencies: ["TilerCore"],
            linkerSettings: [
                .unsafeFlags(["-F/System/Library/PrivateFrameworks"]),
                .linkedFramework("SkyLight"),
            ]
        ),
        .testTarget(name: "TilerCoreTests", dependencies: ["TilerCore"]),
    ]
)
