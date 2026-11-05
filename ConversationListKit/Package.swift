// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ConversationListKit",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "ConversationListKit", targets: ["ConversationListKit"])],
    targets: [
        .target(name: "ConversationListKit"),
        .testTarget(name: "ConversationListKitTests", dependencies: ["ConversationListKit"])
    ]
)
