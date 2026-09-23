// swift-tools-version:6.1
// Production targets and dependency ranges from apple/swift-distributed-actors
// revision 50e789fbb6db9a9869a60b1915e659bd752e1d42. See UPSTREAM.json.
import PackageDescription

// Preserve upstream runtime availability, including its unrestricted Linux
// platform declaration. Distributed actors require these Apple runtimes.
let platforms: [SupportedPlatform]?
#if os(Linux)
platforms = nil
#else
platforms = [.iOS(.v18), .macOS(.v15), .tvOS(.v18), .watchOS(.v11)]
#endif

let package = Package(
    name: "swift-distributed-actors",
    platforms: platforms,
    products: [
        .library(name: "DistributedCluster", targets: ["DistributedCluster"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-atomics", from: "1.1.0"),
        .package(url: "https://github.com/apple/swift-cluster-membership", from: "0.4.0"),
        .package(url: "https://github.com/apple/swift-nio", from: "2.61.1"),
        .package(url: "https://github.com/apple/swift-nio-extras", from: "1.20.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl", from: "2.25.0"),
        .package(url: "https://github.com/apple/swift-protobuf", from: "1.25.1"),
        .package(url: "https://github.com/swift-server/swift-backtrace", from: "1.1.1"),
        .package(url: "https://github.com/apple/swift-async-algorithms", from: "1.0.0-beta"),
        .package(url: "https://github.com/apple/swift-collections", from: "1.1.0"),
        .package(url: "https://github.com/apple/swift-log", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-metrics", "1.0.0"..<"3.0.0"),
        .package(url: "https://github.com/apple/swift-service-discovery", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "DistributedCluster",
            dependencies: [
                "DistributedActorsConcurrencyHelpers",
                "CDistributedActorsMailbox",
                .product(name: "OrderedCollections", package: "swift-collections"),
                .product(name: "Atomics", package: "swift-atomics"),
                .product(name: "SWIM", package: "swift-cluster-membership"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "NIOExtras", package: "swift-nio-extras"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Metrics", package: "swift-metrics"),
                .product(name: "ServiceDiscovery", package: "swift-service-discovery"),
                .product(name: "Backtrace", package: "swift-backtrace"),
                .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(name: "CDistributedActorsMailbox", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "DistributedActorsConcurrencyHelpers", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "DistributedClusterBoundedFramingTests",
            dependencies: [
                "DistributedCluster",
                .product(name: "NIOEmbedded", package: "swift-nio"),
                .product(name: "NIOCore", package: "swift-nio"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
