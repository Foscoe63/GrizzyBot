import Foundation
import Testing
@testable import GrizzyBotCore

/// Records every podman call and answers from a table, so no real Podman is needed.
private final class FakePodman: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [[String]] = []
    var machineUp = true
    var imagePresent = true
    /// The `container inspect` JSON, or nil for "no such container".
    var inspectJSON: String?
    var failing: Set<String> = []

    var runner: PodmanCommandRunner { { [self] _, args, _ in handle(args) } }

    private func handle(_ args: [String]) -> PodmanCommandResult {
        lock.withLock {
            calls.append(args)
            switch args.first ?? "" {
            case "info": return PodmanCommandResult(exitCode: machineUp ? 0 : 125)
            case "image": return PodmanCommandResult(exitCode: imagePresent ? 0 : 1)
            case "container":
                guard let inspectJSON else { return PodmanCommandResult(stderr: "no such container", exitCode: 125) }
                return PodmanCommandResult(stdout: inspectJSON)
            default:
                if failing.contains(args.first ?? "") { return PodmanCommandResult(stderr: "boom", exitCode: 125) }
                return PodmanCommandResult()
            }
        }
    }

    func call(_ verb: String) -> [String]? { lock.withLock { calls.first { $0.first == verb } } }
    func verbs() -> [String] { lock.withLock { calls.compactMap(\.first) } }
}

private let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("podman-desktop-tests-\(UUID().uuidString)")

private func inspectJSON(
    botId: String,
    running: Bool = false,
    labels: [String: String]? = nil,
    caps: [String] = PodmanDesktop.capabilities.map { "CAP_\($0)" },
    privileged: Bool = false,
    host: String = "127.0.0.1",
    memory: Int = 4_294_967_296,
    extraMounts: String = ""
) -> String {
    let target = PodmanDesktopTarget(botId: botId, root: root)
    let labels = labels ?? [
        PodmanDesktop.managedLabel: "1", PodmanDesktop.botLabel: target.botDigest,
        PodmanDesktop.baseLabel: PodmanDesktopImage.baseDigest, PodmanDesktop.layerLabel: PodmanDesktopImage.layerVersion,
        PodmanDesktop.flagsLabel: PodmanDesktop.flagsVersion,
    ]
    let labelJSON = labels.map { "\"\($0.key)\":\"\($0.value)\"" }.joined(separator: ",")
    let capJSON = caps.map { "\"\($0)\"" }.joined(separator: ",")
    return """
    [{"EffectiveCaps":[\(capJSON)],"BoundingCaps":[\(capJSON)],
      "Mounts":[{"Type":"bind","Source":"\(target.workspaceDir.path)","Destination":"\(PodmanDesktop.guestWorkspace)","RW":true}\(extraMounts)],
      "State":{"Running":\(running)},"Config":{"Labels":{\(labelJSON)}},
      "HostConfig":{"Privileged":\(privileged),"PidMode":"private","IpcMode":"private",
      "Memory":\(memory),"PortBindings":{"6901/tcp":[{"HostIp":"\(host)","HostPort":"49321"}]}}}]
    """
}

@Suite("Podman desktop")
struct PodmanDesktopTests {
    private func desktop(_ fake: FakePodman, podman: String? = "/opt/homebrew/bin/podman") -> PodmanDesktop {
        PodmanDesktop(root: root, runner: fake.runner, locate: { podman })
    }

    // MARK: Naming

    @Test("a bot's identity is a digest, so a hostile id cannot pick a path or name")
    func targetNaming() {
        let target = PodmanDesktopTarget(botId: "../../etc/passwd", root: root)
        #expect(target.containerName.hasPrefix("grizzybot-desktop-"))
        #expect(target.containerName.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" })
        #expect(target.workspaceDir.path.hasPrefix(root.appendingPathComponent("private-desktops").path))
        #expect(!target.workspaceDir.path.contains(".."))
        #expect(target == PodmanDesktopTarget(botId: "../../etc/passwd", root: root))
        #expect(target != PodmanDesktopTarget(botId: "other", root: root))
    }

    // MARK: Isolation contract

