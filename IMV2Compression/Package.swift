// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "IMV2Compression",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "IMV2Compression", targets: ["IMV2Compression"]),
    ],
    targets: [
        .systemLibrary(
            name: "CZlib",
            pkgConfig: "zlib",
            providers: [
                .apt(["zlib1g-dev"]),
                .brew(["zlib"]),
            ]
        ),
        .target(name: "IMV2Compression", dependencies: ["CZlib"]),
        .testTarget(name: "IMV2CompressionTests", dependencies: ["IMV2Compression"]),
    ]
)
