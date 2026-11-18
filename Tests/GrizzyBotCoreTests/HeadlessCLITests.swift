import Foundation
import Testing
@testable import GrizzyBotCore

@Suite("Headless CLI")
struct HeadlessCLITests {
    private func inv(_ args: [String], env: [String: String] = ["GRIZZYBOT_TOKEN": "t"]) -> HeadlessCLI.Invocation? {
        if case .run(let i) = HeadlessCLI.parse(args, env: env) { return i }
        return nil
    }

    @Test("run joins the task and waits two minutes by default; send doesn't wait")
    func run() {
        let r = inv(["run", "Ada", "fix", "the", "bug", "--json"])
        #expect(r?.tool == "grizzybot_send_message")
        #expect(r?.arguments["text"] == "fix the bug")
        #expect(r?.arguments["wait_seconds"] == "120")
        #expect(r?.json == true)
        #expect(inv(["send", "Ada", "hi"])?.arguments["wait_seconds"] == "0")
        #expect(inv(["run", "Ada", "x", "--wait", "5"])?.arguments["wait_seconds"] == "5")
    }

    @Test("env and flags set port and token; bad input is a usage error")
    func options() {
        let i = inv(["list", "--port", "9000"], env: ["GRIZZYBOT_TOKEN": "env", "GRIZZYBOT_PORT": "1234"])
        #expect(i?.port == 9000)
        #expect(i?.token == "env")
        #expect(inv(["list"], env: ["GRIZZYBOT_PORT": "1234"])?.port == 1234)
        #expect(HeadlessCLI.parse(["status"]) == .error("status needs a bot"))
        #expect(HeadlessCLI.parse(["list", "--nope"]) == .error("Unknown option --nope"))
        #expect(HeadlessCLI.parse([]) == .help)
    }

    @Test("request body is a typed MCP call")
    func body() throws {
        let i = try #require(inv(["chat", "Ada", "--limit", "5"]))
        let obj = try #require(JSONSerialization.jsonObject(with: HeadlessCLI.requestBody(for: i)) as? [String: Any])
        #expect(obj["method"] as? String == "tools/call")
        let args = (obj["params"] as? [String: Any])?["arguments"] as? [String: Any]
        #expect(args?["limit"] as? Int == 5)
    }

    @Test("replies map to output and exit codes")
    func interpret() {
        func body(_ text: String, error: Bool) -> Data {
            try! JSONSerialization.data(withJSONObject: ["result": ["content": [["type": "text", "text": text]], "isError": error]])
        }
        #expect(HeadlessCLI.interpret(status: 200, body: body("hi", error: false), json: false) == ("hi", .ok))
        #expect(HeadlessCLI.interpret(status: 200, body: body("no bot", error: true), json: false).code == .failed)
        #expect(HeadlessCLI.interpret(status: 401, body: Data(), json: false).code == .unauthorized)
        #expect(HeadlessCLI.interpret(status: 200, body: body("hi", error: false), json: true).output.contains("\"text\" : \"hi\""))
    }
}