    @Test("run arguments hold the isolation contract")
    func runArguments() {
        let target = PodmanDesktopTarget(botId: "bot-1", root: root)
        let args = PodmanDesktop.runArguments(target: target, viewerPassword: "pw")
        func value(after flag: String) -> String? { args.firstIndex(of: flag).map { args[$0 + 1] } }

        #expect(value(after: "--cap-drop") == "ALL")
        #expect(!args.contains("--privileged"))
        #expect(value(after: "--ipc") == "private")
        #expect(value(after: "--cgroupns") == "private")
        #expect(value(after: "--memory") == "4g" && value(after: "--memory-swap") == "4g")
        #expect(value(after: "--cpus") == "2")
        #expect(value(after: "--pids-limit") == "4096")
        #expect(value(after: "-p") == "127.0.0.1::6901")
        #expect(!args.contains("--network") && !args.contains("--pid"))
        #expect(args.last == PodmanDesktopImage.reference)
        #expect(PodmanDesktopImage.reference.hasPrefix("localhost/"))
        #expect(PodmanDesktopImage.base.contains("@sha256:"))

        let caps = args.enumerated().filter { $0.element == "--cap-add" }.map { args[$0.offset + 1] }
        #expect(!caps.contains("SYS_ADMIN") && !caps.contains("NET_ADMIN") && !caps.contains("ALL"))

        // The only host folder shared is this bot's own workspace.
        let mounts = args.enumerated().filter { $0.element == "--mount" }.map { args[$0.offset + 1] }
        #expect(mounts.count == 1)
        #expect(mounts[0].contains("source=\(target.workspaceDir.path)"))
        #expect(mounts[0].contains("target=/home/cua/workspace"))
    }

    @Test("two bots never share a container or a folder")
    func botsAreDisjoint() {
        let a = PodmanDesktop.runArguments(target: PodmanDesktopTarget(botId: "a", root: root), viewerPassword: "x")
        let b = PodmanDesktop.runArguments(target: PodmanDesktopTarget(botId: "b", root: root), viewerPassword: "x")
        #expect(a.filter { $0.hasPrefix("type=bind") } != b.filter { $0.hasPrefix("type=bind") })
        #expect(a[1] != b[1])
    }

    // MARK: Status

    @Test("no podman reports it plainly")
    func noPodman() async {
        let status = await desktop(FakePodman(), podman: nil).status(botId: "b")
        #expect(status.podmanPath == nil)
        #expect(status.problem?.contains("not installed") == true)
    }

    @Test("a stopped machine is reported, and nothing else is asked")
    func machineDown() async {
        let fake = FakePodman()
        fake.machineUp = false
        let status = await desktop(fake).status(botId: "b")
        #expect(status.machineRunning == false)
        #expect(status.problem?.contains("podman machine start") == true)
        #expect(fake.verbs() == ["info"])
    }

    @Test("a missing desktop is not a problem once the image is there")
    func missingContainer() async {
        let status = await desktop(FakePodman()).status(botId: "b")
        #expect(status.container == .missing)
        #expect(status.imagePresent)
        #expect(status.problem == nil)
        #expect(!status.ready)
    }

    @Test("a missing image is reported before anything is created")
    func missingImage() async {
        let fake = FakePodman()
        fake.imagePresent = false
        #expect(await desktop(fake).status(botId: "b").problem?.contains("image") == true)
    }

    @Test("a running hardened desktop is ready and reports its loopback port")
    func ready() async {
        let fake = FakePodman()
        fake.inspectJSON = inspectJSON(botId: "b", running: true)
        let status = await desktop(fake).status(botId: "b")
        #expect(status.ready)
        #expect(status.viewerHostPort == 49321)
    }

    @Test("a desktop that publishes its viewer beyond loopback is not hardened")
    func publicPort() async {
        let fake = FakePodman()
        fake.inspectJSON = inspectJSON(botId: "b", running: true, host: "0.0.0.0")
        let status = await desktop(fake).status(botId: "b")
        #expect(!status.hardened && !status.ready)
    }

    @Test("privileged, extra capabilities, or no memory limit are not hardened")
    func unhardened() async {
        for json in [
            inspectJSON(botId: "b", privileged: true),
            inspectJSON(botId: "b", caps: ["CAP_SYS_ADMIN"]),
            inspectJSON(botId: "b", memory: 0),
        ] {
            let fake = FakePodman()
            fake.inspectJSON = json
            #expect(await desktop(fake).status(botId: "b").hardened == false)
        }
    }

