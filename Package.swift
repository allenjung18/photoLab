// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PhotoLab",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "PhotoLab", path: "Sources/PhotoLab"),
    ]
)
