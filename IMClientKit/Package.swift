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
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", .upToNextMajor(from: "7.10.0")),
    ],
    targets: [
        .target(
            name: "IMClientKit",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(
            name: "IMClientKitTests",
            dependencies: [
                "IMClientKit",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
    ]
)
