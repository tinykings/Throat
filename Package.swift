// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Throat",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Throat"),
        .testTarget(name: "ThroatTests", dependencies: ["Throat"])
    ]
)
