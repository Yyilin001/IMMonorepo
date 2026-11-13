// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MessageSubstringSearch",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "MessageSubstringSearch", targets: ["MessageSubstringSearch"])],
    dependencies: [.package(url: "https://github.com/apple/swift-crypto.git", from: "3.9.0")],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "CSearchFileLock"),
        .target(name: "MessageSubstringSearch", dependencies: ["CSQLite", "CSearchFileLock", .product(name: "Crypto", package: "swift-crypto")]),
        .testTarget(name: "MessageSubstringSearchTests", dependencies: ["MessageSubstringSearch"])
    ]
)
