import Foundation

// MARK: - Errors

public enum McpError: Error, LocalizedError, Sendable {
    case invalidConfiguration(String)
    case launchFailed(String)
    case transport(String)
    case protocolError(String)
    case remote(code: Int, message: String)
    case timeout
    case noTools
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let s): return s
        case .launchFailed(let s): return "Failed to launch MCP server: \(s)"
        case .transport(let s): return s
        case .protocolError(let s): return s
        case .remote(let code, let message): return "MCP error \(code): \(message)"
        case .timeout: return "MCP request timed out"
        case .noTools: return "MCP server exposed no tools"
        case .cancelled: return "MCP call cancelled"
        }
    }
}

// MARK: - Wire types

public struct McpToolInfo: Sendable, Hashable {
    public var name: String
    public var description: String
    public var inputSchema: [String: AnyCodableMCP]

    public init(name: String, description: String = "", inputSchema: [String: AnyCodableMCP] = [:]) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

public struct McpCallResult: Sendable {
    public var toolName: String
    public var text: String
    public var isError: Bool
    public var listedTools: [McpToolInfo]

    public init(toolName: String, text: String, isError: Bool = false, listedTools: [McpToolInfo] = []) {
        self.toolName = toolName
        self.text = text
        self.isError = isError
        self.listedTools = listedTools
    }
}

/// Minimal JSON-compatible box for MCP schemas/arguments.
public struct AnyCodableMCP: Codable, @unchecked Sendable, Hashable {
    public let value: Any

    public init(_ value: Any) { self.value = value }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { value = NSNull(); return }
        if let b = try? c.decode(Bool.self) { value = b; return }
        if let i = try? c.decode(Int.self) { value = i; return }
        if let d = try? c.decode(Double.self) { value = d; return }
        if let s = try? c.decode(String.self) { value = s; return }
        if let a = try? c.decode([AnyCodableMCP].self) { value = a.map(\.value); return }
        if let o = try? c.decode([String: AnyCodableMCP].self) {
            value = o.mapValues(\.value)
            return
        }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case is NSNull: try c.encodeNil()
        case let b as Bool: try c.encode(b)
        case let i as Int: try c.encode(i)
        case let d as Double: try c.encode(d)
        case let s as String: try c.encode(s)
        case let a as [Any]: try c.encode(a.map(AnyCodableMCP.init))
        case let o as [String: Any]: try c.encode(o.mapValues(AnyCodableMCP.init))
        default:
            throw EncodingError.invalidValue(value, .init(codingPath: encoder.codingPath, debugDescription: "Unsupported"))
        }
    }

    public static func == (lhs: AnyCodableMCP, rhs: AnyCodableMCP) -> Bool {
        String(describing: lhs.value) == String(describing: rhs.value)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(String(describing: value))
    }
}

// MARK: - JSON-RPC

struct McpJSONRPCRequest: Encodable {
    var jsonrpc: String = "2.0"
    var id: Int
    var method: String
    var params: [String: AnyCodableMCP]?
}

struct McpJSONRPCNotification: Encodable {
    var jsonrpc: String = "2.0"
    var method: String
    var params: [String: AnyCodableMCP]?
}

struct McpJSONRPCResponse: Decodable {
    var jsonrpc: String?
    var id: Int?
    var result: AnyCodableMCP?
    var error: McpJSONRPCErrorBody?
}

struct McpJSONRPCErrorBody: Decodable {
    var code: Int
    var message: String
}

struct SendableJSON: @unchecked Sendable {
    let value: Any
    init(_ value: Any) { self.value = value }
}

// MARK: - Transport protocol

protocol McpSession: AnyObject {
    func sendRequest(method: String, params: [String: Any]?) async throws -> Any
    func sendNotification(method: String, params: [String: Any]?) async throws
    func close() async
}

// MARK: - Client

public enum McpClient {
    public static let protocolVersion = "2025-11-25"
    public static let clientName = "GrizzyBot"
    public static let clientVersion = "1.0.0"

    /// Connect, initialize, list tools, call the best matching tool, return text.
    public static func invoke(
        server: McpServer,
        prompt: String,
        timeout: TimeInterval = 45
    ) async throws -> McpCallResult {
        let session = try await openSession(server: server, timeout: timeout)
        do {
            let result = try await runToolFlow(session: session, prompt: prompt)
            await session.close()
            return result
        } catch {
            await session.close()
            throw error
        }
    }

