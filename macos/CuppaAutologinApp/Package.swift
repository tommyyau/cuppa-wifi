// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CuppaAutologinApp",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "CuppaAutologin", targets: ["CuppaAutologin"]),
        .executable(name: "CuppaFixtureServer", targets: ["CuppaFixtureServer"]),
        .library(name: "CuppaRuntime", type: .static, targets: ["CuppaEngine", "CuppaNetworking", "CuppaPortals", "CuppaCore"])
    ],
    targets: [
        .target(name: "CuppaCore"),
        .executableTarget(name: "CuppaFixtureServer"),
        .target(name: "CuppaNetworking", dependencies: ["CuppaCore"]),
        .target(name: "CuppaPortals", dependencies: ["CuppaCore"]),
        .target(name: "CuppaEngine", dependencies: ["CuppaCore", "CuppaNetworking", "CuppaPortals"]),
        .testTarget(name: "CuppaNetworkingTests", dependencies: ["CuppaNetworking", "CuppaCore"]),
        .testTarget(name: "CuppaPortalsTests", dependencies: ["CuppaPortals", "CuppaCore"]),
        .testTarget(name: "CuppaEngineTests", dependencies: ["CuppaEngine", "CuppaCore", "CuppaNetworking", "CuppaPortals"]),
        .executableTarget(
            name: "CuppaAutologin",
            dependencies: ["CuppaEngine", "CuppaNetworking", "CuppaCore"],
            path: "Sources/CuppaAutologin"
        ),
    ]
)
