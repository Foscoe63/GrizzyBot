import Foundation
import Observation

// Sending a message, queueing, and the LLM and scripted agent runs.
extension AppStore {
    public func send(botId: String, text: String, attaching files: [URL] = [], workingFolderOverride: String? = nil) {
        // A routing decision for this bot is still in flight; keep message order by waiting for it.
        if routingInFlight.contains(botId) {
            routingHolds[botId, default: []].append(HeldSend(text: text, files: files, workingFolderOverride: workingFolderOverride))
            return
        }
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var imported: [String] = []
        for file in files {
            if let path = try? botHome.importFile(botId: botId, from: file) {
                imported.append(path)
            }
        }
        let attachedJPEG = ComposerImage.jpegBase64(from: files)
            ?? ComposerImage.jpegBase64(fromPathInText: trimmed)
        if let attachedJPEG, !attachedJPEG.isEmpty {
            // Path-only paste (`/Users/…/Screenshot.png`) → treat as an image caption.
            if ComposerImage.isImagePath(trimmed) || SlashCommand.looksLikeFilesystemPath(token: trimmed, full: trimmed) {
                trimmed = "Please describe this image."
            }
        }
        if !imported.isEmpty {
            let list = imported.map { "- `\($0)`" }.joined(separator: "\n")
            let note = "Attached files (in your home):\n\(list)"
            trimmed = trimmed.isEmpty ? note : "\(trimmed)\n\n\(note)"
        }
        guard !trimmed.isEmpty || !(attachedJPEG?.isEmpty ?? true) else { return }
        if trimmed.isEmpty {
            trimmed = "Please describe this image."
        }
        guard let bot = bots.first(where: { $0.id == botId }) else { return }
        let botSkills = skills(for: bot)
        var isPlain = false

        switch SlashCommand.resolve(trimmed, skills: botSkills) {
        case .help(let listed):
            appendLocalAssistant(
                botId: botId,
                userText: trimmed,
                reply: SlashCommand.helpText(skills: listed)
            )
            return
        case .unknown(let name):
            appendLocalAssistant(
                botId: botId,
                userText: trimmed,
                reply: "Unknown command `/\(name)`. Type `/help` to list skills enabled for this bot."
            )
            return
        case .builtin(let command, let argument):
            if let reply = handleBuiltin(command, argument: argument, botId: botId) {
                appendLocalAssistant(botId: botId, userText: trimmed, reply: reply)
                return
            }
        case .plain:
            isPlain = true
        case .skill:
            break
        }

        let threadKey: String = {
            if let taskId = bot.activeTaskId {
                return taskId
            }
            return botId
        }()
        if let run = threads[threadKey]?.run, run.status == .running, runTasks[run.id] != nil {
            queueWhileBusy(botId: botId, threadKey: threadKey, run: run, text: trimmed, imageJPEG: attachedJPEG)
            return
        }
        var turnText = trimmed
        if isPlain, attachedJPEG == nil, workingFolderOverride == nil, files.isEmpty {
            // The Chief of Staff hands a message that clearly belongs to someone else to them.
            guard let proceed = dispatchOrProceed(
                bot: bot, threadKey: threadKey, text: trimmed,
                original: HeldSend(text: trimmed, files: files, workingFolderOverride: workingFolderOverride)
            ) else { return }
            turnText = proceed
        }
        submitUserTurn(
            botId: botId,
            threadKey: threadKey,
            text: turnText,
            imageJPEG: attachedJPEG,
            workingFolderOverride: workingFolderOverride
        )
    }

    /// Files the message as a user turn on its thread and starts the run for it.
    func submitUserTurn(
        botId: String,
        threadKey: String,
        text: String,
        imageJPEG: String?,
        workingFolderOverride: String? = nil
    ) {
        guard var thread = threads[threadKey] ?? threads[botId] else { return }
        if threads[threadKey] == nil {
            threads[threadKey] = thread
        }
        guard let botIdx = bots.firstIndex(where: { $0.id == botId }) else { return }

        let userMsg = ThreadMessage(
            id: Ids.new(),
            threadId: thread.threadId,
            seq: thread.nextSeq,
            role: .user,
            blocks: [.text(text)]
        )
        thread.messages.append(userMsg)
        thread.cursor = userMsg.seq

        threads[threadKey] = thread
        bots[botIdx].preview = text.count > 80 ? String(text.prefix(80)) + "…" : text
        bots[botIdx].updatedAt = .now
        save()
        if let folder = workingFolderOverride?.trimmingCharacters(in: .whitespacesAndNewlines), !folder.isEmpty {
            runWorkingFolderOverride[botId] = (folder as NSString).expandingTildeInPath
        }
        launchRun(botId: botId, threadKey: threadKey, prompt: text, promptImageJPEGBase64: imageJPEG)
    }

