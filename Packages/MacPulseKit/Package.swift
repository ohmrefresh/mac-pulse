// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacPulseKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PulseCore", targets: ["PulseCore"]),
        .library(name: "PulseCollectors", targets: ["PulseCollectors"]),
        .library(name: "PulseStore", targets: ["PulseStore"]),
        .library(name: "PulseEngine", targets: ["PulseEngine"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.0"),
    ],
    targets: [
        .target(name: "PulseCore"),
        .target(name: "PulseCollectors", dependencies: ["PulseCore"],
                linkerSettings: [.linkedFramework("CoreWLAN")]),
        .target(name: "PulseStore", dependencies: ["PulseCore", .product(name: "GRDB", package: "GRDB.swift")]),
        .target(name: "PulseEngine", dependencies: ["PulseCore", "PulseCollectors", "PulseStore"]),
        .testTarget(name: "PulseCoreTests", dependencies: ["PulseCore"]),
        .testTarget(name: "PulseCollectorsTests", dependencies: ["PulseCollectors"]),
        .testTarget(name: "PulseStoreTests", dependencies: ["PulseStore"]),
        .testTarget(name: "PulseEngineTests", dependencies: ["PulseEngine"]),
    ]
)
