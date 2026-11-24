import Foundation
import Testing
@testable import GrizzyBotCore

private let frame = ComputerScreenFrame.square(1280, 900)

@Suite("Xdotool commands")
struct XdotoolCommandsTests {
    private func args(_ kind: ComputerInput.Kind, x: Double = 0, y: Double = 0, text: String = "") -> [String]? {
        XdotoolCommands.arguments(for: ComputerInput(kind: kind, x: x, y: y, text: text), frame: frame)
    }

    @Test("clicks map to buttons and repeats")
    func clicks() {
        #expect(args(.click, x: 300, y: 200) == ["xdotool", "mousemove", "--sync", "300", "200", "click", "1"])
        #expect(args(.rightClick, x: 5, y: 6) == ["xdotool", "mousemove", "--sync", "5", "6", "click", "3"])
        #expect(args(.doubleClick, x: 5, y: 6) == ["xdotool", "mousemove", "--sync", "5", "6", "click", "--repeat", "2", "--delay", "80", "1"])
    }

    @Test("a point off the screen is kept on it; a non-number is refused")
    func clamping() {
        #expect(args(.click, x: 99_999, y: -40) == ["xdotool", "mousemove", "--sync", "1279", "0", "click", "1"])
        #expect(args(.click, x: .nan, y: 1) == nil)
        #expect(args(.click, x: .infinity, y: 1) == nil)
    }

    @Test("scroll turns pixels into wheel clicks, down on 5 and up on 4")
    func scroll() {
        #expect(args(.scroll, x: 10, y: 10, text: "500")?.suffix(6) == ["click", "--repeat", "10", "--delay", "30", "5"])
        #expect(args(.scroll, x: 10, y: 10, text: "-100")?.last == "4")
        #expect(args(.scroll, x: 10, y: 10, text: "")?.last == "5")
        #expect(args(.scroll, x: 10, y: 10, text: "1")?.contains("1") == true)
        #expect(args(.scroll, x: 10, y: 10, text: "999999")?.contains("40") == true)
        #expect(args(.scroll, x: 10, y: 10, text: "0") == nil)
    }

    @Test("typed text comes after -- so it can never be read as an option")
    func typing() {
        let list = args(.type, text: "--help; rm -rf /")
        #expect(list == ["xdotool", "type", "--clearmodifiers", "--delay", "12", "--", "--help; rm -rf /"])
        #expect(args(.type, text: "") == nil)
    }

    @Test("key chords become xdotool chords, with cmd meaning ctrl on Linux")
    func keys() {
        #expect(XdotoolCommands.keyChord("cmd+c") == "ctrl+c")
        #expect(XdotoolCommands.keyChord("Shift+Enter") == "shift+Return")
        #expect(XdotoolCommands.keyChord("ctrl+shift+t") == "ctrl+shift+t")
        #expect(XdotoolCommands.keyChord("escape") == "Escape")
        #expect(XdotoolCommands.keyChord("F5") == "F5")
        #expect(XdotoolCommands.keyChord("pagedown") == "Next")
        #expect(XdotoolCommands.keyChord("backspace") == "BackSpace")
        #expect(XdotoolCommands.keyChord("delete") == "Delete")
        #expect(XdotoolCommands.keyChord("ctrl++") == "ctrl+plus")
        #expect(XdotoolCommands.keyChord("+") == "plus")
        #expect(XdotoolCommands.keyChord("alt+left") == "alt+Left")
    }

    @Test("anything that is not a known key is refused, including option-shaped text")
    func badKeys() {
        for bad in ["", "   ", "--help", "-d", "ctrl+", "+c", "banana", "ctrl+banana", "foo+c", "F13", "a+b+c+d+e+f", "ctrl+;", "$(id)"] {
            #expect(XdotoolCommands.keyChord(bad) == nil, "\(bad) should be refused")
        }
    }

    @Test("open accepts only http and https pages")
    func open() {
        #expect(args(.open, text: "https://example.com/a?b=1") == ["firefox", "https://example.com/a?b=1"])
        #expect(args(.open, text: " http://localhost:3000 ") == ["firefox", "http://localhost:3000"])
        for bad in ["file:///etc/passwd", "javascript:alert(1)", "about:config", "--new-window", "example.com", "https://", "ftp://x.com", ""] {
            #expect(args(.open, text: bad) == nil, "\(bad) should be refused")
        }
    }

    @Test("the screenshot is one JPEG of the display on stdout")
    func screenshot() {
        #expect(XdotoolCommands.screenshot.contains("x11grab") && XdotoolCommands.screenshot.contains(":1"))
        #expect(XdotoolCommands.screenshot.suffix(2) == ["mjpeg", "-"])
    }

