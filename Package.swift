// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "BLEChatKit",
    platforms: [
        .iOS(.v15),
        .macOS(.v12)
    ],
    products: [
        .library(
            name: "BLEChatKit",
            targets: ["BLEChatKit"]
        )
    ],
    targets: [
        .target(
            name: "BLEChatKit"
        ),
        .testTarget(
            name: "BLEChatKitTests",
            dependencies: ["BLEChatKit"]
        )
    ])
