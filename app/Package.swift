// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Kopie",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "Kopie", targets: ["Voxscribe"]),
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
