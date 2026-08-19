import Foundation
import GrizzyBotCore
import Testing

@Suite("ScriptedRuntime")
struct ScriptedRuntimeTests {
    @Test("sign-in resume")
    func signInResume() {
        let reply = ScriptedRuntime.reply(to: "completed sign-in")
        #expect(reply.text.contains("signed in"))
        #expect(reply.action == nil)
    }

    @Test("takeover on sign in")
    func takeover() {
        let reply = ScriptedRuntime.reply(to: "please sign in")
        #expect(reply.action == .takeover(reason: "Sign in to continue. Protected input stays off the thread."))
    }

    @Test("spawn named bot")
    func spawnNamed() {
        let reply = ScriptedRuntime.reply(to: "spawn a bot named Scout")
        #expect(reply.action == .spawnBot(name: "Scout", title: "Scout specialist"))
    }

    @Test("spawn defaults to Helper")
    func spawnDefault() {
        let reply = ScriptedRuntime.reply(to: "spawn a bot")
        #expect(reply.action == .spawnBot(name: "Helper", title: "Helper specialist"))
    }

    @Test("delete bot by name")
    func deleteBot() {
        let reply = ScriptedRuntime.reply(to: "delete the bot named Scout")
        #expect(reply.action == .deleteBot(name: "Scout"))
    }

    @Test("subagent")
    func subagent() {
        let reply = ScriptedRuntime.reply(to: "use a subagent for this")
        guard case .subagent(let task) = reply.action else {
            Issue.record("expected subagent action")
            return
        }
        #expect(task.contains("subagent"))
    }

    @Test("crm destination write")
    func crm() {
        let reply = ScriptedRuntime.reply(to: "update the crm")
        #expect(reply.action == .destinationWrite(title: "GrizzyBot result", body: "update the crm"))
    }

    @Test("write a note that says Hello")
    func writeNote() {
        let reply = ScriptedRuntime.reply(to: "write a note that says Hello.")
        #expect(reply.action == .writeFile(path: "notes/result.txt", content: "Hello\n"))
    }

    @Test("remember")
    func remember() {
        let reply = ScriptedRuntime.reply(to: "remember my favorite color is blue")
        #expect(reply.action == .remember(text: "remember my favorite color is blue"))
    }

    @Test("default reply")
    func defaultReply() {
        let reply = ScriptedRuntime.reply(to: "please research the market")
        #expect(reply.text.contains("on it."))
        #expect(ScriptedRuntime.subagentResult(for: "please research the market").contains("done. i handled:"))
    }

    @Test("web search")
    func webSearch() {
        let reply = ScriptedRuntime.reply(to: "search the web for swift concurrency")
        #expect(reply.action == .webSearch(query: "swift concurrency"))
    }

    @Test("list files")
    func listFiles() {
        let reply = ScriptedRuntime.reply(to: "list files in my home")
        #expect(reply.action == .listFiles(directory: ""))
    }

    @Test("read file")
    func readFile() {
        let reply = ScriptedRuntime.reply(to: "read file notes/result.txt")
        #expect(reply.action == .readFile(path: "notes/result.txt"))
    }

    @Test("move file")
    func moveFile() {
        let reply = ScriptedRuntime.reply(to: "move file notes/a.txt to notes/b.txt")
        #expect(reply.action == .moveFile(from: "notes/a.txt", to: "notes/b.txt"))
    }

    @Test("delete file")
    func deleteFile() {
        let reply = ScriptedRuntime.reply(to: "delete file notes/result.txt")
        #expect(reply.action == .deleteFile(path: "notes/result.txt"))
    }
}