    @Test("a container with our name but no label is not ours")
    func notManaged() async {
        let fake = FakePodman()
        fake.inspectJSON = inspectJSON(botId: "b", labels: [:])
        let status = await desktop(fake).status(botId: "b")
        #expect(!status.managed)
        #expect(status.problem?.contains("did not create") == true)
    }

    @Test("an older flag version asks for a recreate")
    func olderFlags() async {
        let fake = FakePodman()
        let target = PodmanDesktopTarget(botId: "b", root: root)
        fake.inspectJSON = inspectJSON(botId: "b", labels: [
            PodmanDesktop.managedLabel: "1", PodmanDesktop.botLabel: target.botDigest,
            PodmanDesktop.baseLabel: PodmanDesktopImage.baseDigest, PodmanDesktop.layerLabel: PodmanDesktopImage.layerVersion,
            PodmanDesktop.flagsLabel: "0",
        ])
        let status = await desktop(fake).status(botId: "b")
        #expect(!status.currentFlags)
        #expect(status.problem?.contains("older") == true)
    }

    // MARK: Lifecycle

    @Test("create makes a missing desktop and gives it a private workspace folder")
    func createsWhenMissing() async throws {
        let fake = FakePodman()
        try await desktop(fake).create(botId: "fresh")
        #expect(fake.verbs().contains("create"))
        let target = PodmanDesktopTarget(botId: "fresh", root: root)
        let mode = try FileManager.default.attributesOfItem(atPath: target.workspaceDir.path)[.posixPermissions] as? Int
        #expect(mode == 0o700)
        try? FileManager.default.removeItem(at: root)
    }

    @Test("ensureRunning starts a stopped desktop and does not recreate it")
    func startsStopped() async throws {
        let fake = FakePodman()
        fake.inspectJSON = inspectJSON(botId: "b", running: false)
        try await desktop(fake).ensureRunning(botId: "b")
        #expect(fake.verbs().contains("start"))
        #expect(!fake.verbs().contains("create"))
    }

    @Test("ensureRunning leaves a running desktop alone")
    func leavesRunning() async throws {
        let fake = FakePodman()
        fake.inspectJSON = inspectJSON(botId: "b", running: true)
        try await desktop(fake).ensureRunning(botId: "b")
        #expect(!fake.verbs().contains("start") && !fake.verbs().contains("create"))
    }

