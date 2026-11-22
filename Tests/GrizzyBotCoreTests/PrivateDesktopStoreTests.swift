import Foundation
import Testing
@testable import GrizzyBotCore

/// A Podman whose one container for `botId` can be missing, stopped or running, and that records what was asked of it.
private final class StatefulPodman: @unchecked Sendable {
    enum Container { case missing, stopped, running }
    private let lock = NSLock()
    private var verbsSeen: [String] = []
    private var container: Container
    let botId: String
    var jpeg = DesktopImage.render(text: "x")
    var imagePresent = true

    init(botId: String, container: Container) { self.botId = botId; self.container = container }

    var runner: PodmanCommandRunner { { [self] _, args, _ in handle(args) } }
    func verbs() -> [String] { lock.withLock { verbsSeen } }

    private func inspect(running: Bool) -> String {
        let target = PodmanDesktopTarget(botId: botId, root: URL(fileURLWithPath: "/tmp/gb-store-tests"))
        let caps = PodmanDesktop.capabilities.map { "\"CAP_\($0)\"" }.joined(separator: ",")
        return """
        [{"EffectiveCaps":[\(caps)],"BoundingCaps":[\(caps)],"Mounts":[{"Type":"bind","Source":"\(target.workspaceDir.path)","Destination":"\(PodmanDesktop.guestWorkspace)","RW":true}],"State":{"Running":\(running)},
          "Config":{"Labels":{"\(PodmanDesktop.managedLabel)":"1","\(PodmanDesktop.botLabel)":"\(target.botDigest)",
          "\(PodmanDesktop.baseLabel)":"\(PodmanDesktopImage.baseDigest)","\(PodmanDesktop.layerLabel)":"\(PodmanDesktopImage.layerVersion)",
          "\(PodmanDesktop.flagsLabel)":"\(PodmanDesktop.flagsVersion)"}},
          "HostConfig":{"Privileged":false,"PidMode":"private","IpcMode":"private","Memory":4294967296,
          "PortBindings":{"6901/tcp":[{"HostIp":"127.0.0.1","HostPort":"40000"}]}}}]
        """
    }

    private func handle(_ args: [String]) -> PodmanCommandResult {
        lock.withLock {
            let verb = args.first ?? ""
            if verb != "info" && verb != "image" && verb != "container" { verbsSeen.append(verb) }
            switch verb {
            case "info": return PodmanCommandResult()
            case "image": return PodmanCommandResult(exitCode: imagePresent ? 0 : 1)
            case "container":
                return container == .missing ? PodmanCommandResult(stderr: "no such container", exitCode: 125)
                    : PodmanCommandResult(stdout: inspect(running: container == .running))
            case "create": container = .stopped; return PodmanCommandResult()
            case "start": container = .running; return PodmanCommandResult()
            case "stop": container = .stopped; return PodmanCommandResult()
            case "rm": container = .missing; return PodmanCommandResult()
            case "exec":
                return args.contains("ffmpeg") ? PodmanCommandResult(stdoutData: jpeg) : PodmanCommandResult(stdout: "1280 900\n")
            default: return PodmanCommandResult()
            }
        }
    }
}

@MainActor
@Suite("Private desktop in the store")
struct PrivateDesktopStoreTests {
    private func store(_ podman: StatefulPodman) -> (AppStore, String) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("GrizzyBotTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = AppStore(dataDirectory: dir, delayScale: 0.01)
        _ = store.signUp(name: "A", email: "pd@b.com", password: "password1")
        let bot = store.createBot(name: "Agent", title: "helper")
        store.privateDesktop = PodmanDesktop(root: dir, runner: podman.runner, locate: { "/opt/homebrew/bin/podman" })
        return (store, bot.id)
    }

    /// Waits for a store's background Task to finish what it was asked.
    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    @Test("a bot resolves to a Private desktop by its own mode or the default, but Auto never picks it")
    func resolution() {
        let (store, botId) = store(StatefulPodman(botId: "x", container: .missing))
        #expect(!store.isPrivateDesktop(botId: botId))
        store.patchBot(botId, computerMode: .privateDesktop)
        #expect(store.isPrivateDesktop(botId: botId))
        store.patchBot(botId, computerMode: .auto)
        #expect(!store.isPrivateDesktop(botId: botId))
        var config = store.appConfig
        config.defaultComputerMode = .privateDesktop
        store.saveAppConfig(config)
        #expect(store.isPrivateDesktop(botId: botId))
        #expect(!store.isPrivateDesktop(botId: "no-such-bot"))
    }