    /// Connect, initialize, and call a named tool with explicit arguments.
    public static func call(
        server: McpServer,
        toolName: String,
        arguments: [String: JSONValue] = [:],
        timeout: TimeInterval = 45
    ) async throws -> McpCallResult {
        let session = try await openSession(server: server, timeout: timeout)
        do {
            _ = try await initialize(session: session)
            let anyArgs = arguments.mapValues(\.any)
            let (text, isError) = try await toolsCall(session: session, name: toolName, arguments: anyArgs)
            await session.close()
            return McpCallResult(toolName: toolName, text: text, isError: isError)
        } catch {
            await session.close()
            throw error
        }
    }

    /// List tools only (useful for diagnostics).
    public static func listTools(server: McpServer, timeout: TimeInterval = 30) async throws -> [McpToolInfo] {
        let session = try await openSession(server: server, timeout: timeout)
        do {
            _ = try await initialize(session: session)
            let tools = try await toolsList(session: session)
            await session.close()
            return tools
        } catch {
            await session.close()
            throw error
        }
    }

    static func openSession(server: McpServer, timeout: TimeInterval) async throws -> any McpSession {
        switch server.transport {
        case .stdio:
            return try await McpStdioSession.open(server: server, timeout: timeout)
        case .http:
            return try await McpHTTPSession.open(server: server, mode: .streamable, timeout: timeout)
        case .sse:
            return try await McpHTTPSession.open(server: server, mode: .legacySSE, timeout: timeout)
        }
    }

    static func runToolFlow(session: any McpSession, prompt: String) async throws -> McpCallResult {
        _ = try await initialize(session: session)
        let tools = try await toolsList(session: session)
        guard !tools.isEmpty else { throw McpError.noTools }
        let tool = selectTool(from: tools, prompt: prompt)
        let args = buildArguments(for: tool, prompt: prompt)
        let (text, isError) = try await toolsCall(session: session, name: tool.name, arguments: args)
        return McpCallResult(toolName: tool.name, text: text, isError: isError, listedTools: tools)
    }

    static func initialize(session: any McpSession) async throws -> [String: Any] {
        let params: [String: Any] = [
            "protocolVersion": protocolVersion,
            "capabilities": [String: Any](),
            "clientInfo": [
                "name": clientName,
                "version": clientVersion,
            ],
        ]
        let result = try await session.sendRequest(method: "initialize", params: params)
        try await session.sendNotification(method: "notifications/initialized", params: nil)
        return (result as? [String: Any]) ?? [:]
    }

    static func toolsList(session: any McpSession) async throws -> [McpToolInfo] {
        let raw = try await session.sendRequest(method: "tools/list", params: [:])
        let obj = raw as? [String: Any] ?? [:]
        let list = obj["tools"] as? [[String: Any]] ?? []
        return list.compactMap { item in
            guard let name = item["name"] as? String, !name.isEmpty else { return nil }
            let description = item["description"] as? String ?? ""
            let schema = (item["inputSchema"] as? [String: Any]) ?? [:]
            return McpToolInfo(
                name: name,
                description: description,
                inputSchema: schema.mapValues(AnyCodableMCP.init)
            )
        }
    }

    static func toolsCall(
        session: any McpSession,
        name: String,
        arguments: [String: Any]
    ) async throws -> (text: String, isError: Bool) {
        let raw = try await session.sendRequest(
            method: "tools/call",
            params: [
                "name": name,
                "arguments": arguments,
            ]
        )
        let obj = raw as? [String: Any] ?? [:]
        let isError = (obj["isError"] as? Bool) ?? false
        let content = obj["content"] as? [[String: Any]] ?? []
        let texts = content.compactMap { block -> String? in
            if let t = block["text"] as? String { return t }
            if let data = block["data"] as? String { return data }
            return nil
        }
        if !texts.isEmpty {
            return (texts.joined(separator: "\n\n"), isError)
        }
        if let structured = obj["structuredContent"] {
            return (stringifyJSON(structured), isError)
        }
        return (stringifyJSON(obj), isError)
    }

