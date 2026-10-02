// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Tanto",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "KatanaKit", resources: [.copy("Resources/parameters.json")]),
        .testTarget(name: "KatanaKitTests", dependencies: ["KatanaKit"]),
        .executableTarget(name: "TantoProbe", dependencies: ["KatanaKit"]),
        .executableTarget(name: "Tanto", dependencies: ["KatanaKit"]),
    ]
)
