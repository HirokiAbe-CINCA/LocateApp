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
        .executable(name: "LocateAppCoreChecks", targets: ["LocateAppCoreChecks"])
    ],
    targets: [
        .target(name: "LocateAppCore"),
        .executableTarget(
            name: "LocateApp",
            dependencies: ["LocateAppCore"]
        ),
        .executableTarget(
            name: "LocateAppCoreChecks",
            dependencies: ["LocateAppCore"]
        )
    ]
)
