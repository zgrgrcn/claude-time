// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "claude-time",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "claude-time", targets: ["ClaudeTimeCLI"]),
        .executable(name: "ClaudeTime", targets: ["ClaudeTimeApp"]),
        .library(name: "ClaudeTimeCore", targets: ["ClaudeTimeCore"]),
    ],
    targets: [
        .target(name: "ClaudeTimeCore"),
        .executableTarget(name: "ClaudeTimeCLI", dependencies: ["ClaudeTimeCore"]),
        .executableTarget(name: "ClaudeTimeApp", dependencies: ["ClaudeTimeCore"]),
        .testTarget(name: "ClaudeTimeCoreTests", dependencies: ["ClaudeTimeCore"]),
    ]
)
