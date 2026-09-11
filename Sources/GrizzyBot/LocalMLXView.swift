import AppKit
import GrizzyBotCore
import Observation
import SwiftUI

/// UI state for the Local MLX panel: what is on disk, what the Hub search
/// returned, and what is downloading right now.
@Observable
@MainActor
final class LocalMLXController {
    var discovered: [MLXLocalModel] = []
    var skipped: [MLXSkippedBundle] = []
    var customFolders: [String] = MLXSettingsStore.customFolders
    var scansHuggingFaceCache = MLXSettingsStore.scansHuggingFaceCache
    var scansLMStudio = MLXSettingsStore.scansLMStudio
    var scanning = false
    var scanError: String?

    var query = ""
    var results: [MLXHubModel] = []
    var searching = false
    var searchError: String?
    /// Access token for gated repos and higher rate limits. Optional.
    var hubToken = ""

    var downloads: [String: MLXDownloadProgress] = [:]
    private var observerToken: UUID?

    var activeDownloadCount: Int {
        downloads.values.filter { !$0.phase.isTerminal }.count
    }

    func start() async {
        guard observerToken == nil else { return }
        observerToken = await MLXModelDownloader.shared.addObserver { [weak self] progress in
            Task { @MainActor [weak self] in
                self?.downloads[progress.repoId] = progress
                if case .completed = progress.phase {
                    await self?.rescan()
                }
            }
        }
        await rescan()
    }

    func stop() async {
        guard let token = observerToken else { return }
        observerToken = nil
        await MLXModelDownloader.shared.removeObserver(token)
    }

    // MARK: - Disk

    func rescan() async {
        scanning = true
        scanError = nil
        let report = await Task.detached(priority: .userInitiated) {
            MLXSettingsStore.scan()
        }.value
        discovered = report.models
        skipped = report.skipped
        scanning = false
        if report.models.isEmpty && report.rootsScanned.isEmpty {
            scanError = "No model folders were found to scan. Add one below, or download a model from Hugging Face."
        }
    }

    func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan This Folder"
        panel.message = "Choose a folder holding MLX model bundles (a folder with config.json, a tokenizer, and .safetensors weights — or a folder of those)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        MLXSettingsStore.addCustomFolder(url.path)
        customFolders = MLXSettingsStore.customFolders
        Task { await rescan() }
    }

    func removeFolder(_ path: String) {
        MLXSettingsStore.removeCustomFolder(path)
        customFolders = MLXSettingsStore.customFolders
        Task { await rescan() }
    }

    func setScansHuggingFaceCache(_ on: Bool) {
        scansHuggingFaceCache = on
        MLXSettingsStore.scansHuggingFaceCache = on
        Task { await rescan() }
    }

    func setScansLMStudio(_ on: Bool) {
        scansLMStudio = on
        MLXSettingsStore.scansLMStudio = on
        Task { await rescan() }
    }

    // MARK: - Hub

    func search() async {
        searching = true
        searchError = nil
        do {
            let token = hubToken.trimmingCharacters(in: .whitespacesAndNewlines)
            results = try await MLXHuggingFaceService.shared.search(
                query: query,
                token: token.isEmpty ? nil : token
            )
            if results.isEmpty {
                searchError = "No MLX models matched that search."
            }
        } catch {
            results = []
            searchError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        searching = false
    }

    func download(_ repoId: String) {
        let token = hubToken.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            // Failures land in `downloads` through the progress observer, so
            // there is nothing to surface here that the row does not show.
            _ = try? await MLXModelDownloader.shared.download(
                repoId: repoId,
                token: token.isEmpty ? nil : token
            )
        }
    }

    func cancel(_ repoId: String) {
        Task { await MLXModelDownloader.shared.cancel(repoId: repoId) }
    }

    func delete(_ model: MLXLocalModel) {
        Task {
            try? await MLXModelDownloader.shared.removeDownloaded(repoId: model.id)
            await rescan()
        }
    }

    /// True when the model lives in GrizzyBot's own downloads folder, and so
    /// is ours to delete. Models found in the HF cache or LM Studio are not.
    func isRemovable(_ model: MLXLocalModel) -> Bool {
        model.source == "Downloaded in GrizzyBot"
    }

    func isOnDisk(_ repoId: String) -> Bool {
        discovered.contains { $0.id.caseInsensitiveCompare(repoId) == .orderedSame }
    }
}

