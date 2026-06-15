// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Hunk",
    platforms: [.macOS(.v14)],
    dependencies: [
        // 内嵌终端（VS Code 式 ⌘J 面板）
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0"),
    ],
    targets: [
        .target(
            name: "HunkCore",
            resources: [.process("Resources/languages.json")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Hunk",
            dependencies: ["HunkCore", "SwiftTerm"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "HunkCoreTests",
            dependencies: ["HunkCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
