// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MotionRecord",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MotionRecord",
            path: "Sources/MotionRecord"
        )
    ],
    swiftLanguageVersions: [.v5]
)