/// The Local MLX provider panel: models already on this Mac, plus Hugging Face
/// search and download.
struct LocalMLXView: View {
    @Binding var selectedModelId: String
    var onModelsChanged: ([LocalModelRef]) -> Void

    @State private var controller = LocalMLXController()
    @State private var showSkipped = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let reason = MLXRuntime.unavailableReason {
                banner(reason)
            }
            onThisMac
            huggingFace
        }
        .task {
            await controller.start()
            publish()
        }
        .onDisappear {
            Task { await controller.stop() }
        }
        .onChange(of: controller.discovered) { _, _ in publish() }
    }

    private func publish() {
        onModelsChanged(controller.discovered.map(MLXProvider.modelRef(for:)))
        // Keep a selection that no longer exists from silently pointing at a
        // deleted folder.
        if selectedModelId.isEmpty
            || !controller.discovered.contains(where: { $0.path == selectedModelId }) {
            selectedModelId = controller.discovered.first?.path ?? ""
        }
    }

    // MARK: - Sections

    private func banner(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(Theme.orange)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.bgCard)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Theme.orange.opacity(0.35), lineWidth: 1)
            }
    }

    private var onThisMac: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Models on this Mac")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textBright)
                Spacer()
                if controller.scanning {
                    ProgressView().controlSize(.small)
                }
                GrizzyButton(title: "Rescan", variant: .outline, size: .sm) {
                    Task { await controller.rescan() }
                }
                GrizzyButton(title: "Add Folder…", variant: .outline, size: .sm) {
                    controller.addFolder()
                }
            }

            if controller.discovered.isEmpty && !controller.scanning {
                Text("No MLX models found yet. Add a folder you already keep models in, or download one from Hugging Face below.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
            } else {
                modelList
            }

            sourceToggles

            if !controller.customFolders.isEmpty {
                customFolderList
            }

            if let error = controller.scanError {
                Text(error)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.orange)
            }

            if !controller.skipped.isEmpty {
                skippedDisclosure
            }
        }
    }

    private var modelList: some View {
        VStack(spacing: 0) {
            ForEach(Array(controller.discovered.enumerated()), id: \.element.path) { index, model in
                HStack(spacing: 10) {
                    Button {
                        selectedModelId = model.path
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: selectedModelId == model.path
                                  ? "largecircle.fill.circle"
                                  : "circle")
                                .font(.system(size: 13))
                                .foregroundStyle(selectedModelId == model.path
                                                 ? Theme.orange
                                                 : Theme.textSecondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.id)
                                    .font(.system(size: 14))
                                    .foregroundStyle(Theme.textBright)
                                Text(model.summary)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if controller.isRemovable(model) {
                        Button {
                            controller.delete(model)
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .buttonStyle(.plain)
                        .help("Delete this download from GrizzyBot's models folder")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(selectedModelId == model.path ? Theme.bgSelectedRow : Color.clear)

                if index < controller.discovered.count - 1 {
                    Divider().background(Theme.borderListRows)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(Theme.borderInputsDark, lineWidth: 1)
        }
    }

    private var sourceToggles: some View {
        HStack(spacing: 18) {
            Toggle(
                "Hugging Face cache",
                isOn: Binding(
                    get: { controller.scansHuggingFaceCache },
                    set: { controller.setScansHuggingFaceCache($0) }
                )
            )
            Toggle(
                "LM Studio",
                isOn: Binding(
                    get: { controller.scansLMStudio },
                    set: { controller.setScansLMStudio($0) }
                )
            )
            Spacer()
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .font(.system(size: 12.5))
        .foregroundStyle(Theme.textSecondary)
    }

    private var customFolderList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(controller.customFolders, id: \.self) { folder in
                HStack(spacing: 8) {
                    Text(folder)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button {
                        controller.removeFolder(folder)
                    } label: {
                        Image(systemName: "minus.circle")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .help("Stop scanning this folder")
                }
            }
        }
    }

    private var skippedDisclosure: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                showSkipped.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: showSkipped ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10))
                    Text("\(controller.skipped.count) folder\(controller.skipped.count == 1 ? "" : "s") skipped")
                        .font(.system(size: 12.5))
                }
                .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)

            if showSkipped {
                ForEach(controller.skipped) { entry in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.path)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("\(entry.reason.title) — \(entry.detail)")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.orange.opacity(0.8))
                    }
                }
            }
        }
    }

    private var huggingFace: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Download from Hugging Face")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textBright)

            HStack(spacing: 8) {
                TextField("Search MLX models (e.g. qwen3 4bit)", text: $controller.query)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textBright)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Theme.borderInputsDark, lineWidth: 1)
                    }
                    .onSubmit { Task { await controller.search() } }

                GrizzyButton(
                    title: controller.searching ? "Searching…" : "Search",
                    variant: .outline,
                    size: .sm,
                    disabled: controller.searching
                ) {
                    Task { await controller.search() }
                }
            }

            GrizzyField(
                label: "Hugging Face token (optional)",
                placeholder: "hf_… — needed for gated repos",
                text: $controller.hubToken,
                style: .dark,
                secure: true
            )

            if let error = controller.searchError {
                Text(error)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.orange)
            }

            if !controller.results.isEmpty {
                resultList
            }
        }
    }

    private var resultList: some View {
        VStack(spacing: 0) {
            ForEach(Array(controller.results.enumerated()), id: \.element.id) { index, model in
                resultRow(model)
                if index < controller.results.count - 1 {
                    Divider().background(Theme.borderListRows)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(Theme.borderInputsDark, lineWidth: 1)
        }
    }

    @ViewBuilder
    private func resultRow(_ model: MLXHubModel) -> some View {
        let progress = controller.downloads[model.id]
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.id)
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textBright)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(subtitle(for: model))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                downloadControl(model: model, progress: progress)
            }

            if let progress, !progress.phase.isTerminal {
                ProgressView(value: progress.fraction)
                    .progressViewStyle(.linear)
                Text(progress.statusText)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
            } else if let progress, case .failed(let message) = progress.phase {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.orange)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    @ViewBuilder
    private func downloadControl(model: MLXHubModel, progress: MLXDownloadProgress?) -> some View {
        if controller.isOnDisk(model.id) {
            Text("On disk")
                .font(.system(size: 12))
                .foregroundStyle(Theme.green)
        } else if let progress, !progress.phase.isTerminal {
            GrizzyButton(title: "Cancel", variant: .outline, size: .sm) {
                controller.cancel(model.id)
            }
        } else {
            GrizzyButton(title: "Download", variant: .outline, size: .sm) {
                controller.download(model.id)
            }
        }
    }

    private func subtitle(for model: MLXHubModel) -> String {
        var parts: [String] = []
        if let quantization = model.quantizationHint { parts.append(quantization) }
        if model.downloads > 0 {
            parts.append("\(formatCount(model.downloads)) downloads")
        }
        if model.likes > 0 { parts.append("\(formatCount(model.likes)) likes") }
        if let size = model.sizeBytes {
            parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        }
        return parts.isEmpty ? model.owner : parts.joined(separator: " · ")
    }

    private func formatCount(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fk", Double(value) / 1_000) }
        return String(value)
    }
}
