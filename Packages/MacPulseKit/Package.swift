// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacPulseKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PulseCore", targets: ["PulseCore"]),
        .library(name: "PulseCollectors", targets: ["PulseCollectors"]),
        .library(name: "PulseEngine", targets: ["PulseEngine"]),
    ],
    targets: [
        .target(name: "PulseCore"),
        .target(name: "PulseCollectors", dependencies: ["PulseCore"]),
        .target(name: "PulseEngine", dependencies: ["PulseCore", "PulseCollectors"]),
        .testTarget(name: "PulseCoreTests", dependencies: ["PulseCore"]),
        .testTarget(name: "PulseCollectorsTests", dependencies: ["PulseCollectors"]),
        .testTarget(name: "PulseEngineTests", dependencies: ["PulseEngine"]),
    ]
)