    public static func selectTool(from tools: [McpToolInfo], prompt: String) -> McpToolInfo {
        let lower = prompt.lowercased()
        if let exact = tools.first(where: { lower.contains($0.name.lowercased()) }) {
            return exact
        }
        // Prefer common names when prompt is generic.
        let preferred = ["search", "query", "run", "execute", "call", "echo", "write", "read"]
        for name in preferred {
            if let match = tools.first(where: { $0.name.lowercased().contains(name) }) {
                return match
            }
        }
        return tools[0]
    }

    public static func buildArguments(for tool: McpToolInfo, prompt: String) -> [String: Any] {
        let schema = tool.inputSchema.mapValues(\.value)
        let properties = (schema["properties"] as? [String: Any]) ?? [:]
        let required = (schema["required"] as? [String]) ?? []

        if properties.isEmpty {
            return ["prompt": prompt]
        }

        var args: [String: Any] = [:]
        let preferredKeys = [
            "prompt", "query", "text", "input", "message", "content", "q",
            "path", "expression", "question", "ask", "command",
        ]

        if let key = preferredKeys.first(where: { properties[$0] != nil }) {
            args[key] = prompt
        } else if let firstRequired = required.first, properties[firstRequired] != nil {
            args[firstRequired] = prompt
        } else if let firstKey = properties.keys.sorted().first {
            args[firstKey] = prompt
        }

        // Fill remaining required string-ish fields with empty / prompt as needed.
        for key in required where args[key] == nil {
            if let prop = properties[key] as? [String: Any],
               (prop["type"] as? String) == "string" {
                args[key] = prompt
            }
        }
        return args
    }

