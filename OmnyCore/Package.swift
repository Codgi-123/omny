// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OmnyCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "OmnyCore", targets: ["OmnyCore"]),
    ],
    targets: [
        .target(name: "OmnyCore"),
        .testTarget(name: "OmnyCoreTests", dependencies: ["OmnyCore"]),
    ]
)
