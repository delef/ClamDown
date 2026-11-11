// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClamDown",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "ClamDownShared"),
        .testTarget(name: "ClamDownSharedTests", dependencies: ["ClamDownShared"]),
        .target(name: "ClamDownAppKit", dependencies: ["ClamDownShared"]),
        .testTarget(name: "ClamDownAppKitTests", dependencies: ["ClamDownAppKit"]),
        .target(name: "ClamDownHelperKit", dependencies: ["ClamDownShared"]),
        .testTarget(name: "ClamDownHelperKitTests", dependencies: ["ClamDownHelperKit"]),
        .executableTarget(name: "ClamDownHelper", dependencies: ["ClamDownHelperKit", "ClamDownShared"]),
        .executableTarget(name: "ClamDown", dependencies: ["ClamDownAppKit", "ClamDownShared"]),
    ]
)
