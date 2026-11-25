import CryptoKit
import Foundation

/// One Mac folder shown inside a Private desktop, read-only. The container sees exactly this folder and nothing above it.
public struct PodmanDesktopMount: Sendable, Equatable, Hashable {
    /// The real path on the Mac, symlinks resolved.
    public var source: String
    /// The folder's name inside the desktop: `/mnt/mac/<name>`.
    public var name: String
    /// True when the desktop may change the real folder. Off unless the person chose it for this folder.
    public var writable: Bool = false

    public static let guestRoot = "/mnt/mac"

    public var guestPath: String { "\(Self.guestRoot)/\(name)" }

    /// The argument for `--mount`. Read-only unless the person made this folder writable.
    var argument: String { "type=bind,source=\(source),target=\(guestPath),ro=\(writable ? "false" : "true")" }
}

public struct PodmanDesktopMountSkip: Sendable, Equatable {
    public var folderName: String
    public var reason: String
}

public enum PodmanDesktopMounts {
    /// The mounts a set of folders can become, and the folders that were left out with the reason why. Pure apart from
    /// reading the disk, so the rules are testable.
    ///
    /// A folder is left out when it does not exist, is not a folder, holds secrets (`.ssh`, `.env`, …), is the home folder or
    /// a parent of it, is in `~/Library`, holds GrizzyBot's own data, or sits where Podman's VM cannot
    /// see it (it shares `/Users`, `/Volumes`, `/private` and `/var/folders`; only the first two are accepted here).
    public static func resolve(
        _ folders: [GrantedFolder],
        modes: [String: DesktopFolderMode] = [:],
        home: String = NSHomeDirectory(),
        protectedPaths: [String] = [],
        visibleRoots: [String] = ["/Users", "/Volumes"]
    ) -> (mounts: [PodmanDesktopMount], skipped: [PodmanDesktopMountSkip]) {
        var mounts: [PodmanDesktopMount] = []
        var skipped: [PodmanDesktopMountSkip] = []
        var used: Set<String> = []
        var seenSources: Set<String> = []
        let homePath = canonical(home)
        let protected = protectedPaths.map(canonical)

        for folder in folders {
            if let reason = refusal(for: folder.path, home: homePath, protectedPaths: protected, visibleRoots: visibleRoots.map(canonical)) {
                skipped.append(PodmanDesktopMountSkip(folderName: folder.name, reason: reason))
                continue
            }
            let source = canonical(BotHomeStore.expandPath(folder.path))
            let mode = modes[folder.id] ?? .readOnly
            // A copy lives in the bot's workspace, which is already mounted: it needs no mount of its own.
            if mode == .copy { continue }
            guard seenSources.insert(source).inserted else { continue }
            var base = sanitize(folder.name)
            if base.isEmpty { base = sanitize((source as NSString).lastPathComponent) }
            if base.isEmpty { base = "folder" }
            var name = base
            var suffix = 2
            while !used.insert(name.lowercased()).inserted {
                name = "\(base)-\(suffix)"
                suffix += 1
            }
            mounts.append(PodmanDesktopMount(source: source, name: name, writable: mode == .writable))
        }
        return (mounts, skipped)
    }

    /// Why this path cannot be shown to a desktop, or nil when it can.
    static func refusal(for rawPath: String, home: String, protectedPaths: [String], visibleRoots: [String]) -> String? {
        let expanded = BotHomeStore.expandPath(rawPath)
        guard !expanded.isEmpty, expanded.hasPrefix("/") else { return "The path is not absolute." }
        let path = canonical(expanded)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return "The folder is missing." }
        guard isDirectory.boolValue else { return "It is a file, not a folder." }
        // `,` ends a mount option, so a path holding one could smuggle in options of its own.
        if path.contains(",") || path.contains("\n") || path.contains("\0") { return "The path has a character a desktop cannot mount." }
        if BotHomeStore.isDeniedHostPath(path) { return "It holds secrets (such as .ssh or .env)." }

        // The home folder itself, or anything above it, would hand over everything beneath.
        if path == home || home.hasPrefix(path == "/" ? "/" : path + "/") { return "That is your whole home folder or a parent of it." }
        if protectedPaths.contains(where: { inside(path, $0) || inside($0, path) }) {
            return "It holds GrizzyBot's own data."
        }
        if inside(path, home + "/Library") { return "Library folders cannot be shared." }
        // The mount points of the machine themselves, not folders in them.
        if visibleRoots.contains(path) { return "Choose a folder inside it." }
        guard visibleRoots.contains(where: { inside(path, $0) }) else {
            return "Podman can only see folders under \(visibleRoots.joined(separator: " and "))."
        }
        return nil
    }

    /// Resolves `..` and symlinks, so a link inside an allowed folder cannot be used to name a place outside it.
    static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// True when `path` is `parent` or inside it.
    static func inside(_ path: String, _ parent: String) -> Bool {
        path == parent || path.hasPrefix(parent.hasSuffix("/") ? parent : parent + "/")
    }

    static func sanitize(_ raw: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        var text = String(raw.map { allowed.contains($0) ? $0 : "-" })
        while text.contains("--") { text = text.replacingOccurrences(of: "--", with: "-") }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return String(text.prefix(40))
    }

    /// A label value that changes whenever the set of shown folders does. "none" for no folders, which is also what a
    /// desktop made before this feature is taken to have.
    public static func digest(_ mounts: [PodmanDesktopMount]) -> String {
        guard !mounts.isEmpty else { return "none" }
        let lines = mounts.map { "\($0.source)\t\($0.name)\t\($0.writable ? "rw" : "ro")" }.sorted().joined(separator: "\n")
        return SHA256.hash(data: Data(lines.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// A copy of a granted folder, kept in the bot's own workspace so the original is never touched.
public enum DesktopFolderCopy {
    public static let maxFiles = 20_000
    public static let maxBytes: Int64 = 1_000_000_000

    /// Where the copy lives on the Mac, and where the desktop sees it.
    public static func hostPath(workspace: URL, name: String) -> URL {
        workspace.appendingPathComponent("copies", isDirectory: true).appendingPathComponent(name, isDirectory: true)
    }

    public static func guestPath(name: String) -> String { "\(PodmanDesktop.guestWorkspace)/copies/\(name)" }

    /// Why a folder is too big to copy, or nil. Counts as it goes and stops early.
    public static func sizeRefusal(of folder: URL) -> String? {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else {
            return "The folder could not be read."
        }
        var files = 0
        var bytes: Int64 = 0
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            files += 1
            bytes += Int64(values?.fileSize ?? 0)
            if files > maxFiles { return "It has more than \(maxFiles) files, too many to copy." }
            if bytes > maxBytes { return "It is larger than \(maxBytes / 1_000_000_000) GB, too big to copy." }
        }
        return nil
    }

    /// Copies the folder, replacing an earlier copy. Symbolic links are copied as links, never followed.
    public static func make(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: destination)
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: source, to: destination)
    }
}
