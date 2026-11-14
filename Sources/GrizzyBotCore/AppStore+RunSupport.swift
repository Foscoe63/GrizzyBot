import Foundation
import Observation

// Applying scripted actions, bot-home files, and finishing, stopping and answering runs.
extension AppStore {
    func applyAction(
        _ action: ScriptedAction?,
        botId: String,
        blocks: inout [MessageBlock],
        thread: inout ThreadData,
        runId: String
    ) async {
        guard let action else { return }
        switch action {
        case .spawnBot(let name, let title):
            let child = createBot(
                name: name,
                title: title,
                description: "",
                instructions: "",
                parentBotId: botId
            )
            // createBot selects the child; restore parent as active for the chat context
            activeBotId = botId
            blocks.append(.childBot(botId: child.id, name: child.name, title: child.title, status: .created))

        case .deleteBot(let name):
            if let target = bots.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                let id = target.id
                let n = target.name
                deleteBot(id)
                blocks.append(.childBot(botId: id, name: n, title: nil, status: .deleted))
            }

        case .subagent(let task):
            blocks.append(
                .subagent(
                    agentId: Ids.new(),
                    name: "helper",
                    task: task,
                    status: .running,
                    progress: "working…",
                    result: nil
                )
            )

        case .takeover:
            if var computer = computers[botId] {
                computer.controlHolder = .user
                computers[botId] = computer
            }

        case .remember(let text):
            upsertMemory(botId: botId, text: text)

        case .writeFile(let path, let content):
            writeBotFile(botId: botId, path: path, content: content)
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            blocks.append(.card(lines: [
                CardLine(k: "wrote", v: path),
                CardLine(k: "preview", v: String(trimmed.prefix(240))),
            ]))

        case .readFile(let path):
            do {
                let content = try botHome.read(botId: botId, path: path)
                blocks.append(.card(lines: [
                    CardLine(k: "read", v: path),
                    CardLine(k: "content", v: String(content.prefix(800))),
                ]))
            } catch {
                blocks.append(.card(lines: [CardLine(k: "read failed", v: error.localizedDescription)]))
            }

        case .editFile(let path, let content, let append):
            do {
                try botHome.edit(
                    botId: botId,
                    path: path,
                    content: content,
                    mode: append ? .append : .replace
                )
                refreshFilesMirror(botId: botId)
                blocks.append(.card(lines: [
                    CardLine(k: append ? "appended" : "edited", v: path),
                ]))
            } catch {
                blocks.append(.card(lines: [CardLine(k: "edit failed", v: error.localizedDescription)]))
            }

        case .moveFile(let from, let to):
            do {
                try botHome.move(botId: botId, from: from, to: to)
                refreshFilesMirror(botId: botId)
                blocks.append(.card(lines: [
                    CardLine(k: "moved", v: "\(from) → \(to)"),
                ]))
            } catch {
                blocks.append(.card(lines: [CardLine(k: "move failed", v: error.localizedDescription)]))
            }

        case .deleteFile(let path):
            do {
                try botHome.delete(botId: botId, path: path)
                refreshFilesMirror(botId: botId)
                blocks.append(.card(lines: [CardLine(k: "deleted", v: path)]))
            } catch {
                blocks.append(.card(lines: [CardLine(k: "delete failed", v: error.localizedDescription)]))
            }

        case .listFiles(let directory):
            do {
                let entries = try botHome.list(botId: botId, directory: directory)
                if entries.isEmpty {
                    blocks.append(.card(lines: [CardLine(k: "home", v: "(empty)")]))
                } else {
                    let lines = entries.prefix(20).map { entry in
                        CardLine(k: entry.isDirectory ? "dir" : "file", v: entry.path)
                    }
                    blocks.append(.card(lines: Array(lines)))
                }
            } catch {
                blocks.append(.card(lines: [CardLine(k: "list failed", v: error.localizedDescription)]))
            }

        case .webSearch(let query):
            do {
                let results = try await WebSearch.search(query: query, limit: 5, braveKey: appConfig.braveSearchKey)
                if results.isEmpty {
                    blocks.append(.card(lines: [
                        CardLine(k: "search", v: query),
                        CardLine(k: "results", v: "no results"),
                    ]))
                } else {
                    var lines = [CardLine(k: "search", v: query)]
                    for (idx, item) in results.enumerated() {
                        lines.append(CardLine(k: "\(idx + 1). \(item.title)", v: item.snippet.isEmpty ? item.url : item.snippet))
                    }
                    blocks.append(.card(lines: lines))
                    blocks.append(.text(results.map { "• **\($0.title)** — \($0.snippet)\n  \($0.url)" }.joined(separator: "\n\n")))
                }
            } catch {
                blocks.append(.card(lines: [
                    CardLine(k: "search failed", v: error.localizedDescription),
                ]))
            }

        case .destinationWrite(let title, let body):
            let record = DestinationRecord(slug: "local", title: title, body: body)
            try? destinations.append(record)
            blocks.append(.card(lines: [
                CardLine(k: title, v: "recorded"),
                CardLine(k: "id", v: record.id),
            ]))

        case .customTool(let id, let name):
            if let tool = customTools.first(where: { $0.id == id }) {
                blocks.append(.card(lines: [
                    CardLine(k: "tool", v: name),
                    CardLine(k: "status", v: "completed"),
                ]))
                _ = tool
            } else {
                blocks.append(.card(lines: [CardLine(k: "tool", v: name), CardLine(k: "status", v: "completed")]))
            }

        case .mcpServer(let id, let name, let prompt):
            if let server = mcpServers.first(where: { $0.id == id }) {
                do {
                    let result = try await McpClient.invoke(server: server, prompt: prompt)
                    var lines = [
                        CardLine(k: "mcp", v: name),
                        CardLine(k: "transport", v: server.transport.rawValue),
                        CardLine(k: "tool", v: result.toolName),
                        CardLine(k: "status", v: result.isError ? "tool error" : "ok"),
                    ]
                    switch server.transport {
                    case .stdio:
                        lines.insert(CardLine(k: "command", v: server.summaryLine), at: 2)
                    case .http, .sse:
                        lines.insert(CardLine(k: "url", v: server.summaryLine), at: 2)
                    }
                    blocks.append(.card(lines: lines))
                    let body = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !body.isEmpty {
                        blocks.append(.text(String(body.prefix(4000))))
                    }
                } catch {
                    blocks.append(.card(lines: [
                        CardLine(k: "mcp", v: name),
                        CardLine(k: "transport", v: server.transport.rawValue),
                        CardLine(k: "status", v: "failed"),
                        CardLine(k: "error", v: error.localizedDescription),
                    ]))
                }
            } else {
                blocks.append(.card(lines: [
                    CardLine(k: "mcp", v: name),
                    CardLine(k: "status", v: "missing"),
                ]))
            }
        }
    }

    func writeBotFile(botId: String, path: String, content: String) {
        do {
            try botHome.write(botId: botId, path: path, content: content)
        } catch {
            // Fall back to workspace mirror only.
        }
        upsertFile(path: path, content: content)
        refreshFilesMirror(botId: botId)
        ingestMemoryFileIfNeeded(botId: botId, path: path)
    }

    func refreshFilesMirror(botId: String) {
        if let listed = try? botHome.allFilesFlat(botId: botId) {
            files = listed
        }
    }

    public func botHomeEntries(botId: String) -> [BotHomeStore.Entry] {
        (try? botHome.list(botId: botId)) ?? []
    }

    public func readBotHomeFile(botId: String, path: String) -> String? {
        try? botHome.read(botId: botId, path: path)
    }

    func threadKey(for botId: String) -> String {
        if let bot = bots.first(where: { $0.id == botId }), let taskId = bot.activeTaskId {
            return taskId
        }
        return botId
    }

    func completeSubagent(botId: String, threadKey: String, runId: String, messageId: String, task: String) async {
        await sleep(1.5)
        guard !Task.isCancelled else { return }
        guard var thread = threads[threadKey] else { return }
        guard let msgIdx = thread.messages.firstIndex(where: { $0.id == messageId }) else { return }
        var blocks = thread.messages[msgIdx].blocks
        for i in blocks.indices {
            if case .subagent(let agentId, let name, let t, _, _, _) = blocks[i] {
                blocks[i] = .subagent(
                    agentId: agentId,
                    name: name,
                    task: t,
                    status: .completed,
                    progress: nil,
                    result: ScriptedRuntime.subagentResult(for: task)
                )
            }
        }
        thread.messages[msgIdx].blocks = blocks
        thread.run?.status = .completed
        thread.run?.completedAt = .now
        threads[threadKey] = thread
        if let idx = bots.firstIndex(where: { $0.id == botId }) {
            bots[idx].status = "idle"
        }
        save()
        runTasks.removeValue(forKey: runId)
        releaseWorkingFolderOverrideIfNeeded(botId: botId)
    }

    func finishCancelled(botId: String, threadKey: String? = nil, runId: String) {
        let key = threadKey ?? self.threadKey(for: botId)
        guard var thread = threads[key], thread.run?.id == runId else { return }
        thread.messages.removeAll { msg in
            msg.runId == runId && msg.blocks.contains { if case .progress = $0 { return true }; return false }
        }
        thread.run?.status = .cancelled
        thread.run?.completedAt = .now
        // A card that was waiting on this run must not stay answerable: "Always allow" on it would
        // still add a standing rule for a run that no longer exists.
        thread.cancelPendingApprovals()
        thread.pendingTool = nil
        threads[key] = thread
        if let idx = bots.firstIndex(where: { $0.id == botId }) {
            bots[idx].status = "idle"
        }
        runTasks.removeValue(forKey: runId)
        save()
        finishRoutineIfNeeded(botId: botId, threadKey: key, status: .cancelled, error: "cancelled")
        releaseWorkingFolderOverrideIfNeeded(botId: botId)
        settleQueue(botId: botId, threadKey: key, runId: runId, cancelled: true)
    }

    func finishRoutineIfNeeded(
        botId: String,
        threadKey: String,
        status: RunStatus?,
        error: String?
    ) {
        guard let run = threads[threadKey]?.run, RoutineTrigger.isRoutine(run.trigger),
              let routineId = run.routineId,
              let idx = routines[botId]?.firstIndex(where: { $0.id == routineId }),
              let routine = routines[botId]?[idx]
        else { return }
        guard let status, status != .running, status != .queued, status != .leased else {
            return // still in flight; leave inProgress set
        }
        let plan = RoutineTickPolicy.reschedule(
            routine,
            status: status,
            manual: run.trigger != RoutineTrigger.scheduled,
            error: error
        )
        routines[botId]?[idx].inProgress = false
        routines[botId]?[idx].nextRunAt = plan.nextRunAt
        routines[botId]?[idx].failCount = plan.failCount
        routines[botId]?[idx].lastError = plan.lastError
        save()
    }

    public func stopRun(botId: String) {
        cancelDispatch(chiefId: botId)
        let key = threadKey(for: botId)
        guard let runId = threads[key]?.run?.id else { return }
        runTasks[runId]?.cancel()
        finishCancelled(botId: botId, threadKey: key, runId: runId)
    }

    public func answerAsk(botId: String, answer: String = "approved") {
        guard var thread = threads[botId] else { return }
        let msg = ThreadMessage(
            id: Ids.new(),
            threadId: thread.threadId,
            seq: thread.nextSeq,
            role: .bot,
            blocks: [.text("done — sent.")]
        )
        thread.messages.append(msg)
        thread.cursor = msg.seq
        if thread.run?.status == .waitingInput {
            thread.run?.status = .completed
            thread.run?.completedAt = .now
        }
        threads[botId] = thread
        _ = answer
        save()
        releaseWorkingFolderOverrideIfNeeded(botId: botId)
    }
}
