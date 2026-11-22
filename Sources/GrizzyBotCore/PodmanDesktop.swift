import CryptoKit
import Foundation

// A bot's private Linux desktop: one hardened Podman container per bot. This file owns only the container boundary
// (find podman, build the run arguments, create / start / stop / remove, report status). Driving the desktop's screen
// is a separate `ComputerRuntime`.

// MARK: - Command runner

public struct PodmanCommandResult: Sendable, Equatable {
    /// The raw bytes, so a screenshot survives; `stdout` is the same output as text.
    public var stdoutData: Data
    public var stderr: String
    public var exitCode: Int32

    public init(stdout: String = "", stdoutData: Data? = nil, stderr: String = "", exitCode: Int32 = 0) {
        self.stdoutData = stdoutData ?? Data(stdout.utf8)
        self.stderr = stderr
        self.exitCode = exitCode
    }

    public var stdout: String { String(decoding: stdoutData, as: UTF8.self) }
    public var succeeded: Bool { exitCode == 0 }
}

/// Runs `executable args…`. Throws only when the process cannot start or outlives `timeout`; a non-zero exit is a result.
public typealias PodmanCommandRunner = @Sendable (_ executable: String, _ args: [String], _ timeout: TimeInterval) async throws
    -> PodmanCommandResult

public enum PodmanProcess {
    /// The real runner. Output is read while the process runs, so a chatty `podman pull` cannot fill a pipe and stall.
    public static let run: PodmanCommandRunner = { executable, args, timeout in
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = args
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            process.standardInput = FileHandle.nullDevice
            do { try process.run() } catch { throw PodmanDesktopError.launchFailed(executable, error.localizedDescription) }

            // Read both pipes while the process runs, so a chatty `podman pull` cannot fill one and stall.
            let outTask = Task.detached { out.fileHandleForReading.readDataToEndOfFile() }
            let errTask = Task.detached { err.fileHandleForReading.readDataToEndOfFile() }
            let deadline = Date().addingTimeInterval(timeout)
            var timedOut = false
            while process.isRunning {
                if Date() >= deadline, !timedOut {
                    timedOut = true
                    process.terminate()
                }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            let stdout = await outTask.value, stderr = await errTask.value
            if timedOut { throw PodmanDesktopError.timedOut(args.first ?? "command") }
            return PodmanCommandResult(
                stdoutData: stdout,
                stderr: String(decoding: stderr, as: UTF8.self),
                exitCode: process.terminationStatus
            )
        }.value
    }
}

// MARK: - Errors

public enum PodmanDesktopError: LocalizedError, Equatable {
    case podmanNotFound
    case machineNotRunning
    case launchFailed(String, String)
    case timedOut(String)
    case commandFailed(String, String)
    case notOurs(String)
    case unsafeExisting(String)
    case imageNotBuilt
    case displayNotReady

    public var errorDescription: String? {
        switch self {
        case .podmanNotFound:
            return "Podman is not installed. Install it (for example with Homebrew) to use a Private desktop."
        case .machineNotRunning:
            return "Podman is installed but not running. Start it with `podman machine start`."
        case .launchFailed(let path, let why):
            return "Could not run \(path): \(why)"
        case .timedOut(let command):
            return "podman \(command) took too long."
        case .commandFailed(let command, let message):
            return "podman \(command) failed: \(message)"
        case .notOurs(let name):
            return "The container \(name) was not created by GrizzyBot, so it was left alone."
        case .unsafeExisting(let name):
            return "The Private desktop \(name) is missing safety limits. Remove it and create it again."
        case .imageNotBuilt:
            return "The Private desktop image has not been built yet. Build it from Settings → Computer."
        case .displayNotReady:
            return "The Private desktop started but its screen did not come up in time."
        }
    }
}

// MARK: - Target, resources, image

public struct PodmanDesktopResources: Sendable, Equatable {
    public var memoryGb: Int
    public var cpus: Int

    public init(memoryGb: Int = 4, cpus: Int = 2) {
        self.memoryGb = max(1, memoryGb)
        self.cpus = max(1, cpus)
    }
}

/// Everything that names one bot's desktop. Identities come from a digest, never from a display name or any text a
/// caller controls, so a bot called `../x` cannot choose a path or a container.
public struct PodmanDesktopTarget: Sendable, Equatable {
    public let botDigest: String
    public let containerName: String
    public let workspaceDir: URL

