// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "IMServer",
    platforms: [
       .macOS(.v15)
    ],
    dependencies: [
        // 💧 服务端 Swift Web 框架。
        .package(url: "https://github.com/vapor/vapor.git", from: "4.115.0"),
        .package(url: "https://github.com/vapor/fluent.git", from: "4.11.0"),
        .package(url: "https://github.com/vapor/fluent-postgres-driver.git", from: "2.9.0"),
        .package(url: "https://github.com/vapor/fluent-sqlite-driver.git", from: "4.7.0"),
        .package(url: "https://github.com/vapor/jwt-kit.git", from: "5.0.0"),
        .package(url: "https://github.com/vapor/sql-kit.git", from: "3.35.0"),
        .package(url: "https://github.com/swift-server/RediStack.git", from: "1.6.0"),
        .package(url: "https://github.com/valkey-io/valkey-swift.git", exact: "1.4.0"),
        .package(url: "https://github.com/swift-server/swift-kafka-client.git", exact: "1.0.0-alpha.9"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.3.0"),
        // 🔵 面向 Swift 的非阻塞、事件驱动网络库，用于自定义执行器
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-protobuf.git", .upToNextMajor(from: "1.29.0")),
    ],
    targets: [
        .executableTarget(
            name: "IMServer",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                .product(name: "Fluent", package: "fluent"),
                .product(name: "FluentPostgresDriver", package: "fluent-postgres-driver"),
                .product(name: "FluentSQLiteDriver", package: "fluent-sqlite-driver"),
                .product(name: "JWTKit", package: "jwt-kit"),
                .product(name: "SQLKit", package: "sql-kit"),
                .product(name: "RediStack", package: "RediStack"),
                .product(name: "Valkey", package: "valkey-swift"),
                .product(name: "Kafka", package: "swift-kafka-client"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "IMServerTests",
            dependencies: [
                .target(name: "IMServer"),
                .product(name: "FluentPostgresDriver", package: "fluent-postgres-driver"),
                .product(name: "VaporTesting", package: "vapor"),
            ],
            swiftSettings: swiftSettings
        )
    ]
)

var swiftSettings: [SwiftSetting] { [
    .enableUpcomingFeature("ExistentialAny"),
] }