    @Test("podman exec runs as the desktop's own user on its display, with the command after the container")
    func execArgs() {
        let list = PodmanDesktop.execArguments(containerName: "c", command: ["xdotool", "key", "a"])
        #expect(list == ["exec", "-u", "1000", "-e", "DISPLAY=:1", "c", "xdotool", "key", "a"])
        #expect(PodmanDesktop.execArguments(containerName: "c", command: ["firefox"], detached: true).prefix(2) == ["exec", "-d"])
    }
}

/// A fake Podman whose containers answer `exec` the way a real desktop does.
private final class FakeDesktop: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var execs: [[String]] = []
    var imagePresent = true
    var machineUp = true
    var running = false
    var jpeg = DesktopImage.render(text: "x")
    var screenshotFails = false
    var xdotoolFails = false
    var staleOnce = false

    let botId: String
    init(botId: String) { self.botId = botId }

    private var inspect: String {
        let target = PodmanDesktopTarget(botId: botId, root: URL(fileURLWithPath: "/tmp/gb-fake"))
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

    var runner: PodmanCommandRunner { { [self] _, args, _ in handle(args) } }

    private func handle(_ args: [String]) -> PodmanCommandResult {
        lock.withLock {
            switch args.first ?? "" {
            case "info": return PodmanCommandResult(exitCode: machineUp ? 0 : 125)
            case "image": return PodmanCommandResult(exitCode: imagePresent ? 0 : 1)
            case "container": return PodmanCommandResult(stdout: inspect)
            case "create": return PodmanCommandResult()
            case "start": running = true; return PodmanCommandResult()
            case "exec":
                execs.append(args)
                if staleOnce { staleOnce = false; running = false; return PodmanCommandResult(stderr: "Error: no such container", exitCode: 125) }
                if args.contains("ffmpeg") {
                    return screenshotFails ? PodmanCommandResult(stderr: "boom", exitCode: 1) : PodmanCommandResult(stdoutData: jpeg)
                }
                if xdotoolFails && !args.contains("getdisplaygeometry") { return PodmanCommandResult(stderr: "Invalid key", exitCode: 1) }
                return PodmanCommandResult(stdout: "1280 900\n")
            default: return PodmanCommandResult()
            }
        }
    }

    func commands() -> [[String]] { lock.withLock { execs.map { Array($0.drop(while: { $0 != "grizzybot-desktop" && !$0.hasPrefix("grizzybot-desktop-") }).dropFirst()) } } }
}

@Suite("Container computer runtime")
struct ContainerComputerRuntimeTests {
    private func make(_ fake: FakeDesktop) -> ContainerComputerRuntime {
        let desktop = PodmanDesktop(root: URL(fileURLWithPath: "/tmp/gb-fake"), runner: fake.runner, locate: { "/opt/homebrew/bin/podman" })
        return ContainerComputerRuntime(desktop: desktop, readyAttempts: 2, readyInterval: 0)
    }

    @Test("a screenshot keeps the JPEG bytes and takes its size from the picture")
    func screenshot() async throws {
        let fake = FakeDesktop(botId: "b")
        let runtime = make(fake)
        let snap = try #require(await runtime.snapshot(botId: "b"))
        #expect(snap.jpeg == fake.jpeg)
        #expect(snap.width == 1024 && snap.height == 640)
        #expect(snap.frame == ComputerScreenFrame.square(1024, 640))
        #expect(await runtime.lastFrame(botId: "b") == snap.frame)
        #expect(await runtime.unavailableReason(botId: "b") == nil)
    }

    @Test("the first use starts a stopped desktop and waits for its screen")
    func startsOnFirstUse() async {
        let fake = FakeDesktop(botId: "b")
        let runtime = make(fake)
        _ = await runtime.snapshot(botId: "b")
        #expect(fake.running)
        #expect(fake.commands().first?.first == "xdotool")
    }

    @Test("a click is mapped against the screenshot's size")
    func clickUsesFrame() async {
        let fake = FakeDesktop(botId: "b")
        let runtime = make(fake)
        let result = await runtime.send(ComputerInput(kind: .click, x: 5000, y: 100), botId: "b")
        #expect(result.ok && result.summary == "Clicked (5000, 100)")
        let click = fake.commands().last
        #expect(click == ["xdotool", "mousemove", "--sync", "1023", "100", "click", "1"])
    }

    @Test("open runs detached and is remembered")
    func open() async {
        let fake = FakeDesktop(botId: "b")
        let runtime = make(fake)
        let result = await runtime.send(ComputerInput(kind: .open, text: "https://example.com"), botId: "b")
        #expect(result.ok)
        #expect(await runtime.currentURL(botId: "b") == "https://example.com")
        #expect(fake.commands().last == ["firefox", "https://example.com"])
    }