    public init(botId: String, root: URL) {
        let digest = SHA256.hash(data: Data(botId.utf8)).map { String(format: "%02x", $0) }.joined()
        let short = String(digest.prefix(16))
        botDigest = digest
        containerName = "\(PodmanDesktop.containerPrefix)-\(short)"
        workspaceDir = root.appendingPathComponent("private-desktops", isDirectory: true)
            .appendingPathComponent(short, isDirectory: true)
    }
}

public enum PodmanDesktopImage {
    /// The official Cua XFCE desktop (amd64 and arm64), pinned by digest so it never changes under a running bot.
    public static let baseRepository = "docker.io/trycua/xfce-cua"
    public static let baseDigest = "sha256:274eb636f5cf3fc58f705916ee72b7a701270b3877369d08533a385c5325be9b"
    public static let base = "\(baseRepository)@\(baseDigest)"
    /// Bump when `containerfile` changes what the image holds, so desktops made from an older image are recreated.
    public static let layerVersion = "2"
    /// `localhost/` is explicit: Podman may otherwise resolve an unqualified tag on a public registry.
    public static let reference = "localhost/grizzybot/private-desktop:layer-\(layerVersion)"

    /// Where a container reaches services on the Mac: Podman maps this name, and the address behind it, to the host's own
    /// localhost. A page the bot opens must not be able to talk to a Mac service that only listens on localhost.
    static let blockedBrowserHosts = [
        "localhost", "*.localhost", "127.0.0.1", "[::1]",
        "host.containers.internal", "host.docker.internal", "192.168.127.254", "192.168.127.1",
    ]

    /// Firefox's enterprise policy that blocks those hosts.
    static var browserPolicy: String {
        let block = blockedBrowserHosts.map { "\"*://\($0)/*\"" }.joined(separator: ",")
        return "{\"policies\":{\"WebsiteFilter\":{\"Block\":[\(block)]}}}"
    }

    /// The GrizzyBot layer over the base. The base already has X (`DISPLAY=:1`, 1280x900) and `ffmpeg` with `x11grab`, which
    /// takes the screenshots; this adds `xdotool` for the mouse and keyboard, and a Firefox policy that keeps the desktop's
    /// browser off the Mac's localhost.
    public static var containerfile: String {
        """
        FROM \(base)
        USER root
        RUN set -eux; \\
            apt-get update; \\
            apt-get install -y --no-install-recommends xdotool; \\
            rm -rf /var/lib/apt/lists/*; \\
            xdotool --version
        RUN set -eux; \\
            install -d /usr/lib/firefox-esr/distribution; \\
            printf '%s\\n' '\(browserPolicy)' > /usr/lib/firefox-esr/distribution/policies.json
        LABEL \(PodmanDesktop.layerLabel)="\(layerVersion)"

        """
    }
}

// MARK: - Labels and ports

extension PodmanDesktop {
    public static let containerPrefix = "grizzybot-desktop"
    public static let managedLabel = "com.grizzybot.private-desktop"
    public static let botLabel = "com.grizzybot.private-desktop.bot"
    public static let baseLabel = "com.grizzybot.private-desktop.base"
    public static let layerLabel = "com.grizzybot.private-desktop.layer"
    public static let flagsLabel = "com.grizzybot.private-desktop.flags"
    public static let mountsLabel = "com.grizzybot.private-desktop.mounts"
    /// Bump when `runArguments` changes what a desktop is made with, so an older one is recreated.
    public static let flagsVersion = "1"

    public static let display = ":1"
    public static let guestWorkspace = "/home/cua/workspace"
    public static let viewerPort = 6901
    public static let pidsLimit = 4096

    /// What supervisord needs to start each program as `cua`, plus what apt and dpkg need to install a package as root.
    /// SYS_CHROOT is for Firefox's sandbox under Podman's default seccomp profile.
    static let capabilities = ["CHOWN", "DAC_OVERRIDE", "FOWNER", "FSETID", "SETGID", "SETUID", "SYS_CHROOT"]