    /// A message sent while the bot is mid-run. It shows up in the thread at once, then
    /// either reaches the run in flight (steer) or waits for it to end.
    func queueWhileBusy(botId: String, threadKey: String, run: Run, text: String, imageJPEG: String?) {
        guard var thread = threads[threadKey], let botIdx = bots.firstIndex(where: { $0.id == botId }) else { return }
        let userMsg = ThreadMessage(
            id: Ids.new(),
            threadId: thread.threadId,
            seq: thread.nextSeq,
            role: .user,
            blocks: [.text(text)]
        )
        thread.messages.append(userMsg)
        thread.cursor = userMsg.seq
        threads[threadKey] = thread
        bots[botIdx].preview = text.count > 80 ? String(text.prefix(80)) + "…" : text
        bots[botIdx].updatedAt = .now
        save()

        let item = QueuedSend(messageId: userMsg.id, text: text, imageJPEGBase64: imageJPEG)
        // A picture cannot be slipped into a run that is already underway.
        if appConfig.queueMode == .steer, imageJPEG == nil, let inbox = runInboxes[run.id] {
            inbox.push(item)
        } else {
            heldSends[threadKey, default: []].append(item)
        }
        appendRunLog(botId: botId, kind: "queue", text: "\(appConfig.queueMode.rawValue) \(String(text.prefix(120)))")
    }

    /// Called once a run has stopped. Gives anything left in the mailbox a turn of its own
    /// (the run ended before the loop looked), or drops it if the person pressed Stop.
    func settleQueue(botId: String, threadKey: String, runId: String, cancelled: Bool = false) {
        let leftover = runInboxes.removeValue(forKey: runId)?.drain() ?? []
        if cancelled {
            heldSends[threadKey] = nil
            return
        }
        let held = leftover + (heldSends[threadKey] ?? [])
        guard !held.isEmpty else { return }
        if let run = threads[threadKey]?.run, run.status == .running, runTasks[run.id] != nil { return }
        let turns = QueuePlanner.turns(for: held, mode: appConfig.queueMode)
        guard let first = turns.first else { return }
        let rest = turns.dropFirst().flatMap { $0 }
        heldSends[threadKey] = rest.isEmpty ? nil : Array(rest)

        // The messages are already on screen from when they were sent; pull them so the
        // turn files them again after the reply they were waiting behind.
        let ids = Set(first.map(\.messageId))
        if var thread = threads[threadKey] {
            thread.messages.removeAll { ids.contains($0.id) }
            threads[threadKey] = thread
        }
        submitUserTurn(
            botId: botId,
            threadKey: threadKey,
            text: QueuePlanner.merge(first.map(\.text)),
            imageJPEG: first.compactMap(\.imageJPEGBase64).last
        )
    }

    /// Slash / local replies that do not start an LLM run.
    func appendLocalAssistant(botId: String, userText: String, reply: String) {
        let threadKey: String = {
            if let bot = bots.first(where: { $0.id == botId }), let taskId = bot.activeTaskId {
                return taskId
            }
            return botId
        }()
        guard var thread = threads[threadKey] ?? threads[botId] else { return }
        if threads[threadKey] == nil {
            threads[threadKey] = thread
        }
        guard let botIdx = bots.firstIndex(where: { $0.id == botId }) else { return }

        let userMsg = ThreadMessage(
            id: Ids.new(),
            threadId: thread.threadId,
            seq: thread.nextSeq,
            role: .user,
            blocks: [.text(userText)]
        )
        thread.messages.append(userMsg)
        thread.cursor = userMsg.seq
        let assistant = ThreadMessage(
            id: Ids.new(),
            threadId: thread.threadId,
            seq: thread.nextSeq,
            role: .bot,
            blocks: [.text(reply)]
        )
        thread.messages.append(assistant)
        thread.cursor = assistant.seq
        threads[threadKey] = thread
        bots[botIdx].preview = reply.count > 80 ? String(reply.prefix(80)) + "…" : reply
        bots[botIdx].updatedAt = .now
        save()
    }

