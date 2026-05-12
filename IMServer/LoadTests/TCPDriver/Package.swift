// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "IMTCPLoadDriver",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "IMTCPLoadDriver", targets: ["IMTCPLoadDriver"])
    ],
    targets: [
        .executableTarget(name: "IMTCPLoadDriver")
    ]
)

