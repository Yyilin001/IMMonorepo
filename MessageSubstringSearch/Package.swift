// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MessageSubstringSearch",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "MessageSubstringSearch", targets: ["MessageSubstringSearch"])],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "MessageSubstringSearch", dependencies: ["CSQLite"]),
        .testTarget(name: "MessageSubstringSearchTests", dependencies: ["MessageSubstringSearch"])
    ]
)
