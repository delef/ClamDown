// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Wakeup",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "WakeupShared"),
        .testTarget(name: "WakeupSharedTests", dependencies: ["WakeupShared"]),
        .target(name: "WakeupAppKit", dependencies: ["WakeupShared"]),
        .testTarget(name: "WakeupAppKitTests", dependencies: ["WakeupAppKit"]),
        .target(name: "WakeupHelperKit", dependencies: ["WakeupShared"]),
        .testTarget(name: "WakeupHelperKitTests", dependencies: ["WakeupHelperKit"]),
    ]
)
