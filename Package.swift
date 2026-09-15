// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WLOCCoreDeviceLab",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "LoopbackCore", targets: ["LoopbackCore"])
    ],
    targets: [
        .target(name: "LoopbackCore"),
        .testTarget(name: "LoopbackCoreTests", dependencies: ["LoopbackCore"])
    ]
)
