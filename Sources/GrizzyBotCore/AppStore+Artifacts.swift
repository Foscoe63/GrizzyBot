import Foundation
import Observation

// Split out of Store.swift by its MARK sections; behavior is unchanged.
extension AppStore {
    // MARK: - Artifacts

    public func reloadArtifacts() {
        artifacts = artifactStore.list()
    }

    public func artifact(id: String) -> ArtifactRecord? {
        artifacts.first { $0.id == id } ?? artifactStore.load(id: id)
    }

    public var activeArtifact: ArtifactRecord? {
        activeArtifactId.flatMap { artifact(id: $0) }
    }

    /// Content for the panel: the selected saved version, else the current one.
    public func artifactContent(_ record: ArtifactRecord) -> String {
        guard let index = artifactVersionIndex,
              record.versions.indices.contains(index)
        else { return record.content }
        return record.versions[index].content
    }

    public func openArtifact(id: String) {
        reloadArtifacts()
        guard artifact(id: id) != nil else { return }
        activeArtifactId = id
        artifactVersionIndex = nil
        artifactRevision += 1
        openPanel(.artifact)
    }

    public func toggleArtifactPanel() {
        if panel == .artifact {
            panel = nil
            return
        }
        reloadArtifacts()
        if activeArtifactId == nil || artifact(id: activeArtifactId ?? "") == nil {
            activeArtifactId = artifacts.first?.id
        }
        artifactVersionIndex = nil
        openPanel(.artifact)
    }

    public func showArtifactVersion(_ index: Int?) {
        artifactVersionIndex = index
        artifactRevision += 1
    }

    /// Artifact id a skill is edited under. Namespaced so a skill's document
    /// cannot collide with an artifact a bot made for something else.
    public static func skillArtifactId(_ skillId: String) -> String {
        ArtifactStore.slug("skill-\(skillId)")
    }

    /// Opens a skill's SKILL.md in the artifact panel — the full file, frontmatter
    /// included, so description, keywords, and allowed-tools are editable too.
    ///
    /// The artifact is reseeded from the library every time it is opened. The
    /// SKILL.md on disk is the original; a stale document that quietly shadowed it
    /// would be the worst kind of bug here, because you would be editing a copy of
    /// something you had already changed elsewhere.
    @discardableResult
    public func openSkillInEditor(_ skillId: String) -> ArtifactRecord? {
        guard let skill = skills.first(where: { $0.id == skillId }) else { return nil }
        let id = Self.skillArtifactId(skill.id)
        let content = SkillMarkdown.render(skill)

        var record: ArtifactRecord?
        if let existing = artifactStore.load(id: id) {
            // `rewrite` always appends a version, so reseeding an unchanged
            // document would add one on every open.
            record = existing.content == content
                ? existing
                : try? artifactStore.rewrite(id: id, content: content, title: nil)
        } else {
            record = try? artifactStore.create(
                id: id,
                title: "Skill: \(skill.id)",
                kind: .markdown,
                language: nil,
                content: content,
                botId: activeBotId
            )
        }
        guard var saved = record else { return nil }

        if saved.linkedSkillId != skill.id {
            saved = (try? artifactStore.link(id: id, skillId: skill.id)) ?? saved
        }

        skillsOpen = false
        reloadArtifacts()
        activeArtifactId = saved.id
        artifactVersionIndex = nil
        artifactRevision += 1
        openPanel(.artifact)
        return saved
    }

    /// Creates an artifact by hand from the panel. Bots reach the same store
    /// through `artifact_create`; this exists so an artifact is not something
    /// only a bot can start.
    @discardableResult
    public func createArtifact(
        title: String,
        kind: ArtifactKind,
        language: String? = nil,
        content: String? = nil
    ) -> ArtifactRecord? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = content ?? kind.starterContent
        guard let record = try? artifactStore.create(
            id: "",
            title: trimmed.isEmpty ? "Untitled" : trimmed,
            kind: kind,
            language: language,
            content: body,
            botId: activeBotId
        ) else { return nil }

