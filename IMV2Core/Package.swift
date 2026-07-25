// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "IMV2Core",
    platforms: [
        .iOS(.v17),
        .macOS(.v15),
    ],
    products: [
        .library(name: "IMV2Core", targets: ["IMV2Core"]),
    ],
    targets: [
        .target(name: "IMV2Core"),
        .testTarget(name: "IMV2CoreTests", dependencies: ["IMV2Core"]),
    ]
)
