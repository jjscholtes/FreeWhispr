// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Voxscribe",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "Voxscribe", targets: ["Voxscribe"]),
    ],
    targets: [
        .executableTarget(
            name: "Voxscribe"
        ),
        .testTarget(
            name: "VoxscribeTests",
            dependencies: ["Voxscribe"]
        ),
    ]
)
