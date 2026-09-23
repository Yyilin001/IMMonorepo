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
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", "3.9.0"..<"5.0.0"),
    ],
    targets: [
        .target(
            name: "IMV2Core",
            dependencies: [.product(name: "Crypto", package: "swift-crypto")]
        ),
        .testTarget(name: "IMV2CoreTests", dependencies: ["IMV2Core"]),
    ]
)
