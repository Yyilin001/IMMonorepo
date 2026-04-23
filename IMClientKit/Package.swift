// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "IMClientKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "IMClientKit",
            targets: ["IMClientKit"]
        ),
    ],
    targets: [
        .target(
            name: "IMClientKit"
        ),
        .testTarget(
            name: "IMClientKitTests",
            dependencies: ["IMClientKit"]
        ),
    ]
)
