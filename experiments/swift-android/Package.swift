// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "IMSwiftAndroidProbe",
    platforms: [.macOS(.v15)],
    products: [.library(name: "IMSwiftProbe", type: .dynamic, targets: ["IMSwiftProbe", "ProbeJNI"])],
    dependencies: [
        .package(path: "../../IMV2Core"),
        .package(path: "../../IMV2ClientKit"),
        .package(path: "../../MessageSubstringSearch"),
        .package(path: "../../IMV2Compression"),
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
        .package(url: "https://github.com/apple/swift-protobuf.git", exact: "1.38.1"),
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "3.15.1"),
    ],
    targets: [
        .target(name: "ProbeJNI"),
        // Prepared from the repository's generated file; never hand-edit a second protocol copy.
        .target(name: "ProbeProtocol", dependencies: [.product(name: "SwiftProtobuf", package: "swift-protobuf")], path: "build/Protocol"),
        .target(name: "IMSwiftProbe", dependencies: [
            "IMV2Core", "IMV2Compression", "ProbeProtocol", "MessageSubstringSearch",
            .product(name: "IMV2ClientRuntime", package: "IMV2ClientKit"),
            .product(name: "IMV2ClientAndroid", package: "IMV2ClientKit"),
            .product(name: "GRDB", package: "GRDB.swift"),
            .product(name: "Crypto", package: "swift-crypto"),
        ]),
    ],
    swiftLanguageModes: [.v6]
)