    static func stringifyJSON(_ value: Any) -> String {
        if let s = value as? String { return s }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: data, encoding: .utf8)
        else {
            return String(describing: value)
        }
        return s
    }

    static func encodeJSONRPC(_ value: Encodable) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return try enc.encode(value)
    }

    static func decodeJSONObject(_ data: Data) throws -> [String: Any] {
        let obj = try JSONSerialization.jsonObject(with: data)
        guard let dict = obj as? [String: Any] else {
            throw McpError.protocolError("Expected JSON object")
        }
        return dict
    }

    public static func parseSSEDataEvents(_ text: String) -> [Data] {
        var events: [Data] = []
        var dataLines: [String] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if line.isEmpty {
                if !dataLines.isEmpty {
                    let joined = dataLines.joined(separator: "\n")
                    if let data = joined.data(using: .utf8) {
                        events.append(data)
                    }
                    dataLines = []
                }
                continue
            }
            if line.hasPrefix(":") { continue }
            if line.hasPrefix("data:") {
                var value = String(line.dropFirst(5))
                if value.hasPrefix(" ") { value = String(value.dropFirst()) }
                dataLines.append(value)
            }
        }
        if !dataLines.isEmpty, let data = dataLines.joined(separator: "\n").data(using: .utf8) {
            events.append(data)
        }
        return events
    }

    /// Directories a GUI-launched Mac app usually lacks on PATH (Homebrew, nvm, bun, …).
    public static func stdioPATH(
        existing: String,
        home: String,
        exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> String {
        var extras = [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "\(home)/.local/bin",
            "\(home)/.bun/bin",
            "\(home)/.volta/bin",
            "\(home)/.cargo/bin",
            "\(home)/.asdf/shims",
            "\(home)/.fnm/aliases/default/bin",
            "\(home)/.local/share/fnm/aliases/default/bin",
        ]
        let nvmVersions = "\(home)/.nvm/versions/node"
        if exists(nvmVersions),
           let names = try? FileManager.default.contentsOfDirectory(atPath: nvmVersions) {
            for name in names.sorted().reversed() {
                extras.append("\(nvmVersions)/\(name)/bin")
            }
        }
        var parts = existing.split(separator: ":").map(String.init).filter { !$0.isEmpty }
        for dir in extras.reversed() where exists(dir) && !parts.contains(dir) {
            parts.insert(dir, at: 0)
        }
        return parts.joined(separator: ":")
    }

    public static func stdioEnvironment(
        userEnv: [String: String],
        processEnv: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory()
    ) -> [String: String] {
        var env = processEnv
        let resolvedHome = userEnv["HOME"] ?? env["HOME"] ?? home
        env["HOME"] = resolvedHome
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        let basePath = userEnv["PATH"] ?? env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = stdioPATH(existing: basePath, home: resolvedHome)
        for (key, value) in userEnv where key != "PATH" {
            env[key] = value
        }
        if let userPath = userEnv["PATH"] {
            env["PATH"] = stdioPATH(existing: userPath, home: resolvedHome)
        }
        return env
    }

    public static func extractStdioMessages(from buffer: inout Data) -> [Data] {
        var messages: [Data] = []
        while let message = popStdioMessage(from: &buffer) {
            if !message.isEmpty {
                messages.append(message)
            }
        }
        return messages
    }

    private static func popStdioMessage(from buffer: inout Data) -> Data? {
        guard !buffer.isEmpty else { return nil }
        let crlf = Data("\r\n\r\n".utf8)
        if let headerEnd = buffer.range(of: crlf) {
            let headerData = buffer.subdata(in: buffer.startIndex..<headerEnd.lowerBound)
            let header = String(data: headerData, encoding: .utf8) ?? ""
            if let length = contentLength(in: header) {
                let start = headerEnd.upperBound
                let endOffset = buffer.distance(from: buffer.startIndex, to: start) + length
                guard buffer.count >= endOffset else { return nil }
                let end = buffer.index(buffer.startIndex, offsetBy: endOffset)
                let body = buffer.subdata(in: start..<end)
                buffer.removeSubrange(buffer.startIndex..<end)
                return body
            }
        }
        guard let newline = buffer.range(of: Data([0x0A])) else { return nil }
        let line = buffer.subdata(in: buffer.startIndex..<newline.lowerBound)
        buffer.removeSubrange(buffer.startIndex...newline.lowerBound)
        if line.isEmpty { return Data() }
        let trimmed = String(data: line, encoding: .utf8)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\r")) ?? ""
        if trimmed.lowercased().hasPrefix("content-length:") {
            return Data()
        }
        return line
    }

    private static func contentLength(in header: String) -> Int? {
        for raw in header.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            let lower = line.lowercased()
            guard lower.hasPrefix("content-length:") else { continue }
            let value = line.dropFirst("Content-Length:".count).trimmingCharacters(in: .whitespaces)
            return Int(value)
        }
        return nil
    }

    static func jsonRPCId(_ object: [String: Any]) -> Int? {
        if let i = object["id"] as? Int { return i }
        if let n = object["id"] as? NSNumber { return n.intValue }
        if let d = object["id"] as? Double { return Int(d) }
        return nil
    }

    public static func formatToolList(_ tools: [McpToolInfo]) -> String {
        if tools.isEmpty { return "No tools." }
        let gateway = tools.contains { McpGatewayCall.isMetaTool($0.name) }
        var lines: [String] = []
        if gateway {
            lines.append(contentsOf: [
                "Lazy MCP gateway: this list is meta-tools, not GitHub/Obsidian/etc.",
                "1. toolport_status once if you need server prefixes and tool counts.",
                "2. toolport_search_tools once (server: \"github\" with an empty query lists that server).",
                "3. mcp_call with tool=toolport_call_tool and arguments.name = the exact catalog name (not id). Passing github__search_repositories as mcp_call's tool is also fine — it is wrapped.",
                "4. Do not search again this turn. Do not curl or shell those APIs when a catalog tool exists.",
                "5. If a GrizzyBot builtin is off, use Toolport for that job (fast-filesystem for files, web search for news). After you have titles or a dataset, summarize and write — do not toolport_fetch_result (cursors expire) or toolport_run_script.",
                "",
            ])
        }
        lines.append(contentsOf: tools.map { formatToolLine($0, compact: gateway) })
        return lines.joined(separator: "\n")
    }

    private static func formatToolLine(_ tool: McpToolInfo, compact: Bool) -> String {
        var line = "• \(tool.name)"
        if !tool.description.isEmpty {
            let description = compact
                ? String(tool.description.prefix(120)).replacingOccurrences(of: "\n", with: " ")
                : tool.description
            line += " — \(description)"
        }
        let schema = tool.inputSchema.mapValues(\.value)
        let properties = (schema["properties"] as? [String: Any]) ?? [:]
        if !properties.isEmpty {
            let keys = properties.keys.sorted().joined(separator: ", ")
            line += "\n  args: \(keys)"
            if let required = schema["required"] as? [String], !required.isEmpty {
                line += " (required: \(required.joined(separator: ", ")))"
            }
        }
        return line
    }
}

