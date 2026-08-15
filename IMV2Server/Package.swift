// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "IMV2Server",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "IMV2Server", targets: ["IMV2Server"]),
        .library(name: "IMV2ServerHTTP", targets: ["IMV2ServerHTTP"]),
        .executable(name: "IMV2ServerApp", targets: ["IMV2ServerApp"]),
        .executable(name: "IMV2AccountServerApp", targets: ["IMV2AccountServerApp"]),
        .executable(name: "IMV2OperatorServerApp", targets: ["IMV2OperatorServerApp"]),
        .executable(name: "IMV2LocalGatewayProbe", targets: ["IMV2LocalGatewayProbe"]),
    ],
    dependencies: [
        .package(path: "../IMV2Core"),
        .package(url: "https://github.com/vapor/vapor.git", from: "4.115.0"),
        .package(url: "https://github.com/vapor/fluent.git", from: "4.11.0"),
        .package(url: "https://github.com/vapor/fluent-postgres-driver.git", from: "2.9.0"),
        .package(url: "https://github.com/vapor/sql-kit.git", from: "3.35.0"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.29.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.34.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.9.0"),
    ],
    targets: [
        .target(
            name: "IMV2Server",
            dependencies: [
                "IMV2Core",
                .product(name: "Fluent", package: "fluent"),
                .product(name: "SQLKit", package: "sql-kit"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .target(
            name: "IMV2ServerHTTP",
            dependencies: [
                "IMV2Server",
                .product(name: "Vapor", package: "vapor"),
                .product(name: "Fluent", package: "fluent"),
                .product(name: "SQLKit", package: "sql-kit"),
            ]
        ),
        .executableTarget(
            name: "IMV2ServerApp",
            dependencies: [
                "IMV2Server",
                "IMV2ServerHTTP",
                .product(name: "Vapor", package: "vapor"),
                .product(name: "FluentPostgresDriver", package: "fluent-postgres-driver"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]
        ),
        .executableTarget(
            name: "IMV2AccountServerApp",
            dependencies: [
                "IMV2Server",
                "IMV2ServerHTTP",
                .product(name: "Vapor", package: "vapor"),
                .product(name: "FluentPostgresDriver", package: "fluent-postgres-driver"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]
        ),
        .executableTarget(
            name: "IMV2OperatorServerApp",
            dependencies: [
                "IMV2Server",
                "IMV2ServerHTTP",
                .product(name: "Vapor", package: "vapor"),
                .product(name: "FluentPostgresDriver", package: "fluent-postgres-driver"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]
        ),
        // This executable belongs only to the local Compose verification
        // image. It gives the shell smoke test a real TLS/protobuf client
        // without adding a debug route or weakening the gateway itself.
        .executableTarget(
            name: "IMV2LocalGatewayProbe",
            dependencies: [
                "IMV2Core",
                "IMV2Server",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
            ]
        ),
        .testTarget(
            name: "IMV2ServerTests",
            dependencies: [
                "IMV2Server",
                "IMV2ServerHTTP",
                .product(name: "FluentPostgresDriver", package: "fluent-postgres-driver"),
                .product(name: "Vapor", package: "vapor"),
                .product(name: "VaporTesting", package: "vapor"),
                .product(name: "SQLKit", package: "sql-kit"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]
        ),
    ]
)
