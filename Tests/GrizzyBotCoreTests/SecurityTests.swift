import CryptoKit
import Foundation
import GrizzyBotCore
import Testing

@Suite("Security")
struct SecurityTests {
    @Test("PBKDF2 hash verifies and upgrades legacy SHA-256")
    func passwordHasher() {
        let password = "correct horse battery staple"
        let stored = PasswordHasher.hash(password)
        #expect(stored.hasPrefix("pbkdf2:"))
        #expect(PasswordHasher.verify(password, stored: stored))
        #expect(!PasswordHasher.verify("wrong", stored: stored))
        #expect(!PasswordHasher.needsUpgrade(stored))

        let legacy = SHA256.hash(data: Data(password.utf8))
            .map { String(format: "%02x", $0) }.joined()
        #expect(PasswordHasher.verify(password, stored: legacy))
        #expect(PasswordHasher.needsUpgrade(legacy))
    }

    @Test("ComputerHost normalizes legacy docker host")
    func computerHost() {
        #expect(ComputerHost.normalize("cloud") == .inAppBrowser)
        #expect(ComputerHost.normalize("in-app-browser") == .inAppBrowser)
        #expect(ComputerHost.normalize("this-mac") == .thisMac)
        #expect(ComputerHost.normalize("docker") == .inAppBrowser)
    }

    @Test("Workspace export strips secrets from JSON")
    func exportRedactsSecrets() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gb-sec-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let persistence = Persistence(root: dir)
        let userId = "user-1"
        var ws = UserWorkspace()
        ws.apiKey = "sk-test-secret-key"
        ws.connectionSecrets = ["box": "box-token"]
        ws.appConfig.sentryDSN = "https://example@sentry.io/1"
        persistence.saveWorkspace(ws, userId: userId)

        let loaded = persistence.loadWorkspaceMerged(userId: userId)
        #expect(loaded.apiKey == "sk-test-secret-key")

        let stripped = WorkspaceSecrets.from(workspace: loaded).stripped(from: loaded)
        let data = try persistence.encodeJSON(stripped)
        let json = String(decoding: data, as: UTF8.self)
        #expect(!json.contains("sk-test-secret-key"))
        #expect(!json.contains("box-token"))
        #expect(!json.contains("sentry.io"))
    }

    @Test("RoutineTickPlanner finds due routines")
    func routinePlanner() {
        let botId = "bot-1"
        var ws = UserWorkspace()
        var routine = Routine(
            id: "r1",
            botId: botId,
            name: "Daily",
            prompt: "hi",
            cron: "* * * * *"
        )
        routine.nextRunAt = Date(timeIntervalSinceNow: -10)
        ws.routines[botId] = [routine]
        let due = RoutineTickPlanner.dueRoutines(in: ws)
        #expect(due.count == 1)
        #expect(due[0].routineId == "r1")
    }

    @Test("workspace snapshots strip secrets from JSON on disk")
    @MainActor
    func snapshotRedactsSecrets() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gb-snap-sec-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let store = AppStore(dataDirectory: dir, delayScale: 0.01)
        guard let userId = store.session?.userId else {
            Issue.record("Expected bootstrapped session")
            return
        }
        store.saveModelSelection(provider: "openai", modelId: "gpt-4o", apiKey: "sk-snapshot-leak")
        store.connect(slug: "gmail", token: "oauth-token")
        await store.waitForPluginTasks()

        let meta = store.saveWorkspaceSnapshot(name: "Sensitive")
        #expect(meta != nil)

        let userDir = AccountLayout.userDirectory(global: dir, userId: userId)
        let snapDir = userDir.appendingPathComponent("snapshots", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: snapDir, includingPropertiesForKeys: nil)
        #expect(!files.isEmpty)
        let raw = try String(contentsOf: files[0], encoding: .utf8)
        #expect(!raw.contains("sk-snapshot-leak"))
        #expect(!raw.contains("oauth-token"))

        store.apiKey = nil
        #expect(store.restoreWorkspaceSnapshot(meta!.id))
        #expect(store.apiKey == "sk-snapshot-leak")
    }

    @Test("run log dump redacts secrets")
    func runLogScrub() {
        let line = RunLogLine(botId: "b1", kind: "tool", text: "token=abc123 /Users/me/secret")
        let dump = RunLog.dump([line])
        #expect(!dump.contains("abc123"))
        #expect(!dump.contains("/Users/me"))
        #expect(dump.contains("[redacted]"))
    }

    @Test("ComputerMode selectable cases are honest hosts")
    func computerModeSelectable() {
        #expect(ComputerMode.selectableCases.contains(.inAppBrowser))
        #expect(ComputerMode.selectableCases.contains(.thisMac))
        #expect(ComputerMode.inAppBrowser.label == "In-app browser")
    }

    @Test("password hashes live in Keychain not users.json")
    @MainActor
    func credentialsInKeychain() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gb-cred-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = AppStore(dataDirectory: dir, delayScale: 0.01)
        store.signOut()
        #expect(store.signUp(name: "Alice", email: "alice-sec@test.com", password: "password1") == nil)
        guard let userId = store.session?.userId else {
            Issue.record("Expected session after sign-up")
            return
        }
        let usersJSON = try String(contentsOf: dir.appendingPathComponent("users.json"), encoding: .utf8)
        #expect(!usersJSON.contains("pbkdf2:"))
        #expect(AccountCredentialStore.verify(userId: userId, password: "password1"))
        #expect(!AccountCredentialStore.verify(userId: userId, password: "wrong"))
    }

    @Test("multi-user workspaces use separate data directories")
    @MainActor
    func multiUserIsolation() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gb-multi-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = AppStore(dataDirectory: dir, delayScale: 0.01)
        store.signOut()
        #expect(store.signUp(name: "Alice", email: "alice-multi@test.com", password: "password1") == nil)
        let bot = store.createBot(name: "AliceBot", title: "helper")
        let aliceId = store.session!.userId
        store.signOut()

        #expect(store.signUp(name: "Bob", email: "bob-multi@test.com", password: "password2") == nil)
        #expect(store.bots.isEmpty)
        let bobId = store.session!.userId
        #expect(bobId != aliceId)
        store.signOut()

        #expect(store.signIn(email: "alice-multi@test.com", password: "password1") == nil)
        #expect(store.bots.contains(where: { $0.id == bot.id }))

        let aliceDir = AccountLayout.userDirectory(global: dir, userId: aliceId)
        let bobDir = AccountLayout.userDirectory(global: dir, userId: bobId)
        #expect(FileManager.default.fileExists(atPath: aliceDir.appendingPathComponent("workspace.json").path))
        #expect(FileManager.default.fileExists(atPath: bobDir.appendingPathComponent("workspace.json").path))
    }
}