    @Test("an existing desktop missing its safety limits is refused, not started")
    func refusesUnsafe() async {
        let fake = FakePodman()
        fake.inspectJSON = inspectJSON(botId: "b", caps: ["CAP_SYS_ADMIN"])
        await #expect(throws: PodmanDesktopError.unsafeExisting(PodmanDesktopTarget(botId: "b", root: root).containerName)) {
            try await desktop(fake).ensureRunning(botId: "b")
        }
        #expect(!fake.verbs().contains("start"))
    }

    @Test("stop and remove never touch a container GrizzyBot did not create")
    func leavesForeignContainers() async {
        let fake = FakePodman()
        fake.inspectJSON = inspectJSON(botId: "b", running: true, labels: [:])
        let name = PodmanDesktopTarget(botId: "b", root: root).containerName
        await #expect(throws: PodmanDesktopError.notOurs(name)) { try await desktop(fake).stop(botId: "b") }
        await #expect(throws: PodmanDesktopError.notOurs(name)) { try await desktop(fake).remove(botId: "b") }
        #expect(!fake.verbs().contains("stop") && !fake.verbs().contains("rm"))
    }

    @Test("a container labelled for a different bot is not this bot's")
    func differentBotLabel() async {
        let fake = FakePodman()
        fake.inspectJSON = inspectJSON(botId: "someone-else", running: true)
        // The name collides but the bot label names another bot.
        let name = PodmanDesktopTarget(botId: "b", root: root).containerName
        await #expect(throws: PodmanDesktopError.notOurs(name)) { try await desktop(fake).remove(botId: "b") }
    }

    @Test("remove stops after removing our own container and keeps the workspace")
    func removeOurs() async throws {
        let fake = FakePodman()
        fake.inspectJSON = inspectJSON(botId: "b", running: true)
        try await desktop(fake).remove(botId: "b")
        #expect(fake.verbs().contains("rm"))
    }

    @Test("a failing podman command surfaces its message")
    func commandFailure() async {
        let fake = FakePodman()
        fake.imagePresent = false
        fake.failing = ["pull"]
        await #expect(throws: PodmanDesktopError.commandFailed("pull", "boom")) { try await desktop(fake).prepareImage() }
    }

    @Test("prepareImage does nothing when the image exists")
    func imageAlreadyBuilt() async throws {
        let fake = FakePodman()
        try await desktop(fake).prepareImage()
        #expect(!fake.verbs().contains("pull") && !fake.verbs().contains("build"))
    }

    @Test("prepareImage pulls the pinned base, then builds the layer from a Containerfile")
    func buildsImage() async throws {
        let fake = FakePodman()
        fake.imagePresent = false
        try await desktop(fake).prepareImage()
        #expect(fake.verbs().contains("pull") && fake.verbs().last == "build")
        let build = try #require(fake.call("build"))
        #expect(build.contains("--force-rm"))
        #expect(build[build.firstIndex(of: "-t")! + 1] == PodmanDesktopImage.reference)
        #expect(fake.call("pull") == ["pull", PodmanDesktopImage.base])
    }

    @Test("the Containerfile builds on the pinned base, adds only xdotool, and ends as root for the supervisor")
    func containerfile() {
        let text = PodmanDesktopImage.containerfile
        #expect(text.hasPrefix("FROM \(PodmanDesktopImage.base)\n"))
        #expect(text.contains("@sha256:"))
        #expect(text.contains("apt-get install -y --no-install-recommends xdotool"))
        #expect(text.contains("\(PodmanDesktop.layerLabel)=\"\(PodmanDesktopImage.layerVersion)\""))
        #expect(text.components(separatedBy: "apt-get install").count == 2)
        #expect(!text.contains("curl") && !text.contains("wget"))
    }

    @Test("the layer installs a Firefox policy that blocks the Mac's loopback and the host alias")
    func browserPolicy() throws {
        #expect(PodmanDesktopImage.containerfile.contains("/usr/lib/firefox-esr/distribution/policies.json"))
        let data = Data(PodmanDesktopImage.browserPolicy.utf8)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let filter = try #require((json["policies"] as? [String: Any])?["WebsiteFilter"] as? [String: Any])
        let block = try #require(filter["Block"] as? [String])
        for host in ["localhost", "127.0.0.1", "host.containers.internal"] {
            #expect(block.contains("*://\(host)/*"))
        }
    }

    @Test("lifecycle calls report podman missing and the machine down distinctly")
    func requireErrors() async {
        await #expect(throws: PodmanDesktopError.podmanNotFound) { try await desktop(FakePodman(), podman: nil).ensureRunning(botId: "b") }
        let down = FakePodman()
        down.machineUp = false
        await #expect(throws: PodmanDesktopError.machineNotRunning) { try await desktop(down).ensureRunning(botId: "b") }
    }
}

@Suite("Private desktop mode")
struct PrivateDesktopModeTests {
    @Test("the new mode round-trips and is offered in Settings")
    func mode() throws {
        #expect(ComputerMode.parse("private-desktop") == .privateDesktop)
        #expect(ComputerMode.privateDesktop.label == "Private desktop")
        #expect(String(data: try JSONEncoder().encode(ComputerMode.privateDesktop), encoding: .utf8) == #""private-desktop""#)
        #expect(try JSONDecoder().decode(ComputerMode.self, from: Data(#""private-desktop""#.utf8)) == .privateDesktop)
        #expect(ComputerMode.selectableCases.contains(.privateDesktop))
        // Saved bots from before this mode keep meaning what they meant.
        #expect(ComputerMode.parse("vm") == .inAppBrowser)
    }
}

