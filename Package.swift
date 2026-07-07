// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "LocateApp",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "LocateAppCore", targets: ["LocateAppCore"]),
        .executable(name: "LocateApp", targets: ["LocateApp"]),
        .executable(name: "LocateTunneldDaemon", targets: ["LocateTunneldDaemon"]),
        .executable(name: "LocateAppCoreChecks", targets: ["LocateAppCoreChecks"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.3")
    ],
    targets: [
        .target(name: "LocateAppCore"),
        .executableTarget(
            name: "LocateApp",
            dependencies: [
                "LocateAppCore",
                .product(name: "Sparkle", package: "Sparkle")
            ]
        ),
        .executableTarget(
            name: "LocateTunneldDaemon",
            dependencies: ["LocateAppCore"]
        ),
        .executableTarget(
            name: "LocateAppCoreChecks",
            dependencies: ["LocateAppCore"]
        )
    ]
)
