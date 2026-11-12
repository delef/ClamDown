// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClamDown",
    platforms: [.macOS(.v13)],
    dependencies: [
        // Updates from GitHub Releases. Pinned: moving to a new Sparkle version is a reviewed change.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        .target(name: "ClamDownShared"),
        .testTarget(name: "ClamDownSharedTests", dependencies: ["ClamDownShared"]),
        .target(name: "ClamDownSensors", dependencies: ["ClamDownShared"]),
        .target(name: "ClamDownAppKit", dependencies: ["ClamDownShared", "ClamDownSensors"]),
        .testTarget(name: "ClamDownAppKitTests", dependencies: ["ClamDownAppKit", "ClamDownSensors"]),
        .target(name: "ClamDownHelperKit", dependencies: ["ClamDownShared", "ClamDownSensors"]),
        .testTarget(name: "ClamDownHelperKitTests", dependencies: ["ClamDownHelperKit", "ClamDownSensors"]),
        .executableTarget(name: "ClamDownHelper", dependencies: ["ClamDownHelperKit", "ClamDownShared", "ClamDownSensors"]),
        .executableTarget(
            name: "ClamDown",
            dependencies: ["ClamDownAppKit", "ClamDownShared", "ClamDownSensors", .product(name: "Sparkle", package: "Sparkle")],
            // The app bundle carries Sparkle.framework in Contents/Frameworks (see scripts/build-app.sh).
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
    ]
)