    /// The arguments for `podman create` / `run`, minus the verb. Pure, so the isolation contract is testable.
    public static func runArguments(
        target: PodmanDesktopTarget,
        resources: PodmanDesktopResources = PodmanDesktopResources(),
        viewerPassword: String,
        mounts: [PodmanDesktopMount] = [],
        image: String = PodmanDesktopImage.reference
    ) -> [String] {
        let memory = "\(resources.memoryGb)g"
        var args = ["--name", target.containerName,
                    // The supervisor starts as namespace-root and drops to cua (1000); keep-id preserves the workspace owner.
                    "--userns", "keep-id:uid=1000,gid=1000", "--user", "0:0",
                    "--hostname", target.containerName]
        for (key, value) in [
            (managedLabel, "1"), (botLabel, target.botDigest),
            (baseLabel, PodmanDesktopImage.baseDigest), (layerLabel, PodmanDesktopImage.layerVersion),
            (flagsLabel, flagsVersion), (mountsLabel, PodmanDesktopMounts.digest(mounts)),
        ] {
            args += ["--label", "\(key)=\(value)"]
        }
        args += ["--memory", memory, "--memory-swap", memory, "--cpus", String(resources.cpus),
                 "--pids-limit", String(pidsLimit),
                 // Pinned so a daemon with host-mode defaults cannot make a container the hardening check rejects.
                 "--ipc", "private", "--cgroupns", "private",
                 "--cap-drop", "ALL"]
        for cap in capabilities { args += ["--cap-add", cap] }
        args += ["--shm-size", "512m",
                 "--restart", "no",
                 "--mount", "type=bind,source=\(target.workspaceDir.path),target=\(guestWorkspace),relabel=private"]
        for mount in mounts { args += ["--mount", mount.argument] }
        args += [
                 "-e", "VNC_PW=\(viewerPassword)",
                 // Loopback only, on a port the host picks: the viewer is never reachable from the network.
                 "-p", "127.0.0.1::\(viewerPort)",
                 image]
        return args
    }
}

// MARK: - Status

public struct PodmanDesktopStatus: Sendable, Equatable {
    public enum ContainerState: String, Sendable, Equatable { case missing, stopped, running }

    public var podmanPath: String?
    public var machineRunning: Bool
    public var imagePresent: Bool
    public var container: ContainerState
    /// Created by GrizzyBot (our label), not merely named like ours.
    public var managed: Bool
    public var currentFlags: Bool
    /// No privileged mode, host namespaces or public ports, only the capabilities we grant, and a memory limit.
    public var hardened: Bool
    public var viewerHostPort: Int?

    public var ready: Bool { container == .running && managed && currentFlags && hardened }

    /// What stops this desktop from working, in the person's words, or nil.
    public var problem: String? {
        if podmanPath == nil { return PodmanDesktopError.podmanNotFound.errorDescription }
        if !machineRunning { return PodmanDesktopError.machineNotRunning.errorDescription }
        if !imagePresent { return "The desktop image has not been built yet." }
        guard container != .missing else { return nil }
        if !managed { return "A container with this name exists but GrizzyBot did not create it." }
        if !currentFlags { return "This desktop was made by an older GrizzyBot. Remove it and it will be recreated." }
        if !hardened { return "This desktop is missing safety limits. Remove it and it will be recreated." }
        return nil
    }

    static let unavailable = PodmanDesktopStatus(
        podmanPath: nil, machineRunning: false, imagePresent: false, container: .missing,
        managed: false, currentFlags: false, hardened: false, viewerHostPort: nil
    )
}

/// The slice of `podman inspect` this file reads. Every field is optional: Podman omits what it has no value for.
struct PodmanInspect: Decodable {
    struct StateBlock: Decodable { var Running: Bool? }
    struct ConfigBlock: Decodable { var Labels: [String: String]? }
    struct Binding: Decodable { var HostIp: String?; var HostPort: String? }
    struct HostBlock: Decodable {
        var Privileged: Bool?
        var PidMode: String?
        var IpcMode: String?
        var NetworkMode: String?
        var Memory: Int?
        var PortBindings: [String: [Binding]?]?
    }
    /// Podman reports `HostConfig.CapDrop` as the complement of its default set, never as `ALL`, so the capabilities the
    /// container actually holds are these two.
    var EffectiveCaps: [String]?
    var BoundingCaps: [String]?
    struct MountBlock: Decodable {
        var kind: String?; var Source: String?; var Destination: String?; var RW: Bool?
        enum CodingKeys: String, CodingKey { case kind = "Type", Source, Destination, RW }
    }
    var Mounts: [MountBlock]?
    var State: StateBlock?
    var Config: ConfigBlock?
    var HostConfig: HostBlock?

