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
/// `Scripts/make-app.sh` and Xcode both handle a packaged app by placing
/// `mlx-swift_Cmlx.bundle` in `Contents/Resources`. This is the fallback for
/// loose binaries SwiftPM produces.
///
/// It never writes inside a bundle. Only an executable can live in a bundle's
/// `Contents/MacOS`, so a stray `.metallib` there makes the next `codesign`
/// of that bundle fail outright — observed breaking `swift test` after an
/// integration run had staged one into the `.xctest`. A test that needs the
/// shaders stages them explicitly with ``stageBesideExecutable()`` and removes
/// them again.
public enum MLXMetallibBootstrap {
    private static let logger = Logger(subsystem: "com.grizzybot.app", category: "MLXMetallib")

    /// Any bundle wrapper. A file added inside one of these after it was
    /// signed breaks the next signing of that bundle.
    private static let bundleExtensions = [".app", ".xctest", ".framework", ".bundle", ".appex"]

    /// Copy the metallib beside the running executable if it is not already
    /// reachable and the binary does not live inside a bundle. Cheap,
    /// idempotent, and a no-op for anything packaged.
    static func ensureColocated() {
        guard let directory = binaryDirectory(), !isInsideBundle(directory) else { return }
        _ = stage(into: directory)
    }

    /// Put the metallib beside the running executable even inside a bundle,
    /// and return what was created so the caller can remove it again.
    ///
    /// Only for an opt-in test that needs to actually run a model under
    /// `swift test`: the binary there lives in `<name>.xctest/Contents/MacOS`,
    /// which is the one place MLX looks and the one place codesign refuses to
    /// find a non-executable. **Always** delete the returned URL afterwards,
    /// or the next build of that test bundle fails to sign.
    public static func stageBesideExecutable() -> URL? {
        guard let directory = binaryDirectory() else { return nil }
        return stage(into: directory)
    }

    /// Returns the file it created, or nil when one was already reachable or
    /// no source could be found.
    private static func stage(into directory: URL) -> URL? {
        let fm = FileManager.default
        for name in ["mlx.metallib", "default.metallib"]
        where fm.fileExists(atPath: directory.appendingPathComponent(name).path) {
            return nil
        }

        guard let source = locateSource(near: directory) else {
            logger.notice("No default.metallib found; Local MLX model loads will fail in this binary.")
            return nil
        }

        let destination = directory.appendingPathComponent("mlx.metallib")
        do {
            try fm.copyItem(at: source, to: destination)
            logger.info("Colocated MLX metallib at \(destination.path, privacy: .public)")
            return destination
        } catch {
            logger.error(
                "Could not colocate the MLX metallib: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    private static func isInsideBundle(_ directory: URL) -> Bool {
        directory.pathComponents.contains { component in
            bundleExtensions.contains { component.hasSuffix($0) }
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
