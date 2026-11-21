// swift-tools-version: 6.4
import Foundation
import PackageDescription

// Flutter resolves path plugins through symlinks inside its generated package.
let directory = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent()
let clientKit = directory.appendingPathComponent("../../../../../IMV2ClientKit").standardizedFileURL
let package = Package(
    name: "im_flutter_sdk",
    platforms: [.iOS(.v17)],
    products: [.library(name: "im-flutter-sdk", targets: ["im_flutter_sdk"])],
    dependencies: [.package(path: clientKit.path)],
    targets: [.target(name: "im_flutter_sdk", dependencies: [
        .product(name: "IMV2SharedApple", package: "IMV2ClientKit")
    ])],
    swiftLanguageModes: [.v5]
)
