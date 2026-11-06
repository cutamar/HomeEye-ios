// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "HomeEyeCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "HomeEyeCore", targets: ["HomeEyeCore"])
    ],
    targets: [
        .target(name: "HomeEyeCore"),
        .testTarget(name: "HomeEyeCoreTests", dependencies: ["HomeEyeCore"])
    ]
)
