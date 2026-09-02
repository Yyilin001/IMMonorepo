// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "IMV2ClientKit",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [.library(name: "IMV2ClientKit", targets: ["IMV2ClientKit"])],
    dependencies: [
        .package(path: "../IMV2Core"),
        .package(path: "../IMV2Compression"),
        .package(url: "https://github.com/groue/GRDB.swift.git", .upToNextMajor(from: "7.10.0")),
        .package(url: "https://github.com/apple/swift-protobuf.git", .upToNextMajor(from: "1.29.0")),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.9.0"),
    ],
    targets: [
        .target(
            name: "IMV2ClientKit",
            dependencies: [
                "IMV2Core",
                "IMV2Compression",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .testTarget(
            name: "IMV2ClientKitTests",
            dependencies: ["IMV2ClientKit", .product(name: "GRDB", package: "GRDB.swift")]
        ),
    ]
)
