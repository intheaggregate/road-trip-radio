// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RadioEngine",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [.library(name: "RadioEngine", targets: ["RadioEngine"])],
    targets: [
        .target(name: "RadioEngine", path: "Core"),
        .testTarget(name: "RadioEngineTests", dependencies: ["RadioEngine"], path: "Tests")
    ]
)
