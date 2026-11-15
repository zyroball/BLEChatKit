// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "BLEChatKit",
    platforms: [
        .iOS(.v15)
    ],
    products: [
        .library(
            name: "BLEChatKit",
            targets: ["BLEChatKit"]
        )
    ],
    targets: [
        .target(
            name: "BLEChatKit",
            path: "Sources/BLEChatKit"
        ),
        .testTarget(
            name: "BLEChatKitTests",
            dependencies: ["BLEChatKit"],
            path: "Tests/BLEChatKitTests"
        )
    ]
)
