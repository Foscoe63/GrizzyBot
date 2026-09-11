import Foundation
import os

#if canImport(Darwin)
import Darwin
#endif

/// Makes MLX's Metal shader library findable outside a packaged `.app`.
///
/// MLX looks for `mlx.metallib` beside the running binary, then walks loaded
/// bundles for the SwiftPM `mlx-swift_Cmlx.bundle`. A `swift test` or
/// `swift run` binary satisfies neither — the main bundle is the test runner,
/// and the resource bundle sits beside the executable without being loaded —
/// so every model load fails with "Failed to load the default metallib".
///
/// `Scripts/make-app.sh` handles the shipping app by copying both the bundle
/// and `Contents/MacOS/mlx.metallib` at build time. This is the fallback for
/// binaries SwiftPM produces directly. It never writes inside an `.app`:
/// mutating a signed bundle at runtime would invalidate its signature.
enum MLXMetallibBootstrap {
    private static let logger = Logger(subsystem: "com.grizzybot.app", category: "MLXMetallib")

    /// Copy the metallib beside the running executable if it is not already
    /// reachable. Cheap and idempotent.
    static func ensureColocated() {
        let fm = FileManager.default
        guard let executableDirectory = binaryDirectory() else { return }

        // Already there — the app bundle case, and the second call onward.
        for name in ["mlx.metallib", "default.metallib"]
        where fm.fileExists(atPath: executableDirectory.appendingPathComponent(name).path) {
            return
        }

        // Never mutate a signed app bundle.
        guard !executableDirectory.pathComponents.contains(where: { $0.hasSuffix(".app") }) else {
            return
        }

        guard let source = locateSource(near: executableDirectory) else {
            logger.notice("No default.metallib found; Local MLX model loads will fail in this binary.")
            return
        }

        let destination = executableDirectory.appendingPathComponent("mlx.metallib")
        do {
            try fm.copyItem(at: source, to: destination)
            logger.info("Colocated MLX metallib at \(destination.path, privacy: .public)")
        } catch {
            logger.error(
                "Could not colocate the MLX metallib: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// The directory MLX itself searches: the one holding the binary that
    /// contains MLX's code. Resolved with `dladdr` rather than `Bundle.main`,
    /// which under `swift test` names Xcode's `xctest` tool instead of the
    /// test bundle actually running.
    private static func binaryDirectory() -> URL? {
        #if canImport(Darwin)
        var info = Dl_info()
        // `#dsohandle` is this module's Mach-O header, so dladdr names the
        // binary GrizzyBotMLX (and the statically linked MLX) was linked into.
        guard dladdr(#dsohandle, &info) != 0, let name = info.dli_fname else {
            return Bundle.main.executableURL?.deletingLastPathComponent()
        }
        return URL(fileURLWithPath: String(cString: name))
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
        #else
        return Bundle.main.executableURL?.deletingLastPathComponent()
        #endif
    }

    /// The SwiftPM resource bundle sits beside the build products, which for a
    /// test bundle is two levels above `Contents/MacOS` — so walk up a few
    /// directories rather than looking only next to the binary.
    private static func locateSource(near directory: URL) -> URL? {
        let fm = FileManager.default
        if let override = ProcessInfo.processInfo.environment["GRIZZYBOT_MLX_METALLIB"],
           !override.isEmpty,
           fm.fileExists(atPath: override) {
            return URL(fileURLWithPath: override)
        }

        let relativePaths = [
            "mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib",
            "mlx-swift_Cmlx.bundle/default.metallib",
        ]
        var searchRoots: [URL] = []
        var current = directory
        for _ in 0..<4 {
            searchRoots.append(current)
            current = current.deletingLastPathComponent()
        }
        if let resources = Bundle.main.resourceURL {
            searchRoots.append(resources)
        }

        for root in searchRoots {
            for relative in relativePaths {
                let candidate = root.appendingPathComponent(relative)
                if fm.fileExists(atPath: candidate.path) { return candidate }
            }
        }
        return nil
    }
}
