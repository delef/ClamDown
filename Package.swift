// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Wakeup",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "WakeupShared"),
        .testTarget(name: "WakeupSharedTests", dependencies: ["WakeupShared"]),
    ]
)