    static func parse(_ json: String) -> PodmanInspect? {
        (try? JSONDecoder().decode([PodmanInspect].self, from: Data(json.utf8)))?.first
    }

    var labels: [String: String] { Config?.Labels ?? [:] }
    var running: Bool { State?.Running ?? false }

    var viewerHostPort: Int? {
        HostConfig?.PortBindings?["\(PodmanDesktop.viewerPort)/tcp"].flatMap { $0 }?.first.flatMap { Int($0.HostPort ?? "") }
    }

    /// Whether the container shows the Mac exactly what was granted: its own workspace writable, each granted folder
    /// read-only, and nothing else. Anything extra is a way for the bot to see more than it was given.
    func mountsMatch(workspace: String, mounts expected: [PodmanDesktopMount]) -> Bool {
        let actual = Mounts ?? []
        let bindings = actual.filter { $0.kind == "bind" }
        guard actual.count == bindings.count else { return false }
        guard bindings.count == expected.count + 1 else { return false }
        guard let work = bindings.first(where: { $0.Destination == PodmanDesktop.guestWorkspace }),
              work.Source == workspace, work.RW != false else { return false }
        for mount in expected {
            guard let found = bindings.first(where: { $0.Destination == mount.guestPath }),
                  found.Source == mount.source, found.RW == false else { return false }
        }
        return true
    }

    var hardened: Bool {
        guard let host = HostConfig else { return false }
        let bindings = (host.PortBindings ?? [:]).values.compactMap { $0 }.flatMap { $0 }
        let allowed = Set(PodmanDesktop.capabilities.map { "CAP_\($0)" })
        guard let effective = EffectiveCaps.map(Set.init), let bounding = BoundingCaps.map(Set.init) else { return false }
        return effective.isSubset(of: allowed) && bounding == effective
            && host.Privileged != true
            && ["", "private"].contains(host.PidMode ?? "")
            && (host.IpcMode ?? "private") == "private"
            && bindings.allSatisfy { $0.HostIp == "127.0.0.1" }
            && (host.Memory ?? 0) > 0
    }
}

// MARK: - Lifecycle