/// Flatten `mcp_call` arguments so path/content work whether nested or top-level.
public enum McpCallArguments {
    /// `name` is not reserved: Toolport's call_tool requires it, and `tool` already identifies the MCP tool.
    private static let reserved: Set<String> = ["server", "tool"]

    public static func resolve(_ args: [String: JSONValue]) -> [String: JSONValue] {
        var call = args["arguments"]?.objectValue() ?? [:]
        for (key, value) in args where !reserved.contains(key) && key != "arguments" {
            if call[key] == nil {
                call[key] = value
            }
        }
        if call.isEmpty {
            for key in ["prompt", "query", "text"] {
                if case .string(let text) = args[key] {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        call["prompt"] = .string(trimmed)
                        break
                    }
                }
            }
        }
        return applyAliases(call)
    }

    /// Fill required MCP/Toolport fields from common LLM aliases (`path` → `filepath`, etc.).
    public static func applyAliases(_ args: [String: JSONValue]) -> [String: JSONValue] {
        var out = args
        fill(&out, canonical: "filepath", aliases: [
            "path", "file", "filename", "file_path", "note_path", "relative_path", "vault_path",
        ])
        fill(&out, canonical: "dirpath", aliases: [
            "dir", "directory", "folder", "folder_path", "path",
        ])
        fill(&out, canonical: "content", aliases: [
            "text", "body", "markdown", "data", "note", "value",
        ])
        fill(&out, canonical: "query", aliases: [
            "search", "q", "prompt", "term",
        ])
        fill(&out, canonical: "url", aliases: [
            "href", "link", "uri",
        ])
        return out
    }

    private static func fill(
        _ out: inout [String: JSONValue],
        canonical: String,
        aliases: [String]
    ) {
        if out[canonical] != nil { return }
        for alias in aliases {
            guard let value = out[alias] else { continue }
            if case .string(let text) = value {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                out[canonical] = .string(trimmed)
                return
            }
            out[canonical] = value
            return
        }
    }
}

// MARK: - Stdio session

final class McpStdioSession: McpSession, @unchecked Sendable {
    private let process: Process
    private let stdin: FileHandle
    private let stdout: FileHandle
    private let stderr: FileHandle
    private let queue = DispatchQueue(label: "grizzybot.mcp.stdio")
    private var nextId = 1
    private var buffer = Data()
    private var stderrBytes = Data()
    private var pending: [Int: CheckedContinuation<SendableJSON, Error>] = [:]
    private var closed = false
    private var didFail = false
    private var lastError: Error?
    private var exitStatus: Int?
    private let timeout: TimeInterval

