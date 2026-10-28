// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RichContent",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "RichContent", targets: ["RichContent"])
    ],
    targets: [
        .target(name: "RichContent"),
        .testTarget(name: "RichContentTests", dependencies: ["RichContent"])
    ]
)
