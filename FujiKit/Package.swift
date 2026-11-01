// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FujiKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "FujiKit", targets: ["FujiKit"]),
    ],
    targets: [
        .target(name: "FujiKit"),
        .testTarget(name: "FujiKitTests", dependencies: ["FujiKit"]),
    ]
)