    static func open(server: McpServer, timeout: TimeInterval) async throws -> McpStdioSession {
        let command = server.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else {
            throw McpError.invalidConfiguration("Stdio MCP server needs a command")
        }

        let env = McpClient.stdioEnvironment(userEnv: server.env)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.hasPrefix("/") ? command : "/usr/bin/env")
        if command.hasPrefix("/") {
            process.arguments = server.args
        } else {
            process.arguments = [command] + server.args
        }
        process.environment = env
        if let home = env["HOME"] {
            process.currentDirectoryURL = URL(fileURLWithPath: home)
        }

        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            throw McpError.launchFailed(error.localizedDescription)
        }

        let session = McpStdioSession(
            process: process,
            stdin: inPipe.fileHandleForWriting,
            stdout: outPipe.fileHandleForReading,
            stderr: errPipe.fileHandleForReading,
            timeout: timeout
        )
        session.startReading()
        return session
    }

    private init(
        process: Process,
        stdin: FileHandle,
        stdout: FileHandle,
        stderr: FileHandle,
        timeout: TimeInterval
    ) {
        self.process = process
        self.stdin = stdin
        self.stdout = stdout
        self.stderr = stderr
        self.timeout = timeout
    }

    private func startReading() {
        stderr.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty, let self else { return }
            self.queue.async { self.stderrBytes.append(chunk) }
        }
        stdout.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self else { return }
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                self.queue.asyncAfter(deadline: .now() + 0.08) {
                    self.failRemaining()
                }
                return
            }
            self.queue.async { self.ingest(chunk) }
        }
        process.terminationHandler = { [weak self] proc in
            guard let session = self else { return }
            let status = Int(proc.terminationStatus)
            session.queue.async {
                session.exitStatus = status
                session.drainStderr()
                session.failRemaining()
            }
        }
    }

    private func drainStderr() {
        stderr.readabilityHandler = nil
        let rest = stderr.availableData
        if !rest.isEmpty { stderrBytes.append(rest) }
    }

    private func ingest(_ chunk: Data) {
        buffer.append(chunk)
        for message in McpClient.extractStdioMessages(from: &buffer) {
            handleLine(message)
        }
    }

    private func handleLine(_ line: Data) {
        do {
            let obj = try McpClient.decodeJSONObject(line)
            guard let id = McpClient.jsonRPCId(obj) else { return }
            if let error = obj["error"] as? [String: Any] {
                let code = error["code"] as? Int ?? -1
                let message = error["message"] as? String ?? "unknown"
                pending.removeValue(forKey: id)?.resume(throwing: McpError.remote(code: code, message: message))
            } else if let result = obj["result"] {
                pending.removeValue(forKey: id)?.resume(returning: SendableJSON(result))
            } else {
                pending.removeValue(forKey: id)?.resume(returning: SendableJSON([String: Any]()))
            }
        } catch {
            // Skip malformed / log lines.
        }
    }

    private func failRemaining() {
        guard !didFail else { return }
        let err = String(data: stderrBytes, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let message: String
        if let status = exitStatus {
            message = err.isEmpty
                ? "MCP server exited (\(status))"
                : "MCP server exited (\(status)): \(String(err.suffix(800)))"
        } else if !err.isEmpty {
            message = "MCP server closed stdout: \(String(err.suffix(800)))"
        } else if pending.isEmpty {
            return
        } else {
            message = "MCP server closed stdout"
        }
        failAll(McpError.transport(message))
    }

    func sendRequest(method: String, params: [String: Any]?) async throws -> Any {
        let id: Int = queue.sync {
            let current = nextId
            nextId += 1
            return current
        }
        let encodableParams = params?.mapValues(AnyCodableMCP.init)
        let req = McpJSONRPCRequest(id: id, method: method, params: encodableParams)
        let data = try McpClient.encodeJSONRPC(req) + Data([0x0A])

        return try await withThrowingTaskGroup(of: SendableJSON.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<SendableJSON, Error>) in
                    self.queue.async {
                        if self.didFail {
                            cont.resume(throwing: self.lastError ?? McpError.cancelled)
                            return
                        }
                        if self.closed {
                            cont.resume(throwing: McpError.cancelled)
                            return
                        }
                        self.pending[id] = cont
                        do {
                            try self.stdin.write(contentsOf: data)
                        } catch {
                            self.queue.asyncAfter(deadline: .now() + 0.12) {
                                guard !self.didFail else { return }
                                self.pending.removeValue(forKey: id)
                                let err = String(data: self.stderrBytes, encoding: .utf8)?
                                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                                if !err.isEmpty {
                                    cont.resume(throwing: McpError.transport(err))
                                } else {
                                    cont.resume(throwing: McpError.transport(error.localizedDescription))
                                }
                            }
                        }
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(self.timeout * 1_000_000_000))
                throw McpError.timeout
            }
            let value = try await group.next()!
            group.cancelAll()
            return value.value
        }
    }

    func sendNotification(method: String, params: [String: Any]?) async throws {
        let encodableParams = params?.mapValues(AnyCodableMCP.init)
        let note = McpJSONRPCNotification(method: method, params: encodableParams)
        let data = try McpClient.encodeJSONRPC(note) + Data([0x0A])
        try queue.sync {
            try stdin.write(contentsOf: data)
        }
    }

    func close() async {
        queue.sync {
            closed = true
            failAll(McpError.cancelled)
        }
        stdout.readabilityHandler = nil
        stderr.readabilityHandler = nil
        try? stdin.close()
        if process.isRunning {
            process.terminate()
        }
    }

    private func failAll(_ error: Error) {
        guard !didFail else { return }
        didFail = true
        lastError = error
        let waiting = pending
        pending.removeAll()
        for (_, cont) in waiting {
            cont.resume(throwing: error)
        }
    }
}

