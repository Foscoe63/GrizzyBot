// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GrizzyBot",
    platforms: [
        .macOS(.v15)
    ],
    dependencies: [
        .package(url: "https://github.com/getsentry/sentry-cocoa", from: "9.24.0"),
        // In-app MLX inference (the Local MLX provider). MLXLLM / MLXLMCommon
        // moved out of mlx-swift-examples into this package; it deliberately
        // does not depend on swift-transformers, so the tokenizer bridge below
        // is supplied by the consumer through the MLXHuggingFace macros.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", from: "3.31.4"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
    ],
    targets: [
        // Core domain logic (models, cron, catalog, LLM agent runtime, store).
        // No SwiftUI here so it stays unit-testable.
        .target(
            name: "GrizzyBotCore",
            path: "Sources/GrizzyBotCore"
        ),
        // The MLX runtime behind the Local MLX provider. Isolated in its own
        // target so GrizzyBotCore — and its tests — stay free of the MLX and
        // tokenizer dependencies; the app installs the generator at launch
        // through `MLXRuntime.register`.
        .target(
            name: "GrizzyBotMLX",
            dependencies: [
                "GrizzyBotCore",
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            path: "Sources/GrizzyBotMLX"
        ),
        // The macOS SwiftUI app.
        .executableTarget(
            name: "GrizzyBot",
            dependencies: [
                "GrizzyBotCore",
                "GrizzyBotMLX",
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
        // Opt-in: downloads a small model from Hugging Face and runs it, so
        // it only executes when GRIZZYBOT_MLX_INTEGRATION=1 is set.
        .testTarget(
            name: "GrizzyBotMLXTests",
            dependencies: ["GrizzyBotMLX", "GrizzyBotCore"],
            path: "Tests/GrizzyBotMLXTests"
        ),
        .executableTarget(
            name: "GrizzyBotRoutineAgent",
            dependencies: ["GrizzyBotCore"],
            path: "Sources/GrizzyBotRoutineAgent",
            exclude: ["com.grizzybot.routine-agent.plist"],
            linkerSettings: [
                .linkedFramework("AppKit"),
            ]
        ),
    ]
)
