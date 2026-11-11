// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClamDown",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "ClamDownShared"),
        .testTarget(name: "ClamDownSharedTests", dependencies: ["ClamDownShared"]),
        .target(name: "ClamDownSensors", dependencies: ["ClamDownShared"]),
        .target(name: "ClamDownAppKit", dependencies: ["ClamDownShared", "ClamDownSensors"]),
        .testTarget(name: "ClamDownAppKitTests", dependencies: ["ClamDownAppKit", "ClamDownSensors"]),
        .target(name: "ClamDownHelperKit", dependencies: ["ClamDownShared", "ClamDownSensors"]),
        .testTarget(name: "ClamDownHelperKitTests", dependencies: ["ClamDownHelperKit", "ClamDownSensors"]),
        .executableTarget(name: "ClamDownHelper", dependencies: ["ClamDownHelperKit", "ClamDownShared", "ClamDownSensors"]),
        .executableTarget(name: "ClamDown", dependencies: ["ClamDownAppKit", "ClamDownShared", "ClamDownSensors"]),
    ]
)
