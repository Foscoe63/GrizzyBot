import AppKit
import GrizzyBotCore
import Observation
import SwiftUI

/// What is on disk for Splash. Splash itself is a separate server, so this is
/// discovery and a ready-made `splash serve` command rather than a runtime.
@Observable
@MainActor
final class LocalSplashController {
    var discovered: [SplashLocalModel] = []
    var customFolders: [String] = SplashSettingsStore.customFolders
    var scansHuggingFaceCache = SplashSettingsStore.scansHuggingFaceCache
    var scansLMStudio = SplashSettingsStore.scansLMStudio
    var scanning = false
    var scanNote: String?

    func rescan() async {
        scanning = true
        scanNote = nil
        let report = await Task.detached(priority: .userInitiated) {
            SplashSettingsStore.scan()
        }.value
        discovered = report.models
        scanning = false
        if report.rootsScanned.isEmpty {
            scanNote = "No model folders were found to scan. Add the folder your models live in."
        } else if report.models.isEmpty {
            scanNote = "No Splash-compatible models (Qwen3.8, Qwen3.6, Splash packages, Bonsai) in \(report.rootsScanned.count) folder\(report.rootsScanned.count == 1 ? "" : "s")."
        }
    }

    func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan This Folder"
        panel.message = "Choose a folder of models, laid out as publisher/repo like LM Studio's."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        SplashSettingsStore.addCustomFolder(url.path)
        customFolders = SplashSettingsStore.customFolders
        Task { await rescan() }
    }

    func removeFolder(_ path: String) {
        SplashSettingsStore.removeCustomFolder(path)
        customFolders = SplashSettingsStore.customFolders
        Task { await rescan() }
    }

    func setScansHuggingFaceCache(_ on: Bool) {
        scansHuggingFaceCache = on
        SplashSettingsStore.scansHuggingFaceCache = on
        Task { await rescan() }
    }

    func setScansLMStudio(_ on: Bool) {
        scansLMStudio = on
        SplashSettingsStore.scansLMStudio = on
        Task { await rescan() }
    }
}

/// The Splash panel: the same folder settings as Local MLX, applied to models
/// Splash can serve.
struct LocalSplashView: View {
    @Binding var selectedModelId: String
    var onModelsChanged: ([LocalModelRef]) -> Void

    @State private var controller = LocalSplashController()
    @State private var copied = false

    private var selected: SplashLocalModel? {
        controller.discovered.first { $0.id == selectedModelId }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if controller.discovered.isEmpty && !controller.scanning {
                Text(controller.scanNote ?? "No models found yet.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
            } else {
                modelList
            }
            sourceToggles
            if !controller.customFolders.isEmpty { customFolderList }
            if !controller.discovered.isEmpty { serveCommand }
        }
        .task {
            await controller.rescan()
            publish()
        }
        .onChange(of: controller.discovered) { _, _ in publish() }
    }

    private func publish() {
        onModelsChanged(controller.discovered.map { LocalModelRef(id: $0.id, label: "\($0.id) — \($0.summary)") })
    }

    private var header: some View {
        HStack {
            Text("Splash models on this Mac")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textBright)
            Spacer()
            if controller.scanning { ProgressView().controlSize(.small) }
            GrizzyButton(title: "Rescan", variant: .outline, size: .sm) {
                Task { await controller.rescan() }
            }
            GrizzyButton(title: "Add Folder…", variant: .outline, size: .sm) {
                controller.addFolder()
            }
        }
    }

    private var modelList: some View {
        VStack(spacing: 0) {
            ForEach(Array(controller.discovered.enumerated()), id: \.element.id) { index, model in
                Button {
                    selectedModelId = model.id
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: selectedModelId == model.id ? "largecircle.fill.circle" : "circle")
                            .font(.system(size: 13))
                            .foregroundStyle(selectedModelId == model.id ? Theme.orange : Theme.textSecondary)
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
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(selectedModelId == model.id ? Theme.bgSelectedRow : Color.clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

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
            Toggle("Hugging Face cache", isOn: Binding(
                get: { controller.scansHuggingFaceCache },
                set: { controller.setScansHuggingFaceCache($0) }
            ))
            Toggle("LM Studio", isOn: Binding(
                get: { controller.scansLMStudio },
                set: { controller.setScansLMStudio($0) }
            ))
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

    private var serveCommand: some View {
        let command = SplashSettingsStore.serveCommand(for: selected, fallbackId: selectedModelId)
        return VStack(alignment: .leading, spacing: 6) {
            Text("Start Splash with this model")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textBright)
            HStack(spacing: 8) {
                Text(command)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.textBright)
                    .textSelection(.enabled)
                    .lineLimit(2)
                Spacer()
                GrizzyButton(title: copied ? "Copied" : "Copy", variant: .outline, size: .sm) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        copied = false
                    }
                }
            }
            .padding(10)
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Theme.borderInputsDark, lineWidth: 1)
            }
            Text("Splash looks models up by Hugging Face id in its own cache, so it may download a copy rather than read a folder in place. Once it prints Ready, Refresh models above.")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textSecondary)
        }
    }
}
