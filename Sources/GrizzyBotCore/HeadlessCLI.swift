import Foundation

/// The logic behind the `grizzybot` command-line tool: argument parsing, the MCP calls it makes to a
/// running GrizzyBot (control plane on loopback), and how replies map to output and exit codes.
/// Kept here, away from `main.swift`, so it can be tested.
public enum HeadlessCLI {
    public enum ExitCode: Int32, Sendable {
        case ok = 0, failed = 1, usage = 2, unreachable = 3, unauthorized = 4
    }

    public struct Invocation: Equatable, Sendable {
        public var tool: String            // MCP tool name, or "" for `tools`
        public var arguments: [String: String]
        public var json: Bool
        public var port: Int
        public var token: String
        public var listTools: Bool = false
    }

    public enum ParseResult: Equatable, Sendable {
        case run(Invocation)
        case help
        case error(String)
    }

    public static let usage = """
    grizzybot — drive a running GrizzyBot from the terminal

    Usage:
      grizzybot list                               List the bots
      grizzybot status <bot>                       What a bot is doing
      grizzybot chat <bot> [--limit N]             Recent messages in its main chat
      grizzybot search <words…> [--bot <bot>]      Search earlier chats
      grizzybot run <bot> "<task>" [--wait SECS]   Give a bot a job and wait for the reply (default 120)
      grizzybot stop <bot>                         Stop its current run
      grizzybot model <bot> <provider> <model>     Switch its model
      grizzybot tools                              What the control plane offers

    Options:
      --json          Print the raw result as JSON
      --port N        Control-plane port (default 8801, or GRIZZYBOT_PORT)
      --token T       Bearer token (default: GRIZZYBOT_TOKEN)

    Turn the control plane on in GrizzyBot's settings first; the token is shown there.
    Exit codes: 0 ok, 1 the app reported an error, 2 bad usage, 3 app not reachable, 4 token rejected.
    Approvals are answered in the app, never here.
    """

    public static func parse(_ args: [String], env: [String: String] = [:]) -> ParseResult {
        var positional: [String] = []
        var json = false
        var port = Int(env["GRIZZYBOT_PORT"] ?? "") ?? ControlPlaneServer.defaultPort
        var token = env["GRIZZYBOT_TOKEN"] ?? ""
        var options: [String: String] = [:]
        var i = 0
        while i < args.count {
            let a = args[i]
            func value() -> String? { i += 1; return i < args.count ? args[i] : nil }
            switch a {
            case "-h", "--help": return .help
            case "--json": json = true
            case "--port":
                guard let v = value(), let n = Int(v), (1...65535).contains(n) else { return .error("--port needs a number") }
                port = n
            case "--token":
                guard let v = value() else { return .error("--token needs a value") }
                token = v
            case "--wait", "--limit", "--bot":
                guard let v = value() else { return .error("\(a) needs a value") }
                options[String(a.dropFirst(2))] = v
            default:
                if a.hasPrefix("--") { return .error("Unknown option \(a)") }
                positional.append(a)
            }
            i += 1
        }
        guard let verb = positional.first else { return .help }
        let rest = Array(positional.dropFirst())
        func make(_ tool: String, _ a: [String: String]) -> ParseResult {
            .run(Invocation(tool: tool, arguments: a, json: json, port: port, token: token))
        }
        switch verb {
        case "list":
            return make("grizzybot_list_bots", [:])
        case "status":
            guard rest.count == 1 else { return .error("status needs a bot") }
            return make("grizzybot_bot_status", ["bot": rest[0]])
        case "chat":
            guard rest.count == 1 else { return .error("chat needs a bot") }
            var a = ["bot": rest[0]]
            if let l = options["limit"] { a["limit"] = l }
            return make("grizzybot_read_chat", a)
        case "search":
            guard !rest.isEmpty else { return .error("search needs some words") }
            var a = ["query": rest.joined(separator: " ")]
            if let b = options["bot"] { a["bot"] = b }
            return make("grizzybot_search_chats", a)
        case "run", "send":
            guard rest.count >= 2 else { return .error("run needs a bot and a task") }
            let wait = verb == "send" ? (options["wait"] ?? "0") : (options["wait"] ?? "120")
            return make("grizzybot_send_message", ["bot": rest[0], "text": rest.dropFirst().joined(separator: " "), "wait_seconds": wait])
        case "stop":
            guard rest.count == 1 else { return .error("stop needs a bot") }
            return make("grizzybot_interrupt", ["bot": rest[0]])
        case "model":
            guard rest.count == 3 else { return .error("model needs a bot, a provider and a model") }
            return make("grizzybot_set_model", ["bot": rest[0], "provider": rest[1], "model": rest[2]])
        case "tools":
            var inv = Invocation(tool: "", arguments: [:], json: json, port: port, token: token)
            inv.listTools = true
            return .run(inv)
        default:
            return .error("Unknown command “\(verb)”")
        }
    }

    /// The JSON-RPC body to POST to `/mcp`.
    public static func requestBody(for inv: Invocation) -> Data {
        var body: [String: Any] = ["jsonrpc": "2.0", "id": 1]
        if inv.listTools {
            body["method"] = "tools/list"
        } else {
            body["method"] = "tools/call"
            var args: [String: Any] = inv.arguments
            for key in ["wait_seconds", "limit"] { if let s = inv.arguments[key], let n = Int(s) { args[key] = n } }
            body["params"] = ["name": inv.tool, "arguments": args]
        }
        return (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
    }

    /// Turns an HTTP status and body into what to print and how to exit.
    public static func interpret(status: Int, body: Data, json: Bool) -> (output: String, code: ExitCode) {
        switch status {
        case 401, 403: return ("The token was rejected. Copy it again from GrizzyBot's control-plane settings.", .unauthorized)
        case 200: break
        default: return ("GrizzyBot answered HTTP \(status).", .failed)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return ("Unreadable reply from GrizzyBot.", .failed)
        }
        if let err = obj["error"] as? [String: Any] {
            return (err["message"] as? String ?? "Error", .failed)
        }
        let result = obj["result"] as? [String: Any] ?? [:]
        if let tools = result["tools"] as? [[String: Any]] {
            if json { return (pretty(tools), .ok) }
            return (tools.map { "\($0["name"] as? String ?? "?") — \($0["description"] as? String ?? "")" }.joined(separator: "\n"), .ok)
        }
        let isError = result["isError"] as? Bool ?? false
        let text = (result["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
        if json { return (pretty(["ok": !isError, "text": text]), isError ? .failed : .ok) }
        return (text, isError ? .failed : .ok)
    }

    private static func pretty(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let d = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: d, encoding: .utf8) else { return "" }
        return s
    }
}
