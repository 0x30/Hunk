// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Hunk",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "HunkCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Hunk",
            dependencies: ["HunkCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "HunkCoreTests",
            dependencies: ["HunkCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
