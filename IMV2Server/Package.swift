// swift-tools-version:6.4
import PackageDescription

let package = Package(
    name: "IMV2Server",
    platforms: [.macOS("26.2")],
    products: [
        .library(name: "IMV2ActorContracts", targets: ["IMV2ActorContracts"]),
        .library(name: "IMV2ActorRuntime", targets: ["IMV2ActorRuntime"]),
        .library(name: "IMV2ActorCluster", targets: ["IMV2ActorCluster"]),
        .library(name: "IMV2ActorApplication", targets: ["IMV2ActorApplication"]),
        .library(name: "IMV2ServerContracts", targets: ["IMV2ServerContracts"]),
        .library(name: "IMV2ServerApplication", targets: ["IMV2ServerApplication"]),
        .library(name: "IMV2Server", targets: ["IMV2Server"]),
        .library(name: "IMV2ServerInfrastructure", targets: ["IMV2ServerInfrastructure"]),
        .library(name: "IMV2ServerGateway", targets: ["IMV2ServerGateway"]),
        .library(name: "IMV2ServerHTTP", targets: ["IMV2ServerHTTP"]),
        .executable(name: "IMV2ResourceImageWorker", targets: ["IMV2ResourceImageWorker"]),
        .executable(name: "IMV2PlacementControlApp", targets: ["IMV2PlacementControlApp"]),
        .executable(name: "IMV2TrustAdmissionTool", targets: ["IMV2TrustAdmissionTool"]),
        .executable(name: "IMV2RoomHostSupervisorApp", targets: ["IMV2RoomHostSupervisorApp"]),
        .executable(name: "IMV2ServerApp", targets: ["IMV2ServerApp"]),
        .executable(name: "IMV2AccountServerApp", targets: ["IMV2AccountServerApp"]),
        .executable(name: "IMV2OperatorServerApp", targets: ["IMV2OperatorServerApp"]),
        .executable(name: "IMV2LocalGatewayProbe", targets: ["IMV2LocalGatewayProbe"]),
        .executable(name: "IMV2GatewayLoadGenerator", targets: ["IMV2GatewayLoadGenerator"]),
        .executable(name: "VirtualActorCompatibilityProbe", targets: ["VirtualActorCompatibilityProbe"]),
        .executable(name: "VirtualActorBusinessProbe", targets: ["VirtualActorBusinessProbe"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.35.0"),
        .package(url: "https://github.com/vapor/routing-kit.git", from: "5.0.0-beta"),
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.7.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.14.0"),
        // Xcode 27 未向下传递 AsyncStreaming 请求的条件 trait；
        // 显式开启 ContainersPreview 协议定义，保证 Xcode 与 SwiftPM 使用同一依赖图。
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.6.0",
                 traits: [.trait(name: "UnstableContainersPreview")]),
        .package(url: "https://github.com/apple/swift-configuration.git", from: "1.2.0"),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.11.0"),
        .package(path: "../IMV2Core"),
        .package(path: "../IMV2Compression"),
        .package(url: "https://github.com/vapor/vapor.git", exact: "5.0.0-beta.3"),
        .package(url: "https://github.com/vapor/fluent-kit.git", exact: "1.57.0"),
        .package(url: "https://github.com/vapor/fluent-postgres-driver.git", from: "2.9.0"),
        .package(path: "Vendor/postgres-nio"),
        .package(url: "https://github.com/vapor/postgres-kit.git", exact: "2.16.1"),
        .package(url: "https://github.com/vapor/async-kit.git", from: "1.22.0"),
        .package(url: "https://github.com/vapor/sql-kit.git", from: "3.35.0"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.29.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.34.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.0.0"),
        .package(path: "Vendor/swift-distributed-actors"),
    ],
    targets: [
        .executableTarget(name: "IMV2ResourceImageWorker"),
        .executableTarget(name: "IMV2TrustAdmissionTool", dependencies: ["IMV2ActorApplication"]),
        .executableTarget(name: "IMV2PlacementControlApp",
            dependencies: ["IMV2ActorApplication", "IMV2Server", "IMV2ServerContracts", "IMV2ServerApplication",
                           .product(name: "Logging", package: "swift-log")]),
        .executableTarget(name: "IMV2RoomHostSupervisorApp",
            dependencies: ["IMV2ActorApplication", "IMV2ActorCluster", "IMV2ActorContracts", "IMV2Server", "IMV2ServerContracts", "IMV2ServerApplication",
                .product(name: "FluentPostgresDriver", package: "fluent-postgres-driver"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOPosix", package: "swift-nio")]),
        .target(
            name: "IMV2ActorContracts",
            dependencies: ["IMV2Core", .product(name: "SwiftProtobuf", package: "swift-protobuf")]
        ),
        .testTarget(
            name: "IMV2ActorContractsTests",
            dependencies: ["IMV2ActorContracts", "IMV2Core"]
        ),
        .target(
            name: "IMV2ActorRuntime",
            dependencies: ["IMV2ActorContracts", "IMV2Core",
                           .product(name: "Crypto", package: "swift-crypto")]
        ),
        .testTarget(
            name: "IMV2ActorRuntimeTests",
            dependencies: ["IMV2ActorRuntime", "IMV2ActorContracts", "IMV2Core"]
        ),
        .target(
            name: "IMV2ActorCluster",
            dependencies: [
                "IMV2ActorRuntime", "IMV2ActorContracts", "IMV2Core",
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "DistributedCluster", package: "swift-distributed-actors"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "NIOCore", package: "swift-nio"),
            ]
        ),
        .testTarget(
            name: "IMV2ActorClusterTests",
            dependencies: ["IMV2ActorCluster", "IMV2ActorContracts", "IMV2Core", "IMV2ServerGateway",
                           .product(name: "Crypto", package: "swift-crypto"),
                           .product(name: "NIOEmbedded", package: "swift-nio")]
        ),
        .target(
            name: "CIMV2Argon2",
            exclude: ["LICENSE", "UPSTREAM.json"],
            sources: ["src/argon2.c", "src/core.c", "src/encoding.c", "src/ref.c", "src/thread.c", "src/blake2/blake2b.c"],
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath("src"), .define("ARGON2_NO_THREADS")]
        ),
        .target(
            name: "IMV2ServerContracts",
            dependencies: ["IMV2Core", "IMV2ActorContracts",
                .product(name: "Crypto", package: "swift-crypto")]
        ),
        .target(
            name: "IMV2ServerApplication",
            dependencies: ["IMV2ServerContracts", "IMV2Core", "IMV2ActorContracts",
                .product(name: "HashTreeCollections", package: "swift-collections"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Logging", package: "swift-log")]
        ),
        .target(
            name: "IMV2ServerInfrastructure",
            dependencies: [
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                "IMV2ServerContracts", "IMV2ServerApplication",
                "IMV2ActorContracts", "IMV2ActorRuntime", "IMV2ActorCluster", "IMV2Core", "CIMV2Argon2",
                .product(name: "FluentKit", package: "fluent-kit"),
                .product(name: "SQLKit", package: "sql-kit"),
                .product(name: "PostgresNIO", package: "postgres-nio"),
                .product(name: "PostgresKit", package: "postgres-kit"),
                .product(name: "AsyncKit", package: "async-kit"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .target(
            name: "IMV2ServerGateway",
            dependencies: [
                "IMV2ServerApplication", "IMV2ServerContracts",
                "IMV2ActorContracts", "IMV2Core", "IMV2Compression",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
            ]
        ),
        .target(
            name: "IMV2Server",
            dependencies: [
                "IMV2ServerApplication",
                "IMV2ServerContracts",
                "IMV2ServerInfrastructure",
                "IMV2ServerGateway",
                "IMV2ActorContracts",
                "IMV2ActorRuntime",
                "IMV2Core",
                "IMV2Compression",
                .product(name: "FluentKit", package: "fluent-kit"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "SQLKit", package: "sql-kit"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]
        ),
        .executableTarget(
            name: "VirtualActorBusinessProbe",
            dependencies: ["IMV2ServerInfrastructure", "IMV2ActorApplication", "IMV2ActorRuntime", "IMV2ServerApplication", "IMV2Server", "IMV2ServerContracts", "IMV2ActorCluster", "IMV2ActorContracts", "IMV2Core",
                .product(name: "FluentPostgresDriver", package: "fluent-postgres-driver"),
                .product(name: "FluentKit", package: "fluent-kit"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "SQLKit", package: "sql-kit")]
        ),
        .target(
            name: "IMV2ActorApplication",
            dependencies: ["IMV2ServerInfrastructure", "IMV2ServerContracts", "IMV2ServerApplication", "IMV2Server", "IMV2ActorCluster", "IMV2ActorRuntime", "IMV2ActorContracts",
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "FluentKit", package: "fluent-kit"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "Crypto", package: "swift-crypto")]
        ),
        .testTarget(
            name: "IMV2ActorApplicationTests",
            dependencies: ["IMV2ServerInfrastructure", "IMV2ActorApplication", "IMV2ServerApplication", "IMV2Server", "IMV2ServerContracts", "IMV2ActorCluster", "IMV2ActorContracts",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "FluentPostgresDriver", package: "fluent-postgres-driver"),
                .product(name: "SQLKit", package: "sql-kit"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOPosix", package: "swift-nio")]
        ),
        .target(
            name: "IMV2ServerHTTP",
            dependencies: [
                "IMV2Core",
                "IMV2ServerContracts",
                "IMV2ServerApplication",
                .product(name: "Vapor", package: "vapor"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "RoutingKit", package: "routing-kit"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Configuration", package: "swift-configuration"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "_NIOFileSystem", package: "swift-nio"),
            ]
        ),
        .executableTarget(
            name: "IMV2ServerApp",
            dependencies: ["IMV2ServerInfrastructure",
                "IMV2ActorApplication",
                "IMV2ServerContracts",
                "IMV2ServerApplication", "IMV2Server",
                "IMV2ServerGateway",
                "IMV2ServerHTTP",
                .product(name: "Vapor", package: "vapor"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "RoutingKit", package: "routing-kit"),
                .product(name: "FluentKit", package: "fluent-kit"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Configuration", package: "swift-configuration"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "FluentPostgresDriver", package: "fluent-postgres-driver"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]
        ),
        .testTarget(
            name: "IMV2ServerAppTests",
            dependencies: ["IMV2ServerApp", "IMV2ServerGateway"]
        ),
        .executableTarget(
            name: "IMV2AccountServerApp",
            dependencies: ["IMV2ServerInfrastructure",
                "IMV2ActorApplication",
                "IMV2ActorContracts",
                "IMV2ServerContracts",
                "IMV2ServerApplication", "IMV2Server",
                "IMV2ServerHTTP",
                .product(name: "Vapor", package: "vapor"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "RoutingKit", package: "routing-kit"),
                .product(name: "FluentKit", package: "fluent-kit"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Configuration", package: "swift-configuration"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "FluentPostgresDriver", package: "fluent-postgres-driver"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]
        ),
        .executableTarget(
            name: "IMV2OperatorServerApp",
            dependencies: ["IMV2ServerInfrastructure",
                "IMV2ActorApplication",
                "IMV2ServerContracts",
                "IMV2ServerApplication", "IMV2Server",
                "IMV2ServerHTTP",
                .product(name: "Vapor", package: "vapor"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "RoutingKit", package: "routing-kit"),
                .product(name: "FluentKit", package: "fluent-kit"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Configuration", package: "swift-configuration"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "FluentPostgresDriver", package: "fluent-postgres-driver"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]
        ),
        // This executable belongs only to the local Compose verification
        // image. It gives the shell smoke test a real TLS/protobuf client
        // without adding a debug route or weakening the gateway itself.
        .target(name: "IMV2ToolHTTP", dependencies: [
            "IMV2Core",
            .product(name: "AsyncHTTPClient", package: "async-http-client"),
            .product(name: "NIOSSL", package: "swift-nio-ssl"),
        ]),
        .executableTarget(
            name: "IMV2LocalGatewayProbe",
            dependencies: ["IMV2ServerInfrastructure",
                "IMV2ToolHTTP",
                "IMV2Core",
                "IMV2ServerContracts",
                "IMV2ServerApplication", "IMV2Server",
                "IMV2ServerGateway",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
            ]
        ),
        // macOS-only operator tool for bounded, real-protocol load tests. It
        // is intentionally absent from the server image build products.
        .executableTarget(
            name: "IMV2GatewayLoadGenerator",
            dependencies: ["IMV2ServerInfrastructure", "IMV2LoadGeneratorSupport",
                "IMV2ToolHTTP",
                "IMV2Core",
                "IMV2Compression",
                "IMV2ServerContracts",
                "IMV2ServerApplication", "IMV2Server",
                "IMV2ServerGateway",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
            ]
        ),
        .target(name: "IMV2LoadGeneratorSupport"),
        .testTarget(name: "IMV2LoadGeneratorSupportTests", dependencies: ["IMV2LoadGeneratorSupport"]),
        .executableTarget(
            name: "VirtualActorCompatibilityProbe",
            dependencies: ["IMV2ServerInfrastructure",
                "IMV2Core",
                "IMV2ServerContracts",
                "IMV2ServerApplication", "IMV2Server",
                "IMV2ServerHTTP",
                .product(name: "DistributedCluster", package: "swift-distributed-actors"),
                .product(name: "Vapor", package: "vapor"),
                .product(name: "FluentKit", package: "fluent-kit"),
                .product(name: "FluentPostgresDriver", package: "fluent-postgres-driver"),
                .product(name: "SQLKit", package: "sql-kit"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .testTarget(
            name: "IMV2ServerTests",
            dependencies: ["IMV2ServerInfrastructure",
                "IMV2ActorCluster", "IMV2ActorApplication",
                "IMV2ActorContracts",
                "IMV2ServerContracts",
                "IMV2ServerApplication", "IMV2Server",
                "IMV2ServerGateway",
                "CIMV2Argon2",
                "IMV2ServerHTTP",
                .product(name: "FluentPostgresDriver", package: "fluent-postgres-driver"),
                .product(name: "Vapor", package: "vapor"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "RoutingKit", package: "routing-kit"),
                .product(name: "FluentKit", package: "fluent-kit"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Configuration", package: "swift-configuration"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "VaporTesting", package: "vapor"),
                .product(name: "NIOTLS", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "AsyncKit", package: "async-kit"),
                .product(name: "SQLKit", package: "sql-kit"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ],
            swiftSettings: [
                // Swift 6.4 emits very large DWARF for the parameterized database
                // tests on Linux. Keep line-number backtraces and compile each
                // source separately; production debug information is unchanged.
                .unsafeFlags(
                    ["-driver-batch-size-limit", "1", "-Xfrontend", "-gline-tables-only"],
                    .when(platforms: [.linux], configuration: .debug)
                ),
            ]
        ),
    ]
)