    @Test("looking at a running desktop returns its screen")
    func refreshRunning() async {
        let (store, botId) = store(StatefulPodman(botId: "", container: .running))
        let podman = StatefulPodman(botId: botId, container: .running)
        store.privateDesktop = PodmanDesktop(root: URL(fileURLWithPath: "/tmp/gb-store-tests"), runner: podman.runner, locate: { "p" })
        await store.refreshPrivateDesktop(botId: botId)
        let state = store.privateDesktopState(botId: botId)
        #expect(state.status?.ready == true)
        #expect(state.frame == podman.jpeg)
    }

    @Test("looking at a stopped or missing desktop never starts it")
    func lookingDoesNotStart() async {
        for container in [StatefulPodman.Container.stopped, .missing] {
            let (store, botId) = store(StatefulPodman(botId: "", container: .missing))
            let podman = StatefulPodman(botId: botId, container: container)
            store.privateDesktop = PodmanDesktop(root: URL(fileURLWithPath: "/tmp/gb-store-tests"), runner: podman.runner, locate: { "p" })
            await store.refreshPrivateDesktop(botId: botId)
            #expect(store.privateDesktopState(botId: botId).frame == nil)
            #expect(!podman.verbs().contains("start") && !podman.verbs().contains("create") && !podman.verbs().contains("exec"))
        }
    }

    @Test("start brings a missing desktop up, shows progress meanwhile, and refreshes its state")
    func start() async {
        let (store, botId) = store(StatefulPodman(botId: "", container: .missing))
        let podman = StatefulPodman(botId: botId, container: .missing)
        store.privateDesktop = PodmanDesktop(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("gb-start-\(UUID().uuidString)"), runner: podman.runner, locate: { "p" })
        store.startPrivateDesktop(botId: botId)
        #expect(store.privateDesktopState(botId: botId).working == "Starting the desktop…")
        #expect(await eventually { store.privateDesktopState(botId: botId).working == nil && store.privateDesktopState(botId: botId).status != nil })
        #expect(podman.verbs().contains("create") && podman.verbs().contains("start"))
        #expect(store.privateDesktopState(botId: botId).status?.container == .running)
        #expect(store.privateDesktopState(botId: botId).error == nil)
    }

    @Test("a second start while one is running does nothing")
    func startOnce() async {
        let (store, botId) = store(StatefulPodman(botId: "", container: .missing))
        let podman = StatefulPodman(botId: botId, container: .stopped)
        store.privateDesktop = PodmanDesktop(root: URL(fileURLWithPath: "/tmp/gb-store-tests"), runner: podman.runner, locate: { "p" })
        store.startPrivateDesktop(botId: botId)
        store.startPrivateDesktop(botId: botId)
        #expect(await eventually { store.privateDesktopState(botId: botId).working == nil && store.privateDesktopState(botId: botId).status != nil })
        #expect(podman.verbs().filter { $0 == "start" }.count == 1)
    }

    @Test("a failure is shown in words and clears the progress")
    func failure() async {
        let (store, botId) = store(StatefulPodman(botId: "", container: .missing))
        store.privateDesktop = PodmanDesktop(root: URL(fileURLWithPath: "/tmp/gb-store-tests"),
                                             runner: { _, _, _ in PodmanCommandResult(stderr: "boom", exitCode: 125) }, locate: { nil })
        store.startPrivateDesktop(botId: botId)
        #expect(await eventually { store.privateDesktopState(botId: botId).working == nil })
        #expect(store.privateDesktopState(botId: botId).error?.contains("not installed") == true)
    }

    @Test("reset removes the container")
    func reset() async {
        let (store, botId) = store(StatefulPodman(botId: "", container: .missing))
        let podman = StatefulPodman(botId: botId, container: .running)
        store.privateDesktop = PodmanDesktop(root: URL(fileURLWithPath: "/tmp/gb-store-tests"), runner: podman.runner, locate: { "p" })
        store.resetPrivateDesktop(botId: botId)
        #expect(await eventually { podman.verbs().contains("rm") })
    }

