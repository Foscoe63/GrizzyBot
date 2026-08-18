// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GrizzyBot",
    platforms: [
        .macOS(.v15)
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.7.0"),
        .package(url: "https://github.com/getsentry/sentry-cocoa", from: "9.24.0"),
    ],
    targets: [
        // Core domain logic (models, cron, catalog, LLM agent runtime, store).
        // No SwiftUI here so it stays unit-testable.
        .target(
            name: "GrizzyBotCore",
            path: "Sources/GrizzyBotCore"
        ),
        // The macOS SwiftUI app.
        .executableTarget(
            name: "GrizzyBot",
            dependencies: [
                "GrizzyBotCore",
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "Sentry", package: "sentry-cocoa"),
            ],
            path: "Sources/GrizzyBot",
            exclude: ["Info.plist", "Resources", "GrizzyBot.entitlements", "GrizzyBot.Release.entitlements"],
            resources: [
                .process("Assets.xcassets"),
            ]
        ),
        .testTarget(
            name: "GrizzyBotCoreTests",
            dependencies: ["GrizzyBotCore"],
            path: "Tests/GrizzyBotCoreTests"
        ),
    ]
)