    func launchRun(
        botId: String,
        threadKey: String,
        prompt: String,
        promptImageJPEGBase64: String? = nil
    ) {
        guard var thread = threads[threadKey] else { return }
        guard let botIdx = bots.firstIndex(where: { $0.id == botId }) else { return }
        let run = Run(
            id: Ids.new(),
            botId: botId,
            threadId: thread.threadId,
            status: .running,
            trigger: "user"
        )
        thread.run = run
        threads[threadKey] = thread
        bots[botIdx].status = "working"
        bots[botIdx].updatedAt = .now
        save()
        let runId = run.id
        runInboxes[runId] = RunInbox()
        let imageNote = (promptImageJPEGBase64?.isEmpty == false) ? " +image" : ""
        appendRunLog(botId: botId, kind: "run", text: "start \(String(prompt.prefix(240)))\(imageNote)")
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runAgent(
                botId: botId,
                threadKey: threadKey,
                runId: runId,
                prompt: prompt,
                promptImageJPEGBase64: promptImageJPEGBase64
            )
        }
        runTasks[runId] = task
    }

    func runAgent(
        botId: String,
        threadKey: String,
        runId: String,
        prompt: String,
        promptImageJPEGBase64: String? = nil
    ) async {
        guard let bot = bots.first(where: { $0.id == botId }) else { return }
        if canRunLLM(for: bot) {
            await runLLMAgent(
                botId: botId,
                threadKey: threadKey,
                runId: runId,
                prompt: prompt,
                promptImageJPEGBase64: promptImageJPEGBase64
            )
        } else {
            await runScriptedAgent(botId: botId, threadKey: threadKey, runId: runId, prompt: prompt)
        }
    }

    func canRunLLM(for bot: Bot) -> Bool {
        let provider = bot.modelProvider ?? modelProvider
        let settings = modelProviderSettings(for: provider ?? "")
        return LLMRouting.canRun(
            provider: provider,
            apiKey: settings.apiKey,
            baseUrl: settings.baseUrl,
            injectedClient: chatCompleter != nil
        ) || !(settings.oauthJSON?.isEmpty ?? true)
    }

    func runLLMAgent(
        botId: String,
        threadKey: String,
        runId: String,
        prompt: String,
        promptImageJPEGBase64: String? = nil
    ) async {
        guard var thread = threads[threadKey], thread.run?.id == runId else { return }
        guard let bot = bots.first(where: { $0.id == botId }) else { return }

        let progressMsg = ThreadMessage(
            id: Ids.new(),
            threadId: thread.threadId,
            seq: thread.nextSeq,
            role: .bot,
            blocks: [.progress("thinking…")],
            runId: runId
        )
        thread.messages.append(progressMsg)
        thread.cursor = progressMsg.seq
        threads[threadKey] = thread

        var provider = bot.modelProvider ?? modelProvider
        var providerSettings = modelProviderSettings(for: provider ?? ModelCatalog.defaultProvider)
        var selectedModel = bot.modelId ?? providerSettings.modelId ?? modelId
        // A provider switched off in Models must not keep serving turns (the
        // workspace default can still point at it, e.g. Local MLX after the
        // user moves to LM Studio). Fall back to an enabled provider that has
        // a model chosen.
        if chatCompleter == nil, let current = provider, !isProviderEnabled(current),
           let fallback = enabledModelSources().first(where: { source in
               let s = modelProviderSettings(for: source.provider)
               return !(s.modelId ?? "").isEmpty
           }) {
            provider = fallback.provider
            providerSettings = modelProviderSettings(for: fallback.provider)
            selectedModel = providerSettings.modelId ?? selectedModel
        }
        // Short, conversational turns go to the bot's light model when it has one; the reply says so.
        let route = ModelRouter.route(
            prompt: prompt,
            hasImage: promptImageJPEGBase64?.isEmpty == false,
            isCommand: prompt.trimmingCharacters(in: .whitespaces).hasPrefix("/"),
            hasLightModel: bot.lightModel != nil
        )
        var routedNote: String?
        if route.isLight, let light = bot.lightModel {
            provider = light.provider
            providerSettings = modelProviderSettings(for: light.provider)
            selectedModel = light.modelId
            routedNote = "light model \(light.label)"
        }
        let client: any ChatCompleting = chatCompleter ?? Self.defaultClient(for: provider)
        await warmMcpCatalog(bot: bot, prompt: prompt)
        hydratePromotedFromAdvertised(bot: bot)
        let allTools = AgentToolCatalog.chatTools(
            enabledIds: runtimeBot(bot).enabledTools,
            mcpServers: mcpServers,
            includeDelegation: true,
            skills: skills(for: bot),
            promotedMcp: Array(mcpPromotedTools.values),
            mcpAdvertised: mcpAdvertisedTools
        )
        var tools = allTools
        var deferredTools: [ChatTool] = []
        if let selection = bot.toolSelection, !selection.isDefault {
            let used = Set(thread.llmMessages.flatMap(\.toolCalls).map(\.name))
            let applied = selection.apply(to: allTools, prompt: prompt, usedToolNames: used)
            tools = applied.offered
            deferredTools = applied.deferred
        }
        var prior = thread.messages.filter { $0.id != progressMsg.id }
        if prior.last?.role == .user {
            prior.removeLast()
        }
        let textHistory = prior.compactMap { message -> AgentHistoryTurn? in
            let text = message.firstText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return AgentHistoryTurn(role: message.role, text: text)
        }
        let priorLLM = thread.llmMessages
        let memoryRaw = memory.first(where: { $0.botId == botId && $0.path == "MEMORY.md" })?.content ?? ""
        let memoryText = MemoryLeanInject.excerpt(
            content: memoryRaw,
            query: prompt,
            mode: appConfig.memoryRelevanceMode
        )
        let sharedText = MemoryLeanInject.excerpt(
            content: sharedMemory,
            query: prompt,
            mode: appConfig.memoryRelevanceMode
        )
        let botSkills = skills(for: bot)
        let slash = SlashCommand.resolve(prompt, skills: botSkills)
        let pinFolderToRun = runWorkingFolderOverride[botId] != nil
        let agentPromptRaw: String
        let injected: [AgentSkill]
        switch slash {
        case .skill(let skill, let skillPrompt):
            agentPromptRaw = skillPrompt
            if pinFolderToRun {
                injected = []
            } else {
                var matched = SkillMarkdown.matching(botSkills, prompt: skillPrompt)
                matched.removeAll { $0.id == skill.id }
                injected = [skill] + matched
            }
        case .plain(let plain):
            agentPromptRaw = plain
            injected = pinFolderToRun ? [] : SkillMarkdown.matching(botSkills, prompt: plain)
        case .builtin(let command, let argument):
            switch command {
            case .plan: agentPromptRaw = BuiltinCommands.planPrompt(task: argument)
            case .learn: agentPromptRaw = SkillLearning.prompt(topic: argument)
            case .recipe: agentPromptRaw = recipePrompt(argument: argument) ?? prompt
            case .meeting: agentPromptRaw = BuiltinCommands.meetingPrompt(transcriptPath: meetingTranscriptPath(argument, botId: botId))
            case .goal: agentPromptRaw = BuiltinCommands.goalKickoff(goal: bot.goal ?? argument)
            default: agentPromptRaw = prompt
            }
            injected = []
        case .unknown, .help:
            agentPromptRaw = prompt
            injected = pinFolderToRun ? [] : SkillMarkdown.matching(botSkills, prompt: prompt)
        }
        let agentPrompt: String
        do {
            agentPrompt = try PrivacyFilter.applyForSend(
                agentPromptRaw,
                settings: appConfig.privacyFilter,
                logDirectory: userPersistence.root,
                logContext: "bot:\(botId)"
            )
        } catch {
            let message = error.localizedDescription
            let failMsg = ThreadMessage(
                id: progressMsg.id,
                threadId: thread.threadId,
                seq: progressMsg.seq,
                role: .bot,
                blocks: [.text(message)],
                runId: runId
            )
            if var t = threads[threadKey] {
                if let idx = t.messages.firstIndex(where: { $0.id == progressMsg.id }) {
                    t.messages[idx] = failMsg
                }
                t.run = nil
                threads[threadKey] = t
            }
            save()
            releaseWorkingFolderOverrideIfNeeded(botId: botId)
            settleQueue(botId: botId, threadKey: threadKey, runId: runId)
            return
        }
        for skill in injected { recordSkillUse(skill.id) }
        let skillText = SkillMarkdown.catalogPrompt(from: botSkills, injected: injected)
        let homePath = (try? botHome.homeURL(botId: botId).path) ?? ""
        let computerNote = self.computerNote(for: bot)
        let workingFolderNote = [
            WorkingFolder.promptNote(effectiveWorkingFolder(for: bot), scopedToRun: pinFolderToRun),
            GrantedFolders.promptNote(grantedFolders(for: bot)),
        ].filter { !$0.isEmpty }.joined(separator: "\n\n")

        var blocks: [MessageBlock] = []
        var pause: AgentPause?
        var inputTokens = 0
        var outputTokens = 0
        var promptTokens = 0
        var tokensSaved = 0
        var steps = 0
        var replyText = ""
        var failed = false
        var failureReason: String?
        var transcript: [ChatMessage] = []
        let runStartedAt = Date()
        let taint = RunTaint()
        for inherited in inheritedTaint.removeValue(forKey: botId) ?? [] { taint.mark(tool: inherited) }

        do {
            let endpoint = try await resolveEndpoint(provider: provider, modelId: selectedModel)
            let fallbacks = await resolveFallbacks(for: bot, excluding: endpoint)
            let progressId = progressMsg.id
            let stallMs = max(0, appConfig.agentStallTimeoutMs)
            var steerPoll: (@Sendable () -> [String])?
            if let inbox = runInboxes[runId] {
                steerPoll = { @Sendable in
                    let items: [QueuedSend] = inbox.drain()
                    return items.map { $0.text }
                }
            }
            var loopRequest = AgentLoopRequest(
                endpoint: endpoint,
                botName: bot.name,
                botTitle: bot.title,
                instructions: bot.instructions,
                memory: memoryText,
                sharedMemory: sharedText,
                skillCatalog: skillText,
                homePath: homePath,
                history: textHistory,
                priorMessages: priorLLM,
                prompt: agentPrompt,
                promptImageJPEGBase64: promptImageJPEGBase64,
                tools: tools,
                maxSteps: 48,
                charBudget: AgentLoopRequest.charBudget(provider: provider),
                computerNote: computerNote,
                workingFolderNote: workingFolderNote,
                stallMs: stallMs,
                roster: rosterEntries(for: bot),
                isChiefOfStaff: bot.chiefOfStaff,
                steer: steerPoll,
                goal: bot.goal ?? ""
            )
            loopRequest.fallbacks = fallbacks
            loopRequest.deferredTools = deferredTools
            loopRequest.secretNames = botSecretNames(botId: botId)
            let execute: @Sendable (String, String) async -> AgentToolCallResult = { [weak self] name, arguments in
                guard let self else {
                    return AgentToolCallResult(output: "store released")
                }
                let result = await self.guardedExecute(name: name, arguments: arguments, botId: botId, runId: runId) { finalArguments in
                    await self.executeAgentTool(
                        name: name,
                        argumentsJSON: finalArguments,
                        botId: botId,
                        depth: 0,
                        endpoint: endpoint,
                        client: client,
                        taint: taint
                    )
                }
                if UntrustedContent.taints(tool: name) { taint.mark(tool: name) }
                return result
            }
            let result: AgentLoopResult
            if bot.runtime == .agui, let agui = bot.aguiURL?.trimmingCharacters(in: .whitespacesAndNewlines), !agui.isEmpty {
                var aguiMessages: [ChatMessage] = [.system(AgentLoop.systemPrompt(for: loopRequest))]
                aguiMessages.append(contentsOf: priorLLM.filter { $0.role != "system" })
                aguiMessages.append(
                    ChatMessage(role: "user", content: agentPrompt, imageJPEGBase64: promptImageJPEGBase64)
                )
                var headers: [String: String] = [:]
                if let token = connectionSecrets["agui:\(botId)"], !token.isEmpty {
                    headers["Authorization"] = "Bearer \(token)"
                }
                result = try await AguiRuntime.run(
                    input: AguiClient.RunInput(
                        url: agui,
                        headers: headers,
                        threadId: thread.threadId,
                        runId: runId,
                        messages: aguiMessages,
                        tools: tools,
                        stallMs: stallMs
                    ),
                    onDelta: { [weak self] delta in
                        Task { @MainActor in
                            self?.appendStreamDelta(threadKey: threadKey, runId: runId, messageId: progressId, delta: delta)
                        }
                    },
                    onTool: { [weak self] name, _, toolResult in
                        Task { @MainActor in
                            self?.appendRunLog(botId: botId, kind: "tool", text: "\(name) \(String(toolResult.output.prefix(400)))")
                            self?.appendLiveTool(threadKey: threadKey, runId: runId, name: name, result: toolResult)
                        }
                    },
                    execute: execute
                )
            } else {
                result = try await AgentLoop.run(
                    client: client,
                    request: loopRequest,
                    onDelta: { [weak self] delta in
                        Task { @MainActor in
                            self?.appendStreamDelta(threadKey: threadKey, runId: runId, messageId: progressId, delta: delta)
                        }
                    },
                    onStep: { [weak self] step, max in
                        Task { @MainActor in
                            self?.setThinkingProgress(
                                threadKey: threadKey,
                                runId: runId,
                                messageId: progressId,
                                text: "thinking… step \(step)/\(max)"
                            )
                        }
                    },
                    onTool: { [weak self] name, _, toolResult in
                        Task { @MainActor in
                            self?.appendRunLog(botId: botId, kind: "tool", text: "\(name) \(String(toolResult.output.prefix(400)))")
                            self?.appendLiveTool(threadKey: threadKey, runId: runId, name: name, result: toolResult)
                        }
                    },
                    execute: execute
                )
            }
            blocks.append(contentsOf: result.blocks.filter { block in
                // Live tool messages already show status cards; keep interactive blocks only.
                switch block {
                case .card: return false
                case .ask, .approval, .choice, .connect, .component, .computer: return true
                default: return true
                }
            })
            replyText = result.text
            if let answered = result.answeredBy {
                routedNote = "answered by \(answered) after \(result.failedOver.joined(separator: ", ")) failed"
                appendRunLog(botId: botId, kind: "error", text: "Model failover: \(result.failedOver.joined(separator: " → ")) → \(answered)")
                recordAudit(type: .modelFailover, botId: botId, tool: nil, reason: "\(result.failedOver.joined(separator: ", ")) failed; \(answered) answered", allowed: true, forwarded: true)
            }
            pause = result.pause
            inputTokens = result.inputTokens
            outputTokens = result.outputTokens
            promptTokens = result.promptTokens
            tokensSaved = result.savings.estimatedTokensSaved
            if !result.savings.isEmpty {
                appendRunLog(botId: botId, kind: "context", text: result.savings.summaryLine)
            }
            steps = result.steps
            transcript = result.messages
            if result.failed {
                failed = true
                failureReason = result.failureReason
                if let reason = result.failureReason {
                    appendRunLog(botId: botId, kind: "error", text: reason)
                }
            }
        } catch is CancellationError {
            finishCancelled(botId: botId, threadKey: threadKey, runId: runId)
            runTasks.removeValue(forKey: runId)
            return
        } catch {
            failed = true
            replyText = "I couldn't complete that: \(error.localizedDescription)"
            appendRunLog(botId: botId, kind: "error", text: error.localizedDescription)
        }

        lastRunTaint[botId] = taint.isTainted ? taint.tainters : nil
        if !appConfig.otlpEndpoint.isEmpty {
            let span = TraceSpan(
                traceId: Tracing.traceId(forRun: runId),
                spanId: Tracing.runSpanId(forRun: runId),
                name: "run \(bot.name)",
                start: runStartedAt,
                end: Date(),
                ok: !failed,
                attributes: ["bot.name": bot.name, "model": "\(provider ?? "?")/\(selectedModel ?? "?")"],
                counts: ["steps": steps, "tokens.input": inputTokens, "tokens.output": outputTokens]
            )
            let exporter = traceExporter
            Task { await exporter.record(span) }
        }
        guard !Task.isCancelled else {
            finishCancelled(botId: botId, threadKey: threadKey, runId: runId)
            runTasks.removeValue(forKey: runId)
            return
        }
        guard var thread2 = threads[threadKey], thread2.run?.id == runId else { return }
        thread2.messages.removeAll { $0.id == progressMsg.id }

        if groups.contains(where: { $0.id == threadKey }) {
            replyText = "**\(bot.name):** \(replyText)"
        }
        if !replyText.isEmpty {
            blocks.insert(.text(replyText), at: 0)
        } else if blocks.isEmpty {
            blocks.append(.text("done."))
        }
        if inputTokens > 0 || outputTokens > 0 || steps > 0 {
            let modelNote = routedNote.map { " · \($0)" } ?? ""
            blocks.append(.meta("\(steps) steps · \(inputTokens) in / \(outputTokens) out\(modelNote)"))
        }

        let botMsg = ThreadMessage(
            id: Ids.new(),
            threadId: thread2.threadId,
            seq: thread2.nextSeq,
            role: .bot,
            blocks: blocks,
            runId: runId
        )
        // A heartbeat that found nothing to report leaves no trace in the chat.
        let silentHeartbeat = pause == nil && !failed
            && routineForRun(thread2.run)?.heartbeat == true
            && HeartbeatPolicy.isIdle(replyText)
        if !silentHeartbeat {
            thread2.messages.append(botMsg)
            thread2.cursor = botMsg.seq
        }
        if !transcript.isEmpty, !silentHeartbeat {
            thread2.llmMessages = transcript
        }

        if pause == .takeover {
            thread2.run?.status = .waitingTakeover
        } else if case .approval(let tool, let detail, let arguments) = pause {
            thread2.run?.status = .waitingInput
            thread2.pendingTool = PendingAgentTool(
                name: Self.approvalFunctionName(tool),
                arguments: arguments,
                tool: tool,
                detail: detail
            )
            if tool != AppStore.secretRequestTool, let waiting = bots.first(where: { $0.id == botId }), waiting.notifications {
                onApprovalNeeded?(waiting, tool, detail)
            }
        } else if pause == .waitingInput || blocks.contains(where: {
            if case .approval(_, _, .pending) = $0 { return true }
            if case .choice = $0 { return true }
            if case .ask = $0 { return true }
            return false
        }) {
            thread2.run?.status = .waitingInput
        } else if failed {
            thread2.run?.status = .failed
            thread2.run?.error = failureReason ?? replyText
            thread2.run?.completedAt = .now
            if failureReason?.contains("AGENT_STREAM_STALLED") == true {
                recordAudit(
                    type: .agentStreamStalled,
                    botId: botId,
                    tool: nil,
                    reason: replyText,
                    allowed: false,
                    forwarded: false
                )
            }
        } else {
            thread2.run?.status = .completed
            thread2.run?.completedAt = .now
        }
        threads[threadKey] = thread2
        if !silentHeartbeat {
            finalizeBotPreview(botId: botId, threadKey: threadKey, message: botMsg)
        } else if let idx = bots.firstIndex(where: { $0.id == botId }) {
            bots[idx].status = "idle"
            appendRunLog(botId: botId, kind: "heartbeat", text: "all clear")
        }
        recordRoutineOutput(botId: botId, run: thread2.run, text: replyText, failed: failed)
        flushDelegationReports()
        usage.append(
            UsageRecord(
                id: Ids.new(),
                botId: botId,
                runId: runId,
                provider: provider ?? ModelCatalog.defaultProvider,
                model: selectedModel ?? ModelCatalog.defaultModelId,
                promptTokens: promptTokens > 0 ? promptTokens : nil,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                tokensSaved: tokensSaved > 0 ? tokensSaved : nil
            )
        )
        save()
        runTasks.removeValue(forKey: runId)
        finishRoutineIfNeeded(
            botId: botId,
            threadKey: threadKey,
            status: thread2.run?.status,
            error: thread2.run?.error ?? (failed ? replyText : nil)
        )
        if !silentHeartbeat {
            announceFinished(botId: botId, text: replyText, status: thread2.run?.status)
        }
        telegramAfterRun(botId: botId, threadKey: threadKey, silent: silentHeartbeat)
        releaseWorkingFolderOverrideIfNeeded(botId: botId)
        settleQueue(botId: botId, threadKey: threadKey, runId: runId)
    }

    func runScriptedAgent(botId: String, threadKey: String, runId: String, prompt: String) async {
        await sleep(0.9)
        guard !Task.isCancelled else { return }
        guard var thread = threads[threadKey], thread.run?.id == runId else { return }

        let progressMsg = ThreadMessage(
            id: Ids.new(),
            threadId: thread.threadId,
            seq: thread.nextSeq,
            role: .bot,
            blocks: [.progress("working…")],
            runId: runId
        )
        thread.messages.append(progressMsg)
        thread.cursor = progressMsg.seq
        threads[threadKey] = thread

        await sleep(0.7)
        guard !Task.isCancelled else {
            await MainActor.run { self.finishCancelled(botId: botId, threadKey: threadKey, runId: runId) }
            return
        }
        guard var thread2 = threads[threadKey], thread2.run?.id == runId else { return }

        thread2.messages.removeAll { $0.id == progressMsg.id }

        let reply = ScriptedRuntime.reply(to: prompt, customTools: customTools, mcpServers: mcpServers)
        var blocks: [MessageBlock] = []
        var actionToRun = reply.action

        if let proposed = actionToRun,
           let bot = bots.first(where: { $0.id == botId }),
           !bot.isToolEnabled(proposed.toolId) {
            let label = AgentToolCatalog.label(for: proposed.toolId, custom: customTools, mcpServers: mcpServers)
            blocks.append(.text("that tool is disabled for me (**\(label)**). enable it in Settings → Tools."))
            actionToRun = nil
        } else {
            blocks.append(.text(reply.text))
        }

        await applyAction(actionToRun, botId: botId, blocks: &blocks, thread: &thread2, runId: runId)

        let lowerPrompt = prompt.lowercased()
        if lowerPrompt.contains("run shell") {
            let bot = bots.first(where: { $0.id == botId })
            if bot?.isToolEnabled("shell") != true {
                blocks.append(.text("shell is disabled for me. enable it in Settings → Tools."))
            } else {
                let tool = "shell.exec"
                if bot?.autoApprove == true || bot?.alwaysAllowTools.contains(tool) == true {
                    blocks.append(.approval(tool: tool, detail: prompt, status: .alwaysAllowed))
                } else {
                    blocks.append(.approval(tool: tool, detail: prompt, status: .pending))
                }
            }
        }

        if lowerPrompt.contains("choose") || lowerPrompt.contains("pick one") || lowerPrompt.contains("which option") {
            blocks.append(
                .choice(
                    question: "Which should I do?",
                    subtitle: "Pick one to continue",
                    options: [
                        ChoiceOption(id: "a", letter: "A", label: "Continue as planned"),
                        ChoiceOption(id: "b", letter: "B", label: "Try a safer approach"),
                        ChoiceOption(id: "c", letter: "C", label: "Ask me first next time"),
                    ]
                )
            )
        }

        let botMsg = ThreadMessage(
            id: Ids.new(),
            threadId: thread2.threadId,
            seq: thread2.nextSeq,
            role: .bot,
            blocks: blocks,
            runId: runId
        )
        thread2.messages.append(botMsg)
        thread2.cursor = botMsg.seq

        if case .takeover = actionToRun {
            thread2.run?.status = .waitingTakeover
        } else if case .subagent = actionToRun {
            thread2.run?.status = .running
        } else if blocks.contains(where: {
            if case .approval(_, _, .pending) = $0 { return true }
            if case .choice = $0 { return true }
            return false
        }) {
            thread2.run?.status = .waitingInput
        } else {
            thread2.run?.status = .completed
            thread2.run?.completedAt = .now
        }
        threads[threadKey] = thread2
        finalizeBotPreview(botId: botId, threadKey: threadKey, message: botMsg)

        usage.append(
            UsageRecord(
                id: Ids.new(),
                botId: botId,
                runId: runId,
                provider: modelProvider ?? ModelCatalog.defaultProvider,
                model: modelId ?? ModelCatalog.defaultModelId,
                promptTokens: 12,
                inputTokens: 12,
                outputTokens: 40
            )
        )
        save()

        if case .subagent(let task) = actionToRun {
            await completeSubagent(botId: botId, threadKey: threadKey, runId: runId, messageId: botMsg.id, task: task)
        }

        runTasks.removeValue(forKey: runId)
        announceFinished(botId: botId, text: botMsg.firstText, status: thread2.run?.status)
        telegramAfterRun(botId: botId, threadKey: threadKey)
        releaseWorkingFolderOverrideIfNeeded(botId: botId)
        settleQueue(botId: botId, threadKey: threadKey, runId: runId)
    }

    func setThinkingProgress(threadKey: String, runId: String, messageId: String, text: String) {
        guard var thread = threads[threadKey], thread.run?.id == runId else { return }
        guard let idx = thread.messages.firstIndex(where: { $0.id == messageId }) else { return }
        if case .progress(let existing) = thread.messages[idx].blocks.first {
            if existing.hasPrefix("thinking…") || existing.isEmpty {
                thread.messages[idx].blocks = [.progress(text)]
                threads[threadKey] = thread
            }
        }
    }

    func appendStreamDelta(threadKey: String, runId: String, messageId: String, delta: String) {
        guard var thread = threads[threadKey], thread.run?.id == runId else { return }
        guard let idx = thread.messages.firstIndex(where: { $0.id == messageId }) else { return }
        var text = ""
        if case .progress(let existing) = thread.messages[idx].blocks.first {
            if existing.hasPrefix("thinking…") {
                text = ""
            } else {
                text = existing
            }
        } else if case .text(let existing) = thread.messages[idx].blocks.first {
            text = existing
        }
        text += delta
        thread.messages[idx].blocks = [.progress(text)]
        threads[threadKey] = thread
    }

    func finalizeBotPreview(botId: String, threadKey: String, message: ThreadMessage) {
        let status = threads[threadKey]?.run?.status
        if let idx = bots.firstIndex(where: { $0.id == botId }) {
            let preview = message.firstText
            bots[idx].preview = preview.count > 80 ? String(preview.prefix(80)) + "…" : preview
            if status?.isActive != true && status != .waitingInput && status != .waitingTakeover {
                bots[idx].status = "idle"
                releaseWorkingFolderOverrideIfNeeded(botId: botId)
            }
            bots[idx].updatedAt = .now
            if activeBotId != botId {
                bots[idx].unread = true
            }
        }
        if let gIdx = groups.firstIndex(where: { $0.id == threadKey }) {
            groups[gIdx].preview = message.firstText
        }
    }
}