        if let bot = activeBot {
            _ = mirrorArtifact(
                record,
                botId: bot.id,
                path: WorkingFolder.resolve(record.fileName, workingFolder: effectiveWorkingFolder(for: bot))
            )
        }
        reloadArtifacts()
        activeArtifactId = record.id
        artifactVersionIndex = nil
        artifactRevision += 1
        return artifact(id: record.id) ?? record
    }

    /// Saves an edit made in the panel as a new version.
    ///
    /// `baseVersionCount` is what the editor opened against. Bots and routines
    /// share this store and can write while the editor is open, so a save that
    /// lands on top of newer work says so — the history keeps every version, but
    /// silently superseding a bot's edit is the kind of thing you only discover
    /// much later.
    @discardableResult
    public func saveArtifactEdit(
        id: String,
        content: String,
        baseVersionCount: Int
    ) -> ArtifactSaveOutcome {
        guard let current = artifactStore.load(id: id) else {
            return .failed(ArtifactError.notFound(id).localizedDescription)
        }
        guard content != current.content else { return .unchanged }

        let arrived = max(0, current.versions.count - baseVersionCount)

        // A skill document is refused before it is saved, not after. Storing a
        // version the library rejected would leave the panel showing a skill the
        // bots cannot see.
        var editedSkill: AgentSkill?
        if let skillId = current.linkedSkillId {
            do {
                editedSkill = try SkillMarkdown.parse(content, fallbackId: skillId, source: .user)
            } catch {
                return .failed(error.localizedDescription)
            }
        }

        let saved: ArtifactRecord
        do {
            saved = try artifactStore.rewrite(id: id, content: content, title: nil)
        } catch {
            return .failed(error.localizedDescription)
        }

        if let editedSkill {
            do {
                try installUserSkill(editedSkill)
            } catch {
                return .failed(error.localizedDescription)
            }
        } else if let bot = activeBot {
            // Skill documents are not mirrored: the SKILL.md in the library is
            // the file, and a second copy in the working folder would be the one
            // people edit by mistake.
            _ = mirrorArtifact(
                saved,
                botId: bot.id,
                path: WorkingFolder.resolve(saved.fileName, workingFolder: effectiveWorkingFolder(for: bot))
            )
        }
        reloadArtifacts()
        activeArtifactId = saved.id
        artifactVersionIndex = nil
        artifactRevision += 1
        return arrived > 0 ? .savedOverNewerVersions(arrived) : .saved
    }

    public func deleteArtifact(id: String) {
        guard let removed = try? artifactStore.delete(id: id) else { return }
        reloadArtifacts()
        if activeArtifactId == removed.id {
            activeArtifactId = artifacts.first?.id
            artifactVersionIndex = nil
            if activeArtifactId == nil, panel == .artifact { panel = nil }
        }
        artifactRevision += 1
    }

    /// Refreshes the panel after a tool wrote an artifact. Headless routine
    /// ticks stay headless — the artifact is still created and mirrored, it
    /// just does not yank a panel open with nobody watching.
    func showArtifact(_ id: String) {
        reloadArtifacts()
        activeArtifactId = id
        artifactVersionIndex = nil
        artifactRevision += 1
        if !headlessRoutineTick {
            openPanel(.artifact)
        }
    }

    /// Writes the artifact into the run's working folder (or the bot home when
    /// none is set). A failed mirror is reported but never fails the tool: the
    /// artifact itself is already saved, and losing it to a disk error would be
    /// the worse outcome.
    func mirrorArtifact(_ record: ArtifactRecord, botId: String, path: String) -> ArtifactMirror {
        do {
            try botHome.writeFlexible(botId: botId, path: path, content: record.content)
            if !BotHomeStore.isHostPath(path) {
                upsertFile(path: path, content: record.content)
                refreshFilesMirror(botId: botId)
            }
            let noted = (try? artifactStore.noteMirror(id: record.id, path: path)) ?? record
            return ArtifactMirror(record: noted, path: path, error: nil)
        } catch {
            return ArtifactMirror(record: record, path: nil, error: error.localizedDescription)
        }
    }

    func artifactResult(_ mirror: ArtifactMirror, verb: String) -> AgentToolCallResult {
        let record = mirror.record
        var lines = [
            CardLine(k: verb.lowercased(), v: record.title),
            CardLine(k: "id", v: record.id),
            CardLine(k: "type", v: record.summary),
        ]
        var output = "\(verb) artifact \(record.title) (\(record.id)) — \(record.summary)."
        if let path = mirror.path {
            lines.append(CardLine(k: "file", v: path))
            output += " Mirrored to \(path)."
        }
        if let error = mirror.error {
            lines.append(CardLine(k: "file", v: "not mirrored: \(error)"))
            output += " The artifact saved, but writing the file copy failed: \(error)."
        }
        return AgentToolCallResult(
            output: output,
            blocks: [
                .artifact(
                    id: record.id,
                    title: record.title,
                    kind: record.kind,
                    summary: record.summary,
                    deleted: false
                ),
                .card(lines: lines),
            ]
        )
    }

    public func toggleCanvasPanel() {
        if panel == .canvas {
            panel = nil
        } else {
            reloadCanvases()
            openPanel(.canvas)
        }
    }

    public func openCanvas(id: String?, placingScreenshotFrom botId: String? = nil) {
        reloadCanvases()
        let screenshotBot = botId ?? activeBotId
        let hasShot = screenshotBot.map { canvasImageData(botId: $0, path: "") != nil } ?? false
        if let id, let match = canvasBoard.load(id: id) {
            activeCanvasId = match.id
        } else if hasShot {
            if let empty = canvases.first(where: { $0.images.isEmpty }) {
                activeCanvasId = empty.id
            } else {
                activeCanvasId = createCanvas(title: "Screenshot").id
            }
        } else if let first = canvases.first {
            activeCanvasId = first.id
        } else {
            activeCanvasId = createCanvas(title: "Untitled").id
        }
        if hasShot, let screenshotBot, let board = activeCanvas(), board.images.isEmpty {
            _ = placeActiveScreenshot(botId: screenshotBot)
        }
        canvasOpen = true
        if panel != .canvas {
            openPanel(.canvas)
        }
    }

    public func closeCanvasOverlay() {
        canvasOpen = false
    }

    @discardableResult
    public func createCanvas(title: String) -> CanvasRecord {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let record = CanvasRecord(title: name.isEmpty ? "Untitled" : name)
        let saved = (try? canvasBoard.save(record)) ?? record
        reloadCanvases()
        activeCanvasId = saved.id
        canvasRevision += 1
        return saved
    }

    @discardableResult
    public func saveCanvas(_ record: CanvasRecord) -> CanvasRecord? {
        let saved = try? canvasBoard.save(record)
        reloadCanvases()
        if let saved {
            activeCanvasId = saved.id
        }
        canvasRevision += 1
        return saved
    }

    public func deleteCanvas(id: String) {
        try? canvasBoard.delete(id: id)
        if activeCanvasId == id {
            activeCanvasId = canvases.first(where: { $0.id != id })?.id
            if activeCanvasId == nil { canvasOpen = false }
        }
        reloadCanvases()
        canvasRevision += 1
    }

    public func previewURL(forCanvas id: String) -> URL {
        canvasBoard.previewURL(id: id)
    }

    public func canvasImageURL(id: String, fileName: String) -> URL {
        canvasBoard.imageURL(id: id, fileName: fileName)
    }

    public func activeCanvas() -> CanvasRecord? {
        activeCanvasId.flatMap { canvasBoard.load(id: $0) } ?? canvases.first
    }

    @discardableResult
    public func placeActiveScreenshot(botId: String) -> CanvasRecord? {
        guard let jpeg = canvasImageData(botId: botId, path: "") else { return nil }
        let title = activeCanvas()?.title ?? "Screenshot"
        let saved = try? canvasBoard.placeImage(canvasId: activeCanvasId, title: title, jpeg: jpeg)
        reloadCanvases()
        if let saved {
            activeCanvasId = saved.id
        }
        canvasRevision += 1
        return saved
    }

    func canvasImageData(botId: String, path: String) -> Data? {
        if !path.isEmpty {
            // Resolve like every other file tool: a relative path means the
            // run's working folder when one is set, and the bot home
            // otherwise. Reading only the home is why an image the bot had
            // just written to its working folder came back "No image to
            // place."
            let bot = bots.first(where: { $0.id == botId })
            let resolved = bot.map { WorkingFolder.resolve(path, workingFolder: effectiveWorkingFolder(for: $0)) } ?? path
            var candidates: [URL] = []
            if BotHomeStore.isHostPath(resolved) {
                candidates.append(URL(fileURLWithPath: BotHomeStore.expandPath(resolved)))
            }
            if let home = try? botHome.homeURL(botId: botId) {
                candidates.append(home.appendingPathComponent(path))
            }
            for url in candidates {
                if let data = try? Data(contentsOf: url), !data.isEmpty { return data }
            }
            return nil
        }
        if let home = try? botHome.homeURL(botId: botId) {
            let shot = home.appendingPathComponent(".computer/screen.jpg")
            if let data = try? Data(contentsOf: shot), !data.isEmpty { return data }
        }
        return nil
    }

    func autoBootIfNeeded(botId: String) {
        guard let computer = computers[botId] else { return }
        if computer.state == .booting || computer.state == .suspended { return }
        if computer.state == .running && computer.screenAvailable { return }
        boot(botId: botId, force: true)
    }

    public func boot(botId: String, force: Bool) {
        guard var computer = computers[botId] else { return }
        if !force, computer.state == .running || computer.state == .booting { return }
        computer.state = .booting
        computer.screenAvailable = false
        computers[botId] = computer
        booting = true
        save()

        bootTasks[botId]?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            if let home = try? self.botHome.homeURL(botId: botId) {
                let bot = self.bots.first(where: { $0.id == botId })
                let mode = (bot?.computerMode == .auto ? self.appConfig.defaultComputerMode : bot?.computerMode) ?? .auto
                await self.computerRuntime?.setSession(
                    botId: botId,
                    thisMac: mode == .thisMac,
                    persistent: mode != .off
                )
                await self.computerRuntime?.attach(botId: botId, homeURL: home)
                if let snap = await self.computerRuntime?.snapshot(botId: botId) {
                    let url = home.appendingPathComponent(".computer/screen.jpg")
                    try? FileManager.default.createDirectory(
                        at: url.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try? snap.jpeg.write(to: url)
                }
            }
            await self.sleep(0.2)
            guard !Task.isCancelled else { return }
            guard var c = self.computers[botId] else { return }
            c.state = .running
            c.screenAvailable = true
            self.computers[botId] = c
            self.booting = false
            self.save()
            self.bootTasks.removeValue(forKey: botId)
        }
        bootTasks[botId] = task
    }

    public func takeControl(botId: String) {
        guard var computer = computers[botId] else { return }
        computer.controlHolder = .user
        if computer.state == .suspended {
            computer.state = .running
            computer.screenAvailable = true
        }
        computers[botId] = computer
        recordAudit(
            type: .computerControlTaken,
            botId: botId,
            tool: nil,
            reason: "Person took control.",
            allowed: true,
            forwarded: true
        )
        save()
    }

    /// Mirrors rakazo `releaseComputer`: release control and close the full-window overlay.
    public func release(botId: String) {
        guard var computer = computers[botId] else { return }
        computer.controlHolder = .bot
        computers[botId] = computer
        computerOpen = false
        canvasOpen = false
        recordAudit(
            type: .computerControlReleased,
            botId: botId,
            tool: nil,
            reason: "Person released control.",
            allowed: true,
            forwarded: true
        )
        save()
    }

    /// Keep-alive while the computer panel or overlay is open (rakazo `computer.heartbeat`).
    public func heartbeat(botId: String) {
        guard var computer = computers[botId], computer.state == .running else { return }
        computer.lastHeartbeatAt = .now
        computers[botId] = computer
    }
}
