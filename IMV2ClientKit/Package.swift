// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "IMV2ClientKit",
    platforms: [.iOS(.v17), .macOS(.v15)],
    products: [
        .library(name: "IMV2ClientKit", targets: ["IMV2ClientKit"]),
        .library(name: "IMV2ClientRuntime", targets: ["IMV2ClientRuntime"]),
        .library(name: "IMV2ClientNetwork", targets: ["IMV2ClientNetwork"]),
        .library(name: "IMV2ClientAndroid", targets: ["IMV2ClientAndroid"]),
        .library(name: "IMV2SharedSDK", type: .dynamic, targets: ["IMV2SharedSDK", "CIMV2SharedSDK"]),
    ],
    dependencies: [
        .package(path: "../IMV2Core"),
        .package(path: "../MessageSubstringSearch"),
        .package(path: "../IMV2Compression"),
        .package(url: "https://github.com/groue/GRDB.swift.git", .upToNextMajor(from: "7.10.0")),
        .package(url: "https://github.com/apple/swift-protobuf.git", .upToNextMajor(from: "1.29.0")),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.9.0"),
    ],
    targets: [
        .target(name: "CIMV2SharedSDK"),
        .target(name: "IMV2SharedSDK", dependencies: ["IMV2SharedRuntime",
            .target(name: "IMV2SharedAndroid", condition: .when(platforms: [.android])),
            .target(name: "IMV2SharedApple", condition: .when(platforms: [.iOS, .macOS]))]),
        .target(name: "IMV2SharedRuntime", dependencies: ["IMV2ClientRuntime", "IMV2Core", .product(name: "Crypto", package: "swift-crypto")]),
        .target(name: "IMV2SharedAndroid", dependencies: ["IMV2SharedRuntime", "IMV2ClientAndroid"]),
        .target(name: "IMV2SharedApple", dependencies: ["IMV2SharedRuntime", "IMV2ClientApple"]),
        .target(name: "CIMV2AndroidPlatform"),
        .target(name: "IMV2ClientAndroid", dependencies: ["IMV2ClientRuntime", "IMV2Core", "CIMV2AndroidPlatform"]),
        .target(name: "IMV2ClientPlatform", dependencies: [.product(name: "Crypto", package: "swift-crypto")]),
        .target(name: "IMV2ClientNetwork", dependencies: ["IMV2Core", "IMV2ClientPlatform"]),
        .target(name: "IMV2ClientApple", dependencies: ["IMV2ClientRuntime", "IMV2ClientNetwork", "IMV2ClientPlatform", "IMV2Core"]),
        .target(name: "IMV2ClientKit", dependencies: ["IMV2ClientRuntime", "IMV2ClientApple", "IMV2SharedRuntime"], path: "Sources/IMV2ClientFacade"),
        .target(
            name: "IMV2ClientRuntime",
            dependencies: [
                "IMV2ClientNetwork", "IMV2ClientPlatform",
                "IMV2Core",
                "MessageSubstringSearch",
                "IMV2Compression",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Sources/IMV2ClientKit"
        ),
        .testTarget(name: "IMV2SharedRuntimeTests", dependencies: ["IMV2SharedRuntime", "IMV2SharedSDK", "IMV2SharedApple", "IMV2ClientRuntime", "IMV2ClientNetwork"]),
        .testTarget(
            name: "IMV2ClientKitTests",
            dependencies: ["IMV2ClientKit", "IMV2ClientRuntime", "IMV2ClientNetwork", "IMV2ClientApple", .product(name: "GRDB", package: "GRDB.swift")]
        ),
    ]
)
