// swift-tools-version: 5.9
// QuickAuth iOS SDK — Swift Package Manager manifest
import PackageDescription

let package = Package(
    name: "QuickAuth",
    platforms: [
        .iOS(.v14),
        .macOS(.v11)
    ],
    products: [
        .library(
            name: "QuickAuth",
            targets: ["QuickAuth"]
        )
    ],
    dependencies: [],
    targets: [
        .target(
            name: "QuickAuth",
            dependencies: [],
            path: "Sources/QuickAuth",
            // Copied, not processed: App Store review reads the manifest at the
            // bundle root and .process would be free to relocate it.
            resources: [.copy("PrivacyInfo.xcprivacy")]
        ),
        .testTarget(
            name: "QuickAuthTests",
            dependencies: ["QuickAuth"],
            path: "Tests/QuickAuthTests"
        )
    ]
)
