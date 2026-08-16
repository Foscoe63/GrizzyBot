// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GrizzyBot",
    platforms: [
        .macOS(.v15)
    ],
    targets: [
        // Core domain logic (models, cron, catalog, scripted runtime, store).
        // No SwiftUI here so it stays unit-testable.
        .target(
            name: "GrizzyBotCore",
            path: "Sources/GrizzyBotCore"
        ),
        // The macOS SwiftUI app.
        .executableTarget(
            name: "GrizzyBot",
            dependencies: ["GrizzyBotCore"],
            path: "Sources/GrizzyBot"
        ),
        .testTarget(
            name: "GrizzyBotCoreTests",
            dependencies: ["GrizzyBotCore"],
            path: "Tests/GrizzyBotCoreTests"
        ),
    ]
)