// MARK: - HTTP / SSE session

enum McpHTTPMode {
    case streamable
    case legacySSE
}

final class McpHTTPSession: McpSession, @unchecked Sendable {
    private let endpoint: URL
    private let headers: [String: String]
    private let mode: McpHTTPMode
    private let timeout: TimeInterval
    private let session: URLSession
    private let lock = NSLock()
    private var nextId = 1
    private var mcpSessionId: String?
    private var negotiatedVersion = McpClient.protocolVersion
    /// Legacy SSE: POST messages here after reading `endpoint` event.
    private var messageURL: URL?
    private var forceLegacy = false

    static func open(server: McpServer, mode: McpHTTPMode, timeout: TimeInterval) async throws -> McpHTTPSession {
        let raw = server.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw), url.scheme == "http" || url.scheme == "https" else {
            throw McpError.invalidConfiguration("HTTP/SSE MCP server needs a valid http(s) URL")
        }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        let urlSession = URLSession(configuration: config)
        let client = McpHTTPSession(
            endpoint: url,
            headers: server.headers,
            mode: mode,
            timeout: timeout,
            session: urlSession
        )
        if mode == .legacySSE {
            try await client.bootstrapLegacySSE()
            client.forceLegacy = true
        }
        return client
    }

    private init(
        endpoint: URL,
        headers: [String: String],
        mode: McpHTTPMode,
        timeout: TimeInterval,
        session: URLSession
    ) {
        self.endpoint = endpoint
        self.headers = headers
        self.mode = mode
        self.timeout = timeout
        self.session = session
    }

    private func bootstrapLegacySSE() async throws {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        applyUserHeaders(to: &request)

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw McpError.transport("Legacy SSE GET failed")
        }

        var dataBuffer = ""
        for try await line in bytes.lines {
            if line.isEmpty {
                if let endpointPath = parseEndpointEvent(dataBuffer) {
                    messageURL = resolveURL(endpointPath)
                    return
                }
                dataBuffer = ""
                continue
            }
            if line.hasPrefix("event:") {
                // track if needed
            } else if line.hasPrefix("data:") {
                var value = String(line.dropFirst(5))
                if value.hasPrefix(" ") { value = String(value.dropFirst()) }
                if !dataBuffer.isEmpty { dataBuffer += "\n" }
                dataBuffer += value
            }
            // Safety: some servers send endpoint without blank line quickly
            if let endpointPath = parseEndpointEvent(dataBuffer), messageURL == nil {
                messageURL = resolveURL(endpointPath)
                return
            }
        }
        guard messageURL != nil else {
            throw McpError.transport("Legacy SSE did not send an endpoint event")
        }
    }

    private func parseEndpointEvent(_ data: String) -> String? {
        let trimmed = data.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") || trimmed.hasPrefix("/") {
            return trimmed
        }
        if let obj = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any],
           let ep = obj["endpoint"] as? String {
            return ep
        }
        return nil
    }

    private func resolveURL(_ pathOrURL: String) -> URL? {
        if let absolute = URL(string: pathOrURL), absolute.scheme != nil {
            return absolute
        }
        return URL(string: pathOrURL, relativeTo: endpoint)?.absoluteURL
    }

    func sendRequest(method: String, params: [String: Any]?) async throws -> Any {
        let id: Int = {
            lock.lock()
            defer { lock.unlock() }
            let current = nextId
            nextId += 1
            return current
        }()

        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params ?? [:],
        ]
        let data = try JSONSerialization.data(withJSONObject: body)

        if mode == .streamable && !forceLegacy {
            do {
                return try await postStreamable(data: data, method: method, nameHint: params?["name"] as? String)
            } catch {
                // Auto-fallback to legacy SSE when streamable init is rejected.
                if method == "initialize" {
                    try await bootstrapLegacySSE()
                    forceLegacy = true
                    return try await postLegacy(data: data)
                }
                throw error
            }
        } else {
            return try await postLegacy(data: data)
        }
    }

    func sendNotification(method: String, params: [String: Any]?) async throws {
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
            "params": params ?? [:],
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        if mode == .streamable && !forceLegacy {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.httpBody = data
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
            request.setValue(negotiatedVersion, forHTTPHeaderField: "MCP-Protocol-Version")
            if let mcpSessionId {
                request.setValue(mcpSessionId, forHTTPHeaderField: "MCP-Session-Id")
            }
            applyUserHeaders(to: &request)
            let (_, response) = try await session.data(for: request)
            _ = response
        } else {
            _ = try? await postLegacy(data: data, expectResult: false)
        }
    }

    private func postStreamable(data: Data, method: String, nameHint: String?) async throws -> Any {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(negotiatedVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        request.setValue(method, forHTTPHeaderField: "Mcp-Method")
        if let nameHint {
            request.setValue(nameHint, forHTTPHeaderField: "Mcp-Name")
        }
        if let mcpSessionId {
            request.setValue(mcpSessionId, forHTTPHeaderField: "MCP-Session-Id")
        }
        applyUserHeaders(to: &request)

        let (responseData, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw McpError.transport("Invalid HTTP response")
        }

        if let sid = http.value(forHTTPHeaderField: "MCP-Session-Id"), !sid.isEmpty {
            mcpSessionId = sid
        }

        if http.statusCode == 400 || http.statusCode == 404 || http.statusCode == 405 {
            throw McpError.transport("Streamable HTTP rejected (\(http.statusCode))")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: responseData, encoding: .utf8) ?? ""
            throw McpError.transport("HTTP \(http.statusCode): \(body.prefix(200))")
        }

        let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        if contentType.contains("text/event-stream") {
            return try extractResult(fromSSE: String(data: responseData, encoding: .utf8) ?? "")
        }
        return try extractResult(fromJSON: responseData)
    }

    private func postLegacy(data: Data, expectResult: Bool = true) async throws -> Any {
        guard let url = messageURL ?? (mode == .legacySSE ? nil : endpoint) else {
            throw McpError.transport("Legacy SSE message endpoint missing")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        applyUserHeaders(to: &request)

        let (responseData, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw McpError.transport("Invalid HTTP response")
        }
        if !expectResult {
            return [String: Any]()
        }
        guard (200..<300).contains(http.statusCode) else {
            throw McpError.transport("HTTP \(http.statusCode)")
        }
        let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        if contentType.contains("text/event-stream") {
            return try extractResult(fromSSE: String(data: responseData, encoding: .utf8) ?? "")
        }
        if responseData.isEmpty {
            return [String: Any]()
        }
        return try extractResult(fromJSON: responseData)
    }

    private func extractResult(fromJSON data: Data) throws -> Any {
        let obj = try McpClient.decodeJSONObject(data)
        if let error = obj["error"] as? [String: Any] {
            throw McpError.remote(
                code: error["code"] as? Int ?? -1,
                message: error["message"] as? String ?? "unknown"
            )
        }
        if let result = obj["result"] {
            if let dict = result as? [String: Any],
               let version = dict["protocolVersion"] as? String {
                negotiatedVersion = version
            }
            return result
        }
        return obj
    }

    private func extractResult(fromSSE text: String) throws -> Any {
        let events = McpClient.parseSSEDataEvents(text)
        for event in events.reversed() {
            if let obj = try? McpClient.decodeJSONObject(event) {
                if obj["result"] != nil || obj["error"] != nil {
                    return try extractResult(fromJSON: event)
                }
            }
        }
        throw McpError.protocolError("SSE stream had no JSON-RPC response")
    }

    private func applyUserHeaders(to request: inout URLRequest) {
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
    }

    func close() async {
        session.invalidateAndCancel()
        if let mcpSessionId {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "DELETE"
            request.setValue(mcpSessionId, forHTTPHeaderField: "MCP-Session-Id")
            applyUserHeaders(to: &request)
            _ = try? await URLSession.shared.data(for: request)
        }
    }
}