/// Creates, starts, stops and removes one hardened desktop per bot. It only ever touches containers carrying our label.
public actor PodmanDesktop {
    private let root: URL
    private let resources: PodmanDesktopResources
    private let runner: PodmanCommandRunner
    private let locate: @Sendable () -> String?
    private var inFlight: [String: Task<Void, Error>] = [:]
    private var mountsProvider: (@Sendable (String) async -> [PodmanDesktopMount])?

    public init(
        root: URL,
        resources: PodmanDesktopResources = PodmanDesktopResources(),
        runner: @escaping PodmanCommandRunner = PodmanProcess.run,
        locate: @escaping @Sendable () -> String? = PodmanDesktop.locatePodman
    ) {
        self.root = root
        self.resources = resources
        self.runner = runner
        self.locate = locate
    }

    /// Homebrew (Apple Silicon and Intel) and the system path. A GUI app does not inherit the shell's PATH.
    public static func locatePodman() -> String? {
        ["/opt/homebrew/bin/podman", "/usr/local/bin/podman", "/usr/bin/podman"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Where each bot's granted Mac folders come from. Asked when a desktop is made, so a change to the grants reaches the
    /// next desktop without anyone remembering to push it here.
    public func setMountsProvider(_ provider: (@Sendable (String) async -> [PodmanDesktopMount])?) {
        mountsProvider = provider
    }

    func mounts(for botId: String) async -> [PodmanDesktopMount] { await mountsProvider?(botId) ?? [] }

    public func target(for botId: String) -> PodmanDesktopTarget { PodmanDesktopTarget(botId: botId, root: root) }

    /// Podman and the image, which no one bot owns: what Settings shows before any desktop exists.
    public func environment() async -> PodmanDesktopStatus {
        guard let podman = locate() else { return .unavailable }
        var status = PodmanDesktopStatus.unavailable
        status.podmanPath = podman
        // `podman info` fails on macOS while the machine is stopped, so it doubles as the liveness check.
        guard let info = try? await runner(podman, ["info", "--format", "{{.Host.Arch}}"], 20), info.succeeded else { return status }
        status.machineRunning = true
        status.imagePresent = await imageExists(podman, PodmanDesktopImage.reference)
        return status
    }

    public func status(botId: String) async -> PodmanDesktopStatus {
        var status = await environment()
        guard status.podmanPath != nil, status.machineRunning else { return status }
        guard let podman = locate() else { return status }

        guard let inspect = await inspectContainer(podman, target(for: botId)) else { return status }
        status.container = inspect.running ? .running : .stopped
        status.managed = inspect.labels[Self.managedLabel] == "1"
        status.currentFlags = inspect.labels[Self.flagsLabel] == Self.flagsVersion
            && inspect.labels[Self.baseLabel] == PodmanDesktopImage.baseDigest
            && inspect.labels[Self.layerLabel] == PodmanDesktopImage.layerVersion
        status.hardened = inspect.hardened
        status.viewerHostPort = inspect.viewerHostPort
        return status
    }

    /// Makes the desktop image: downloads the pinned base (over 1 GB) and builds GrizzyBot's layer over it. Does nothing when
    /// the image is already there. Slow, so the caller shows progress rather than blocking a turn.
    public func prepareImage() async throws {
        let podman = try await requirePodman()
        if await imageExists(podman, PodmanDesktopImage.reference) { return }
        if !(await imageExists(podman, PodmanDesktopImage.base)) {
            try await check(podman, ["pull", PodmanDesktopImage.base], timeout: 15 * 60)
        }
        // The build context is a private temp folder holding only the Containerfile.
        let context = FileManager.default.temporaryDirectory.appendingPathComponent("grizzybot-image-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: context, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: context) }
        let file = context.appendingPathComponent("Containerfile")
        try Data(PodmanDesktopImage.containerfile.utf8).write(to: file, options: .atomic)
        // --force-rm: a failed step must not leave its container behind.
        try await check(podman, ["build", "--force-rm", "-t", PodmanDesktopImage.reference, "-f", file.path, context.path],
                        timeout: 15 * 60)
    }

    /// Makes the bot's desktop and leaves it stopped. Does nothing when a current one exists.
    public func create(botId: String) async throws {
        let podman = try await requirePodman()
        let target = target(for: botId)
        let mounts = await mounts(for: botId)
        if let existing = await inspectContainer(podman, target) {
            try verifyOwnedByUs(existing, target)
            // Folders granted or taken back since it was made: a container cannot change its mounts, so it is replaced.
            // Its workspace folder stays, so nothing the bot kept is lost.
            if (existing.labels[Self.mountsLabel] ?? "none") != PodmanDesktopMounts.digest(mounts) {
                try await check(podman, ["rm", "--force", "--time", "5", target.containerName], timeout: 60)
            } else {
                try verifyOurs(existing, target, mounts: mounts)
                return
            }
        }
        try FileManager.default.createDirectory(at: target.workspaceDir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // A private workspace even if the folder already existed with looser permissions.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: target.workspaceDir.path)
        let args = ["create"] + Self.runArguments(target: target, resources: resources, viewerPassword: Self.randomPassword(), mounts: mounts)
        try await check(podman, args, timeout: 120)
    }

    /// Creates the desktop if it is missing, starts it if it is stopped. Concurrent calls for one bot share one attempt.
    public func ensureRunning(botId: String) async throws {
        if let task = inFlight[botId] { return try await task.value }
        let task = Task { try await self.wake(botId: botId) }
        inFlight[botId] = task
        defer { inFlight[botId] = nil }
        try await task.value
    }

    public func stop(botId: String) async throws {
        let podman = try await requirePodman()
        let target = target(for: botId)
        guard let existing = await inspectContainer(podman, target) else { return }
        try verifyOwnedByUs(existing, target)
        if existing.running { try await check(podman, ["stop", "--time", "10", target.containerName], timeout: 60) }
    }

    /// Removes the container. The workspace folder stays: it holds the bot's files and outlives any one container.
    public func remove(botId: String) async throws {
        let podman = try await requirePodman()
        let target = target(for: botId)
        guard let existing = await inspectContainer(podman, target) else { return }
        try verifyOwnedByUs(existing, target)
        try await check(podman, ["rm", "--force", "--time", "5", target.containerName], timeout: 60)
    }

    /// Runs a command inside the bot's desktop as the `cua` user on its X display. Arguments go straight to the program,
    /// never through a shell, so text from a bot cannot become a command.
    public func exec(botId: String, _ command: [String], detached: Bool = false, timeout: TimeInterval = 30) async throws
        -> PodmanCommandResult {
        guard let podman = locate() else { throw PodmanDesktopError.podmanNotFound }
        let name = target(for: botId).containerName
        return try await runner(podman, Self.execArguments(containerName: name, command: command, detached: detached), timeout)
    }

    /// The screen as a JPEG, or nil. Never starts the desktop.
    public func screenshot(botId: String) async -> Data? {
        guard let result = try? await exec(botId: botId, XdotoolCommands.screenshot, timeout: 20),
              result.succeeded, !result.stdoutData.isEmpty else { return nil }
        return result.stdoutData
    }

    /// Waits for the desktop's X server to answer. A started container takes a few seconds before it does.
    public func waitUntilDisplayReady(botId: String, attempts: Int = 30, interval: TimeInterval = 1) async throws {
        for attempt in 0..<max(1, attempts) {
            if let result = try? await exec(botId: botId, ["xdotool", "getdisplaygeometry"], timeout: 10), result.succeeded { return }
            if attempt < attempts - 1, interval > 0 { try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000)) }
        }
        throw PodmanDesktopError.displayNotReady
    }

    /// `podman exec` arguments. The container's own X display, and the unprivileged user the desktop runs as.
    public static func execArguments(containerName: String, command: [String], detached: Bool = false) -> [String] {
        ["exec"] + (detached ? ["-d"] : []) + ["-u", "1000", "-e", "DISPLAY=\(display)", containerName] + command
    }

    // MARK: Internals

    private func wake(botId: String) async throws {
        try await create(botId: botId)
        let podman = try await requirePodman()
        let target = target(for: botId)
        if let existing = await inspectContainer(podman, target), !existing.running {
            try await check(podman, ["start", target.containerName], timeout: 60)
        }
    }

    private func requirePodman() async throws -> String {
        guard let podman = locate() else { throw PodmanDesktopError.podmanNotFound }
        guard let info = try? await runner(podman, ["info", "--format", "{{.Host.Arch}}"], 20), info.succeeded else {
            throw PodmanDesktopError.machineNotRunning
        }
        return podman
    }

    private func imageExists(_ podman: String, _ reference: String) async -> Bool {
        (try? await runner(podman, ["image", "exists", reference], 20))?.succeeded == true
    }

    private func inspectContainer(_ podman: String, _ target: PodmanDesktopTarget) async -> PodmanInspect? {
        guard let result = try? await runner(podman, ["container", "inspect", "--format", "json", target.containerName], 20),
              result.succeeded else { return nil }
        return PodmanInspect.parse(result.stdout)
    }

    private func verifyOwnedByUs(_ inspect: PodmanInspect, _ target: PodmanDesktopTarget) throws {
        guard inspect.labels[Self.managedLabel] == "1", inspect.labels[Self.botLabel] == target.botDigest else {
            throw PodmanDesktopError.notOurs(target.containerName)
        }
    }

    private func verifyOurs(_ inspect: PodmanInspect, _ target: PodmanDesktopTarget, mounts: [PodmanDesktopMount]) throws {
        try verifyOwnedByUs(inspect, target)
        guard inspect.hardened, inspect.mountsMatch(workspace: target.workspaceDir.path, mounts: mounts) else {
            throw PodmanDesktopError.unsafeExisting(target.containerName)
        }
    }

    @discardableResult
    private func check(_ podman: String, _ args: [String], timeout: TimeInterval) async throws -> PodmanCommandResult {
        let result = try await runner(podman, args, timeout)
        guard result.succeeded else {
            let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw PodmanDesktopError.commandFailed(args.first ?? "command", message.isEmpty ? "exit \(result.exitCode)" : message)
        }
        return result
    }

    private static func randomPassword() -> String {
        var bytes = [UInt8](repeating: 0, count: 18)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return UUID().uuidString.replacingOccurrences(of: "-", with: "")
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