    @Test("a bot that leaves Private desktop has its container stopped; one that stays is left running")
    func leavingStops() async {
        let (store, leaver) = store(StatefulPodman(botId: "", container: .missing))
        let stayer = store.createBot(name: "Stayer", title: "t").id
        store.patchBot(leaver, computerMode: .privateDesktop)
        store.patchBot(stayer, computerMode: .privateDesktop)

        let leaverPodman = StatefulPodman(botId: leaver, container: .running)
        // One Podman answers for whichever bot is asked, by container name.
        let stayerPodman = StatefulPodman(botId: stayer, container: .running)
        let leaverName = PodmanDesktopTarget(botId: leaver, root: URL(fileURLWithPath: "/")).containerName
        store.privateDesktop = PodmanDesktop(root: URL(fileURLWithPath: "/tmp/gb-store-tests"),
            runner: { exe, args, timeout in
                args.contains(leaverName) ? try await leaverPodman.runner(exe, args, timeout) : try await stayerPodman.runner(exe, args, timeout)
            }, locate: { "p" })

        store.patchBot(leaver, computerMode: .off)
        #expect(await eventually { leaverPodman.verbs().contains("stop") })
        #expect(!stayerPodman.verbs().contains("stop"))
    }

    @Test("a person cannot take over a Private desktop: request_takeover is refused and audited, and control stays with the bot")
    func takeoverRefused() async {
        let (store, botId) = store(StatefulPodman(botId: "", container: .missing))
        store.patchBot(botId, computerMode: .privateDesktop)
        let result = await store.executeAgentTool(
            name: "request_takeover", argumentsJSON: #"{"reason":"sign in"}"#, botId: botId, depth: 0,
            endpoint: ModelEndpoint(provider: "p", model: "m", baseURL: "https://localhost", apiKey: ""),
            client: ByBotClient([:]), taint: RunTaint()
        )
        #expect(result.output.hasPrefix("Refused request_takeover"))
        #expect(result.pause == nil)
        #expect(store.computers[botId]?.controlHolder != .user)
        #expect(store.auditEvents.contains { $0.type == .computerActionRefused && $0.botId == botId && $0.tool == "request_takeover" })
    }

    @Test("take control does nothing for a Private desktop")
    func takeControlNoop() {
        let (store, botId) = store(StatefulPodman(botId: "", container: .missing))
        store.patchBot(botId, computerMode: .privateDesktop)
        store.takeControl(botId: botId)
        #expect(store.computers[botId]?.controlHolder != .user)
    }

    @Test("a granted folder can be shown in the desktop; one the bot is not granted, or that is unsafe, cannot")
    func desktopFolders() throws {
        let (store, botId) = store(StatefulPodman(botId: "", container: .missing))
        store.patchBot(botId, computerMode: .privateDesktop)
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("gb-desktop-folder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = try #require(store.addGrantedFolder(path: dir.path, name: "Taxes"))

        store.setDesktopFolder(botId: botId, folderId: folder.id, shown: true)
        #expect(store.bots.first { $0.id == botId }?.desktopFolderIds == [], "not granted to the bot yet")

        store.setBotFolder(botId, folderId: folder.id, granted: true)
        store.setDesktopFolder(botId: botId, folderId: folder.id, shown: true)
        #expect(store.bots.first { $0.id == botId }?.desktopFolderIds == [folder.id])
        #expect(store.privateDesktopFolders(botId: botId).mounts.map(\.name) == ["Taxes"])
        #expect(store.auditEvents.contains { $0.tool == "private_desktop_folder" && $0.botId == botId })

        let home = try #require(store.addGrantedFolder(path: NSHomeDirectory(), name: "Home"))
        store.setBotFolder(botId, folderId: home.id, granted: true)
        store.setDesktopFolder(botId: botId, folderId: home.id, shown: true)
        #expect(store.bots.first { $0.id == botId }?.desktopFolderIds == [folder.id], "the home folder is refused")

        // Taking the grant away takes it out of the desktop too.
        store.setBotFolder(botId, folderId: folder.id, granted: false)
        #expect(store.bots.first { $0.id == botId }?.desktopFolderIds == [])
        #expect(store.privateDesktopFolders(botId: botId).mounts.isEmpty)
    }
}