@Suite("Private desktop Mac folders")
struct PrivateDesktopFolderTests {
    /// A folder tree under a temporary "home", with that folder as the one place a desktop may see.
    private func tree(_ names: [String]) throws -> (home: String, visible: [String], dirs: [String]) {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pd-folders-\(UUID().uuidString)")
        let home = base.appendingPathComponent("home")
        var dirs: [String] = []
        for name in names {
            let url = home.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            dirs.append(PodmanDesktopMounts.canonical(url.path))
        }
        return (PodmanDesktopMounts.canonical(home.path), [PodmanDesktopMounts.canonical(base.path)], dirs)
    }

    @Test("a plain folder under the visible roots becomes a mount named after it")
    func resolves() throws {
        let t = try tree(["Taxes", "Photos"])
        let folders = [GrantedFolder(name: "Taxes 2025", path: t.dirs[0]), GrantedFolder(name: "Photos", path: t.dirs[1])]
        let result = PodmanDesktopMounts.resolve(folders, home: t.home, visibleRoots: t.visible)
        #expect(result.skipped.isEmpty)
        #expect(result.mounts.map(\.name) == ["Taxes-2025", "Photos"])
        #expect(result.mounts[0].guestPath == "/mnt/mac/Taxes-2025")
        #expect(result.mounts[0].argument == "type=bind,source=\(t.dirs[0]),target=/mnt/mac/Taxes-2025,ro=true")
    }

    @Test("an offline desktop has no network and publishes no port; an online one is unchanged")
    func offlineArguments() throws {
        let target = PodmanDesktopTarget(botId: "bot-1", root: root)
        let on = PodmanDesktop.runArguments(target: target, viewerPassword: "pw")
        let off = PodmanDesktop.runArguments(target: target, viewerPassword: "pw", offline: true)
        #expect(!on.contains("--network"))
        #expect(off.firstIndex(of: "--network").map { off[$0 + 1] } == "none")
        #expect(!off.contains("-p"))
        #expect(off.last == PodmanDesktopImage.reference)
        #expect(off.contains("\(PodmanDesktop.networkLabel)=none") && on.contains("\(PodmanDesktop.networkLabel)=on"))
    }

    @Test("an existing container only counts as offline when it has no network and no ports")
    func offlineInspect() throws {
        func inspect(_ mode: String, _ ports: String) throws -> PodmanInspect {
            try #require(PodmanInspect.parse(#"[{"HostConfig":{"NetworkMode":"\#(mode)","PortBindings":\#(ports)}}]"#))
        }
        #expect(try inspect("none", "{}").networkMatches(offline: true))
        #expect(try !inspect("bridge", "{}").networkMatches(offline: true))
        #expect(try !inspect("none", #"{"6901/tcp":[{"HostIp":"127.0.0.1","HostPort":"5000"}]}"#).networkMatches(offline: true))
        #expect(try inspect("bridge", "{}").networkMatches(offline: false))
    }

    @Test("a writable folder mounts read-write, a copy needs no mount, and the mode changes the digest")
    func writableAndCopy() throws {
        let t = try tree(["Work", "Notes"])
        let work = GrantedFolder(name: "Work", path: t.dirs[0])
        let notes = GrantedFolder(name: "Notes", path: t.dirs[1])
        let rw = PodmanDesktopMounts.resolve([work], modes: [work.id: .writable], home: t.home, visibleRoots: t.visible)
        #expect(rw.mounts.first?.argument.hasSuffix("ro=false") == true)
        let ro = PodmanDesktopMounts.resolve([work], home: t.home, visibleRoots: t.visible)
        #expect(ro.mounts.first?.argument.hasSuffix("ro=true") == true)
        #expect(PodmanDesktopMounts.digest(rw.mounts) != PodmanDesktopMounts.digest(ro.mounts))
        let mixed = PodmanDesktopMounts.resolve([work, notes], modes: [notes.id: .copy], home: t.home, visibleRoots: t.visible)
        #expect(mixed.mounts.map(\.name) == ["Work"], "a copy lives in the workspace, not in a mount")
    }