    @Test("a refused input says why and runs nothing")
    func refused() async {
        let fake = FakeDesktop(botId: "b")
        let runtime = make(fake)
        let key = await runtime.send(ComputerInput(kind: .key, text: "banana"), botId: "b")
        #expect(!key.ok && key.summary.contains("not a key"))
        let page = await runtime.send(ComputerInput(kind: .open, text: "file:///etc/passwd"), botId: "b")
        #expect(!page.ok && page.summary.contains("http"))
        #expect(!fake.commands().contains { $0.first == "firefox" })
    }

    @Test("a failing command reports its own message")
    func commandFails() async {
        let fake = FakeDesktop(botId: "b")
        let runtime = make(fake)
        _ = await runtime.snapshot(botId: "b")
        fake.xdotoolFails = true
        let result = await runtime.send(ComputerInput(kind: .type, text: "hi"), botId: "b")
        #expect(!result.ok && result.summary.contains("Invalid key"))
    }

    @Test("a missing image is reported, never built silently")
    func imageMissing() async {
        let fake = FakeDesktop(botId: "b")
        fake.imagePresent = false
        let runtime = make(fake)
        #expect(await runtime.snapshot(botId: "b") == nil)
        #expect(await runtime.unavailableReason(botId: "b")?.contains("has not been built") == true)
        let result = await runtime.send(ComputerInput(kind: .click, x: 1, y: 1), botId: "b")
        #expect(!result.ok && result.summary.contains("has not been built"))
    }

    @Test("a stopped Podman machine is reported plainly")
    func machineDown() async {
        let fake = FakeDesktop(botId: "b")
        fake.machineUp = false
        let runtime = make(fake)
        #expect(await runtime.snapshot(botId: "b") == nil)
        #expect(await runtime.unavailableReason(botId: "b")?.contains("podman machine start") == true)
    }

    @Test("a failed capture is explained and leaves no stale reason after the next good one")
    func captureFails() async {
        let fake = FakeDesktop(botId: "b")
        let runtime = make(fake)
        fake.screenshotFails = true
        #expect(await runtime.snapshot(botId: "b") == nil)
        #expect(await runtime.unavailableReason(botId: "b")?.contains("could not capture") == true)
        fake.screenshotFails = false
        #expect(await runtime.snapshot(botId: "b") != nil)
        #expect(await runtime.unavailableReason(botId: "b") == nil)
    }

    @Test("a container that stopped under a command is restarted and the command retried once")
    func restartsStoppedContainer() async {
        let fake = FakeDesktop(botId: "b")
        let runtime = make(fake)
        _ = await runtime.snapshot(botId: "b")
        fake.staleOnce = true
        let snap = await runtime.snapshot(botId: "b")
        #expect(snap != nil)
        #expect(fake.running)
    }

    @Test("an unreadable picture is not a screenshot")
    func notAJpeg() async {
        let fake = FakeDesktop(botId: "b")
        fake.jpeg = Data("not an image".utf8)
        #expect(await make(fake).snapshot(botId: "b") == nil)
    }
}

@Suite("Routing computer runtime")
struct RoutingComputerRuntimeTests {
    private actor Recorder: ComputerRuntime {
        let name: String
        private(set) var calls: [String] = []
        init(_ name: String) { self.name = name }
        func attach(botId: String, homeURL: URL) async { calls.append("attach:\(botId)") }
        func snapshot(botId: String) async -> ComputerSnapshot? { calls.append("snapshot:\(botId)"); return nil }
        func send(_ input: ComputerInput, botId: String) async -> ComputerActionResult {
            calls.append("send:\(botId)"); return ComputerActionResult(summary: name)
        }
        func currentURL(botId: String) async -> String { name }
        func unavailableReason(botId: String) async -> String? { "\(name) says no" }
    }

    @Test("a Private desktop bot goes to the container runtime and every other bot to the app's")
    func routes() async {
        let app = Recorder("app"), desktop = Recorder("desktop")
        let router = RoutingComputerRuntime(primary: app, privateDesktop: desktop)
        await router.setMode(botId: "p", mode: .privateDesktop)
        await router.setMode(botId: "m", mode: .thisMac)

        #expect(await router.send(ComputerInput(kind: .click), botId: "p").summary == "desktop")
        #expect(await router.send(ComputerInput(kind: .click), botId: "m").summary == "app")
        #expect(await router.send(ComputerInput(kind: .click), botId: "never-announced").summary == "app")
        #expect(await router.unavailableReason(botId: "p") == "desktop says no")
        #expect(await router.currentURL(botId: "m") == "app")
        #expect(await desktop.calls == ["send:p"])
    }

    @Test("changing a bot's mode moves it between runtimes")
    func switching() async {
        let app = Recorder("app"), desktop = Recorder("desktop")
        let router = RoutingComputerRuntime(primary: app, privateDesktop: desktop)
        await router.setMode(botId: "b", mode: .privateDesktop)
        #expect(await router.currentURL(botId: "b") == "desktop")
        await router.setMode(botId: "b", mode: .inAppBrowser)
        #expect(await router.currentURL(botId: "b") == "app")
    }
}
