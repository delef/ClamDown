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
        // The ClamDown look: tokens, glass-or-classic components and building blocks for Settings and setup.
        // SwiftUI and AppKit only; it knows nothing about settings, the helper or the controller.
        .target(name: "ClamDownUI"),
        .testTarget(name: "ClamDownUITests", dependencies: ["ClamDownUI"]),
        .testTarget(name: "ClamDownSharedTests", dependencies: ["ClamDownShared"]),
        .target(name: "ClamDownSensors", dependencies: ["ClamDownShared"]),
        .testTarget(name: "ClamDownSensorsTests", dependencies: ["ClamDownSensors", "ClamDownShared"],
                    resources: [.copy("Fixtures")]),
        .target(name: "ClamDownAppKit", dependencies: ["ClamDownShared", "ClamDownSensors"]),
        .testTarget(name: "ClamDownAppKitTests", dependencies: ["ClamDownAppKit", "ClamDownSensors"]),
        .target(name: "ClamDownHelperKit", dependencies: ["ClamDownShared", "ClamDownSensors"]),
        .testTarget(name: "ClamDownHelperKitTests", dependencies: ["ClamDownHelperKit", "ClamDownSensors"],
                    resources: [.copy("Fixtures")]),
        .executableTarget(name: "ClamDownHelper", dependencies: ["ClamDownHelperKit", "ClamDownShared", "ClamDownSensors"]),
        // A root-only debug tool for device checks (fan spin-up, hottest core, thermal level). Never bundled:
        // scripts/build-app.sh builds and copies only ClamDown and ClamDownHelper.
        .executableTarget(name: "ClamDownFanProbe", dependencies: ["ClamDownSensors", "ClamDownShared"]),
        .executableTarget(
            name: "ClamDown",
            dependencies: ["ClamDownAppKit", "ClamDownShared", "ClamDownSensors", "ClamDownUI", .product(name: "Sparkle", package: "Sparkle")],
            // The app bundle carries Sparkle.framework in Contents/Frameworks (see scripts/build-app.sh).
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
    ]
)
