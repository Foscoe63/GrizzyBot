import AppKit
import GrizzyBotCore
import SwiftUI

/// Shared model picker: cloud providers + local/LAN (Ollama, LM Studio, vMLX, oMLX).
struct ModelConnectView: View {
    var onContinue: (() -> Void)?
    var onSkip: (() -> Void)?
    var showSkip: Bool = true
    var continueLabel: String = "Continue"

    @Environment(AppStore.self) private var store

    @State private var search = ""
    @State private var selectedProvider = ModelCatalog.defaultProvider
    @State private var selectedModelId = ModelCatalog.defaultModelId
    @State private var apiKey = ""
    @State private var baseUrl = ""
    @State private var customModels: [LocalModelRef] = []
    @State private var manualModel = ""
    @State private var lanHost = ""
    @State private var lanHints: [String] = []
    @State private var probing = false
    @State private var discovering = false
    @State private var modelError: String?
    @State private var signingIn = false
    @State private var userCode: String?
    @State private var waitingSignIn = false

    private var isLocal: Bool { LocalProviders.isLocal(selectedProvider) }

    private var filteredProviders: [CatalogEntry] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let providers = ModelCatalog.providers
        guard !q.isEmpty else { return providers }
        return providers.filter { entry in
            let hay = [
                entry.provider,
                entry.providerName ?? "",
                entry.label,
                entry.id,
                entry.billing,
                entry.oauthLabel ?? "",
                entry.kind.rawValue,
            ].joined(separator: " ").lowercased()
            return hay.contains(q)
        }
    }

    private var providerEntry: CatalogEntry? {
        ModelCatalog.providers.first(where: { $0.provider == selectedProvider })
    }

    private var modelsForProvider: [CatalogEntry] {
        var byId: [String: CatalogEntry] = [:]
        for entry in ModelCatalog.models(forProvider: selectedProvider) {
            if isLocal && entry.id.hasSuffix("/default") { continue }
            byId[entry.id] = entry
        }
        for model in customModels {
            byId[model.id] = CatalogEntry(
                provider: selectedProvider,
                providerName: providerEntry?.providerName,
                id: model.id,
                label: model.label,
                billing: providerEntry?.billing ?? "",
                auth: .apiKey,
                kind: isLocal ? .local : .cloud,
                defaultBaseUrl: baseUrl.isEmpty ? providerEntry?.defaultBaseUrl : baseUrl,
                supportsBaseUrl: true
            )
        }
        return Array(byId.values).sorted {
            $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
        }
    }

    private var selectedEntry: CatalogEntry? {
        modelsForProvider.first(where: { $0.id == selectedModelId }) ?? modelsForProvider.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Connect a model")
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(Theme.textBrightAlt)

            Text("Paste an API key, sign in with ChatGPT / Copilot / SuperGrok, or point at a local provider (Ollama, LM Studio, vMLX, oMLX) on this machine or another host on your LAN.")
                .font(.system(size: 14.5))
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, 10)

            TextField("Search providers and models", text: $search)
                .font(.system(size: 15))
                .foregroundStyle(Theme.textBright)
                .textFieldStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(Theme.borderInputsDark, lineWidth: 1)
                }
                .padding(.top, 32)

            providerRail
                .padding(.top, 12)

            if isLocal || providerEntry?.supportsBaseUrl == true || providerEntry?.kind == .local {
                localConfig
                    .padding(.top, 16)
            }

            modelPicker
                .padding(.top, 16)

            if let entry = selectedEntry ?? providerEntry {
                Text(entry.billing)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.top, 8)

                if entry.signIn == .deviceCode {
                    deviceCodeSection(entry)
                }

                if isLocal {
                    GrizzyField(
                        label: "API key (optional)",
                        placeholder: "Usually not required",
                        text: $apiKey,
                        style: .dark,
                        secure: true
                    )
                    .padding(.top, 12)
                } else if entry.auth == .oauth {
                    Text("This provider cannot paste a key here. Skip if this deployment already has credentials.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.top, 12)
                } else {
                    GrizzyField(
                        label: entry.signIn == .deviceCode ? "Or paste an API key" : "API key",
                        placeholder: "sk-…",
                        text: $apiKey,
                        style: .dark,
                        secure: true
                    )
                    .padding(.top, 12)
                }
            }

            if let modelError {
                Text(modelError)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.orange)
                    .padding(.top, 10)
            }

            HStack(spacing: 12) {
                Button {
                    continueModel()
                } label: {
                    Text(continueLabel)
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textCream)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Theme.bgCream)
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(waitingSignIn)

                if showSkip, let onSkip {
                    Button(action: onSkip) {
                        Text("Skip for now")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 24)
        }
        .onAppear(perform: hydrateFromStore)
    }

    // MARK: - Sections

    private var providerRail: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(filteredProviders.enumerated()), id: \.element.provider) { index, entry in
                    Button {
                        selectProvider(entry)
                    } label: {
                        HStack {
                            Text(entry.providerName ?? entry.provider)
                                .font(.system(size: 15))
                                .foregroundStyle(Theme.textBright)
                            Spacer()
                            Text(ModelCatalog.hint(for: entry))
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(
                            selectedProvider == entry.provider
                                ? Theme.bgSelectedRow
                                : Color.clear
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if index < filteredProviders.count - 1 {
                        Divider().background(Theme.borderListRows)
                    }
                }
            }
        }
        .frame(maxHeight: 192)
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(Theme.borderInputsDark, lineWidth: 1)
        }
    }

    private var localConfig: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Base URL")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)

            TextField(
                providerEntry?.defaultBaseUrl ?? "http://127.0.0.1:11434/v1",
                text: $baseUrl
            )
            .font(.system(size: 15))
            .foregroundStyle(Theme.textBright)
            .textFieldStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(Theme.borderInputsDark, lineWidth: 1)
            }
            .padding(.top, 8)

            Text("Use 127.0.0.1 for this machine, or a LAN IP like 192.168.1.40 for another computer. The server must listen on 0.0.0.0 (not only localhost).")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, 8)

            HStack(spacing: 8) {
                Button {
                    Task { await refreshModels() }
                } label: {
                    Text(probing ? "Loading models…" : "Refresh models")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textBright)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .overlay {
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .stroke(Theme.borderInputsDark, lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .disabled(probing || discovering)
            }
            .padding(.top, 12)

            if isLocal {
                HStack(alignment: .bottom, spacing: 8) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("LAN host")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.textSecondary)
                        TextField(lanHints.first ?? "192.168.1.40", text: $lanHost)
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.textBright)
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .overlay {
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .stroke(Theme.borderInputsDark, lineWidth: 1)
                            }
                    }
                    .frame(maxWidth: .infinity)

                    Button {
                        Task { await discoverOnLan() }
                    } label: {
                        Text(discovering ? "Scanning…" : "Find on LAN")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.textBright)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .overlay {
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .stroke(Theme.borderInputsDark, lineWidth: 1)
                            }
                    }
                    .buttonStyle(.plain)
                    .disabled(probing || discovering)
                }
                .padding(.top, 12)

                if !lanHints.isEmpty {
                    Text("This machine’s LAN addresses: \(lanHints.joined(separator: ", "))")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.top, 8)
                }
            }
        }
    }

    private var modelPicker: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Model")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)

            if modelsForProvider.isEmpty {
                Text(isLocal ? "Refresh models or add one below" : "No models listed")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .stroke(Theme.borderInputsDark, lineWidth: 1)
                    }
                    .padding(.top, 8)
            } else {
                GrizzySelect(
                    options: modelsForProvider.map(\.id),
                    selection: $selectedModelId,
                    style: .field,
                    label: { id in
                        modelsForProvider.first(where: { $0.id == id })?.label ?? id
                    }
                )
                .padding(.top, 8)
            }

            HStack(spacing: 8) {
                TextField("Or type a model id", text: $manualModel)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textBright)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .overlay {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .stroke(Theme.borderInputsDark, lineWidth: 1)
                    }
                Button {
                    addManualModel()
                } label: {
                    Text("Add")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textBright)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .overlay {
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .stroke(Theme.borderInputsDark, lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 8)
        }
    }

    @ViewBuilder
    private func deviceCodeSection(_ entry: CatalogEntry) -> some View {
        Button {
            startDeviceCode(for: entry)
        } label: {
            Text(signingIn ? "Starting…" : ModelCatalog.signInLabel(for: entry))
                .font(.system(size: 14))
                .foregroundStyle(Theme.textCream)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(Theme.bgCream)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(signingIn || waitingSignIn)
        .padding(.top, 14)

                    if let userCode, waitingSignIn {
                        let uri = ModelCatalog.verificationURI(forProvider: entry.provider)
                        let display = uri.replacingOccurrences(of: "https://", with: "")
                        VStack(alignment: .leading, spacing: 10) {
                            Button {
                                if let url = URL(string: uri) {
                                    NSWorkspace.shared.open(url)
                                }
                            } label: {
                                Text("Enter this code at \(display)")
                                    .font(.system(size: 14))
                                    .foregroundStyle(Theme.textBright)
                                    .underline()
                            }
                            .buttonStyle(.plain)
                            Text(userCode)
                                .font(.system(size: 22, design: .monospaced))
                                .tracking(0.2 * 22 * 0.1)
                                .foregroundStyle(Theme.textBrightAlt)
                            Text("Waiting for sign-in…")
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .overlay {
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .stroke(Theme.borderInputsDark, lineWidth: 1)
                        }
                        .padding(.top, 12)
                    }
    }

    // MARK: - Actions

    private func hydrateFromStore() {
        if let provider = store.modelProvider {
            selectedProvider = provider
        }
        if let modelId = store.modelId {
            selectedModelId = modelId
        }
        apiKey = store.apiKey ?? ""
        if let url = store.modelBaseUrl {
            baseUrl = url
        } else if let def = LocalProviders.def(for: selectedProvider) {
            baseUrl = def.defaultBaseUrl
        }
        customModels = store.fetchedModels
        lanHints = LocalProviders.listLocalLanIPv4Addresses()
    }

    private func selectProvider(_ entry: CatalogEntry) {
        selectedProvider = entry.provider
        userCode = nil
        waitingSignIn = false
        modelError = nil
        customModels = []
        manualModel = ""
        baseUrl = entry.defaultBaseUrl ?? LocalProviders.def(for: entry.provider)?.defaultBaseUrl ?? ""
        let first = ModelCatalog.models(forProvider: entry.provider)
            .first(where: { !(entry.kind == .local && $0.id.hasSuffix("/default")) })
        selectedModelId = first?.id ?? ""
    }

    private func addManualModel() {
        let id = manualModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        if !customModels.contains(where: { $0.id == id }) {
            customModels.append(LocalModelRef(id: id))
        }
        selectedModelId = id
        manualModel = ""
    }

    private func refreshModels() async {
        modelError = nil
        probing = true
        defer { probing = false }
        do {
            let url = baseUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? (providerEntry?.defaultBaseUrl ?? "")
                : baseUrl
            guard !url.isEmpty else {
                modelError = "Set a base URL first."
                return
            }
            let result = try await LocalProviders.probeModels(
                baseUrl: url,
                apiKey: apiKey.isEmpty ? nil : apiKey
            )
            baseUrl = result.baseUrl
            customModels = result.models
            if let first = result.models.first {
                selectedModelId = first.id
            } else {
                modelError = "Reachable, but no models were listed. Add a model id below."
            }
        } catch {
            modelError = (error as? LocalProviderError)?.message ?? error.localizedDescription
        }
    }

    private func discoverOnLan() async {
        modelError = nil
        discovering = true
        defer { discovering = false }
        do {
            let result = try await LocalProviders.discover(
                host: lanHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? nil
                    : lanHost,
                includeLocalhost: true
            )
            lanHints = result.hosts
            let match = result.providers.first(where: { $0.provider.rawValue == selectedProvider && $0.reachable })
                ?? result.providers.first(where: \.reachable)
            guard let match else {
                let host = lanHost.trimmingCharacters(in: .whitespacesAndNewlines)
                modelError = host.isEmpty
                    ? "No local providers answered on this machine. Enter a LAN host or set the base URL."
                    : "No local providers answered on \(host). Check the host and that the server listens on 0.0.0.0."
                return
            }
            selectedProvider = match.provider.rawValue
            baseUrl = match.baseUrl
            customModels = match.models
            if let first = match.models.first {
                selectedModelId = first.id
            }
        } catch {
            modelError = (error as? LocalProviderError)?.message ?? error.localizedDescription
        }
    }

    private func startDeviceCode(for entry: CatalogEntry) {
        signingIn = true
        modelError = nil
        userCode = ModelCatalog.makeUserCode()
        signingIn = false
        waitingSignIn = true
        let uri = ModelCatalog.verificationURI(forProvider: entry.provider)
        if let url = URL(string: uri) {
            NSWorkspace.shared.open(url)
        }
        Task {
            try? await Task.sleep(for: .seconds(4))
            await MainActor.run {
                waitingSignIn = false
                persistSelection()
                onContinue?()
            }
        }
    }

    private func continueModel() {
        if isLocal {
            let model = selectedModelId.trimmingCharacters(in: .whitespacesAndNewlines)
            if model.isEmpty && customModels.isEmpty {
                modelError = "Select or add a model id for this endpoint."
                return
            }
        }
        persistSelection()
        onContinue?()
    }

    private func persistSelection() {
        let model = selectedModelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (customModels.first?.id ?? selectedModelId)
            : selectedModelId
        store.saveModelSelection(
            provider: selectedProvider,
            modelId: model,
            apiKey: apiKey.isEmpty ? nil : apiKey,
            baseUrl: baseUrl.isEmpty ? nil : baseUrl,
            models: customModels
        )
    }
}

/// Full-window overlay to reconfigure the model from the shell.
struct ModelSettingsOverlayView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        ZStack {
            Color(red: 4 / 255, green: 4 / 255, blue: 5 / 255).opacity(0.62)
                .ignoresSafeArea()
                .onTapGesture { store.closeModelSettings() }

            VStack(spacing: 0) {
                HStack {
                    Text("Model")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(Theme.textBrightAlt)
                    Spacer()
                    Button {
                        store.closeModelSettings()
                    } label: {
                        Text("✕")
                            .font(.system(size: 16))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 32)
                .padding(.top, 28)

                ScrollView {
                    ModelConnectView(
                        onContinue: { store.closeModelSettings() },
                        showSkip: false,
                        continueLabel: "Save"
                    )
                    .padding(.horizontal, 32)
                    .padding(.top, 20)
                    .padding(.bottom, 40)
                }
                .grizzyScroll()
            }
            .frame(width: 640, height: 720)
            .background(Theme.bgPluginsCard)
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .stroke(Theme.borderListRowsAlt, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.55), radius: 40, y: 20)
        }
    }
}
