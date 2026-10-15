// swift-tools-version: 5.9
import PackageDescription

// Complete concurrency checking on both targets: every crossing of an image
// or a model between the main actor and a detached render or decode is
// checked, and the build is kept at zero warnings.
let strict: [SwiftSetting] = [.enableUpcomingFeature("StrictConcurrency")]

let package = Package(

    name: "PhotoLab",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "PhotoLab", path: "Sources/PhotoLab", swiftSettings: strict),
        .testTarget(name: "PhotoLabTests", dependencies: ["PhotoLab"], path: "Tests/PhotoLabTests", swiftSettings: strict),

    ]
)