    @Test("a folder of nothing is copied, a symlink is not followed, and a huge one is refused")
    func copying() throws {
        let t = try tree(["Src"])
        let src = URL(fileURLWithPath: t.dirs[0])
        try "hello".write(to: src.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        #expect(DesktopFolderCopy.sizeRefusal(of: src) == nil)
        let ws = URL(fileURLWithPath: t.home).appendingPathComponent("ws")
        let dest = DesktopFolderCopy.hostPath(workspace: ws, name: "Src")
        try DesktopFolderCopy.make(from: src, to: dest)
        try "changed".write(to: dest.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        #expect(try String(contentsOf: src.appendingPathComponent("a.txt"), encoding: .utf8) == "hello")
        #expect(DesktopFolderCopy.guestPath(name: "Src") == "/home/cua/workspace/copies/Src")
    }

    @Test("two folders with one name get different guest folders, and one folder twice is one mount")
    func names() throws {
        let t = try tree(["a/Docs", "b/Docs"])
        let folders = [GrantedFolder(name: "Docs", path: t.dirs[0]), GrantedFolder(name: "Docs", path: t.dirs[1]),
                       GrantedFolder(name: "Again", path: t.dirs[0])]
        let result = PodmanDesktopMounts.resolve(folders, home: t.home, visibleRoots: t.visible)
        #expect(result.mounts.map(\.name) == ["Docs", "Docs-2"])
    }

    @Test("what must never be shown is refused with a reason")
    func refusals() throws {
        let t = try tree([".ssh", "Library/Mail", "Work", "GrizzyData"])
        let file = URL(fileURLWithPath: t.home).appendingPathComponent("note.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        let cases: [(String, String)] = [
            (t.dirs[0], "secrets"), (t.dirs[1], "Library"), (t.home, "home folder"),
            (URL(fileURLWithPath: t.home).deletingLastPathComponent().path, "parent"), ("/", "parent"),
            (file.path, "not a folder"), (t.home + "/missing", "missing"), ("relative/path", "absolute"),
            (t.dirs[3], "GrizzyBot's own data"),
        ]
        for (path, word) in cases {
            let result = PodmanDesktopMounts.resolve([GrantedFolder(name: "x", path: path)], home: t.home,
                                                     protectedPaths: [t.dirs[3]], visibleRoots: t.visible)
            #expect(result.mounts.isEmpty, "\(path)")
            #expect(result.skipped.first?.reason.contains(word) == true, "\(path): \(result.skipped.first?.reason ?? "")")
        }
        // Outside what Podman's VM can see.
        let outside = PodmanDesktopMounts.resolve([GrantedFolder(name: "x", path: t.dirs[2])], home: t.home, visibleRoots: ["/Users"])
        #expect(outside.skipped.first?.reason.contains("/Users") == true)
    }

    @Test("a symlink cannot name a place outside what is allowed")
    func symlink() throws {
        let t = try tree(["Work"])
        let link = URL(fileURLWithPath: t.home).appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/etc"))
        let result = PodmanDesktopMounts.resolve([GrantedFolder(name: "x", path: link.path)], home: t.home, visibleRoots: t.visible)
        #expect(result.mounts.isEmpty)
    }

    @Test("a comma in a path cannot add mount options")
    func comma() throws {
        let t = try tree(["a,b"])
        let result = PodmanDesktopMounts.resolve([GrantedFolder(name: "x", path: t.dirs[0])], home: t.home, visibleRoots: t.visible)
        #expect(result.mounts.isEmpty)
    }

    @Test("the digest changes with the folders and is 'none' without any")
    func digest() {
        let a = PodmanDesktopMount(source: "/Users/x/a", name: "a")
        let b = PodmanDesktopMount(source: "/Users/x/b", name: "b")
        #expect(PodmanDesktopMounts.digest([]) == "none")
        #expect(PodmanDesktopMounts.digest([a]) != PodmanDesktopMounts.digest([a, b]))
        #expect(PodmanDesktopMounts.digest([a, b]) == PodmanDesktopMounts.digest([b, a]))
    }

    @Test("create passes each mount read-only and labels the container with the set")
    func runArgs() {
        let mount = PodmanDesktopMount(source: "/Users/x/Taxes", name: "Taxes")
        let args = PodmanDesktop.runArguments(target: PodmanDesktopTarget(botId: "b", root: root), viewerPassword: "p", mounts: [mount])
        #expect(args.contains("type=bind,source=/Users/x/Taxes,target=/mnt/mac/Taxes,ro=true"))
        #expect(args.contains("\(PodmanDesktop.mountsLabel)=\(PodmanDesktopMounts.digest([mount]))"))
        let plain = PodmanDesktop.runArguments(target: PodmanDesktopTarget(botId: "b", root: root), viewerPassword: "p")
        #expect(plain.filter { $0 == "--mount" }.count == 1)
        #expect(plain.contains("\(PodmanDesktop.mountsLabel)=none"))
    }

    @Test("a container is safe only when its mounts are exactly the workspace and the granted folders, read-only")
    func mountsMatch() throws {
        let target = PodmanDesktopTarget(botId: "b", root: root)
        let mount = PodmanDesktopMount(source: "/Users/x/Taxes", name: "Taxes")
        func inspect(_ extra: String) throws -> PodmanInspect {
            try #require(PodmanInspect.parse("""
            [{"Mounts":[{"Type":"bind","Source":"\(target.workspaceDir.path)","Destination":"\(PodmanDesktop.guestWorkspace)","RW":true}\(extra)]}]
            """))
        }
        let granted = #",{"Type":"bind","Source":"/Users/x/Taxes","Destination":"/mnt/mac/Taxes","RW":false}"#
        #expect(try inspect("").mountsMatch(workspace: target.workspaceDir.path, mounts: []))
        #expect(try inspect(granted).mountsMatch(workspace: target.workspaceDir.path, mounts: [mount]))
        // Writable, extra, missing, or from somewhere else: all unsafe.
        #expect(try !inspect(granted.replacingOccurrences(of: "false", with: "true")).mountsMatch(workspace: target.workspaceDir.path, mounts: [mount]))
        #expect(try !inspect(granted).mountsMatch(workspace: target.workspaceDir.path, mounts: []))
        #expect(try !inspect("").mountsMatch(workspace: target.workspaceDir.path, mounts: [mount]))
        #expect(try !inspect(granted.replacingOccurrences(of: "/Users/x/Taxes\"", with: "/Users/x/Other\"")).mountsMatch(workspace: target.workspaceDir.path, mounts: [mount]))
        #expect(try !inspect(#",{"Type":"bind","Source":"/","Destination":"/host","RW":true}"#).mountsMatch(workspace: target.workspaceDir.path, mounts: []))
        #expect(try !inspect(#",{"Type":"volume","Destination":"/v","RW":true}"#).mountsMatch(workspace: target.workspaceDir.path, mounts: []))
    }

    @Test("a desktop made before a folder was granted is replaced; one that already matches is left alone")
    func recreatesOnChange() async throws {
        let t = try tree(["Taxes"])
        let mount = PodmanDesktopMount(source: t.dirs[0], name: "Taxes")
        let fake = FakePodman()
        fake.inspectJSON = inspectJSON(botId: "b", running: false)
        let desktop = PodmanDesktop(root: root, runner: fake.runner, locate: { "/opt/homebrew/bin/podman" })
        await desktop.setMountsProvider { _ in [mount] }
        try await desktop.create(botId: "b")
        #expect(fake.verbs().contains("rm"))
        #expect(fake.verbs().contains("create"))
        let create = try #require(fake.call("create"))
        #expect(create.contains(mount.argument))

        let quiet = FakePodman()
        quiet.inspectJSON = inspectJSON(botId: "b", running: false)
        try await PodmanDesktop(root: root, runner: quiet.runner, locate: { "/opt/homebrew/bin/podman" }).create(botId: "b")
        #expect(!quiet.verbs().contains("rm") && !quiet.verbs().contains("create"))
    }

    @Test("a desktop whose label matches but whose mounts do not is refused, not reused")
    func refusesWrongMounts() async throws {
        let fake = FakePodman()
        let target = PodmanDesktopTarget(botId: "b", root: root)
        // Labelled as having no folders, yet holding an extra bind of the Mac's root.
        fake.inspectJSON = inspectJSON(botId: "b", running: true,
            extraMounts: #",{"Type":"bind","Source":"/","Destination":"/host","RW":true}"#)
        _ = target
        await #expect(throws: PodmanDesktopError.unsafeExisting(target.containerName)) {
            try await PodmanDesktop(root: root, runner: fake.runner, locate: { "p" }).create(botId: "b")
        }
    }
}
