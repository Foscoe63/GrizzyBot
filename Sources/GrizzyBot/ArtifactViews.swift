import AppKit
import GrizzyBotCore
import SwiftUI
import UniformTypeIdentifiers
import WebKit

// MARK: - Sandboxed frame

/// Serves the artifact document and the bundled runtimes to the artifact web
/// view, and nothing else.
///
/// This is the whole network stack an artifact gets. There is no HTTP client
/// behind it: a request either matches the generated document or one of the
/// files vendored in `Resources/ArtifactRuntime`, or it fails.
final class ArtifactSchemeHandler: NSObject, WKURLSchemeHandler {
    private var document: String = ""
    private let lock = NSLock()

    func setDocument(_ html: String) {
        lock.lock()
        document = html
        lock.unlock()
    }

    private var currentDocument: String {
        lock.lock()
        defer { lock.unlock() }
        return document
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else {
            task.didFailWithError(ArtifactFrameError.blocked("no url"))
            return
        }
        let name = url.lastPathComponent

        if name.isEmpty || name == "index.html" {
            respond(task, url: url, data: Data(currentDocument.utf8), mime: "text/html")
            return
        }
        guard let runtime = ArtifactRuntime.Runtime(rawValue: name),
              let file = ArtifactSchemeHandler.runtimeURL(runtime),
              let data = try? Data(contentsOf: file)
        else {
            task.didFailWithError(ArtifactFrameError.blocked(name))
            return
        }
        respond(task, url: url, data: data, mime: "application/javascript")
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    /// The packaged app keeps these in `Contents/Resources/ArtifactRuntime`
    /// (make-app.sh puts them there, and the Xcode folder reference lands in
    /// the same place). A plain `swift build` run instead leaves them in
    /// SwiftPM's own resource bundle, so that is checked second rather than
    /// leaving the frame blank during development.
    static func runtimeURL(_ runtime: ArtifactRuntime.Runtime) -> URL? {
        let name = (runtime.rawValue as NSString).deletingPathExtension
        if let url = Bundle.main.url(forResource: name, withExtension: "js", subdirectory: "ArtifactRuntime") {
            return url
        }
        guard let resources = Bundle.main.resourceURL else { return nil }
        let nested = (try? FileManager.default.contentsOfDirectory(
            at: resources,
            includingPropertiesForKeys: nil
        )) ?? []
        for bundle in nested where bundle.pathExtension == "bundle" {
            let candidate = bundle
                .appendingPathComponent("Contents/Resources/ArtifactRuntime", isDirectory: true)
                .appendingPathComponent(runtime.rawValue)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    private func respond(_ task: WKURLSchemeTask, url: URL, data: Data, mime: String) {
        // The policy also rides on the response, so it applies even to a
        // document that arrived without the meta tag.
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": "\(mime); charset=utf-8",
                "Content-Length": "\(data.count)",
                "Content-Security-Policy": ArtifactRuntime.contentSecurityPolicy,
                "X-Content-Type-Options": "nosniff",
            ]
        )
        guard let response else {
            task.didFailWithError(ArtifactFrameError.blocked(url.absoluteString))
            return
        }
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }
}

enum ArtifactFrameError: LocalizedError {
    case blocked(String)

    var errorDescription: String? {
        switch self {
        case .blocked(let what): return "The artifact frame blocked \(what)."
        }
    }
}

/// Cancels everything except the frame's own scheme, and hands link clicks to
/// the real browser instead of navigating the artifact away from itself.
@MainActor
final class ArtifactNavigationDelegate: NSObject, WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel, preferences)
            return
        }
        if url.scheme == ArtifactRuntime.scheme {
            decisionHandler(.allow, preferences)
            return
        }
        if navigationAction.navigationType == .linkActivated,
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            NSWorkspace.shared.open(url)
        }
        decisionHandler(.cancel, preferences)
    }
}

/// The web view an artifact renders in. One per panel, reloaded whenever the
/// artifact or the selected version changes.
struct ArtifactWebFrame: NSViewRepresentable {
    let html: String
    let revision: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(handler: ArtifactSchemeHandler(), navigation: ArtifactNavigationDelegate())
    }

    final class Coordinator {
        let handler: ArtifactSchemeHandler
        let navigation: ArtifactNavigationDelegate
        var loaded: String?

        init(handler: ArtifactSchemeHandler, navigation: ArtifactNavigationDelegate) {
            self.handler = handler
            self.navigation = navigation
            self.loaded = nil
        }
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // No shared cookies, caches, or storage with anything else in the app.
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(context.coordinator.handler, forURLScheme: ArtifactRuntime.scheme)
        // No script-message handlers are registered, so the page has no bridge
        // back into the app.
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator.navigation
        web.setValue(false, forKey: "drawsBackground")
        load(web, context: context)
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        let key = "\(revision)"
        guard context.coordinator.loaded != key else { return }
        load(web, context: context)
    }

    private func load(_ web: WKWebView, context: Context) {
        context.coordinator.loaded = "\(revision)"
        context.coordinator.handler.setDocument(html)
        guard let url = ArtifactRuntime.indexURL else { return }
        web.load(URLRequest(url: url))
    }
}

// MARK: - Inline chat card

/// The card that appears in the transcript. Claude Desktop shows a compact
/// affordance and keeps the content in the side panel; this does the same, so
/// a long artifact never floods the conversation.
struct ArtifactChatCard: View {
    @Environment(AppStore.self) private var store

    let id: String
    let title: String
    let kind: ArtifactKind
    let summary: String
    let deleted: Bool

    var body: some View {
        Button {
            guard !deleted, exists else { return }
            store.openArtifact(id: id)
        } label: {
            HStack(spacing: 12) {
                Text(glyph)
                    .font(.system(size: 19))
                    .foregroundStyle(deleted ? Theme.textMuted : Theme.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(deleted ? Theme.textMuted : .white)
                        .strikethrough(deleted)
                    Text(detail)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 12)
                if !deleted, exists {
                    Text("Open")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textCream)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .frame(maxWidth: 420, alignment: .leading)
            .background(Theme.bgBubble)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Theme.orange.opacity(deleted ? 0 : 0.28), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(deleted || !exists)
        .help(deleted ? "This artifact was deleted" : "Open \(title) in the artifact panel")
    }

    private var exists: Bool { store.artifact(id: id) != nil }

    private var detail: String {
        if deleted { return "Deleted" }
        if !exists { return "No longer available" }
        return summary
    }

    private var glyph: String {
        switch kind {
        case .markdown: return "¶"
        case .code: return "{ }"
        case .html: return "◍"
        case .svg: return "◆"
        case .mermaid: return "⌗"
        case .react: return "⚛"
        }
    }
}

// MARK: - Right panel

struct ArtifactPanelView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var colorScheme
    @State private var confirmDelete = false
    @State private var showingSource = false
    @State private var copied = false
    @State private var newTitle = ""
    @State private var newKind: ArtifactKind = .markdown
    @State private var editing = false
    @State private var draft = ""
    /// Version count the editor opened against, so a save can tell whether a
    /// bot wrote to this artifact meanwhile.
    @State private var draftBaseVersions = 0
    @State private var notice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            createRow

            if let record = store.activeArtifact {
                picker(current: record)
                versionBar(record)
                Divider().overlay(Theme.borderListRows).padding(.vertical, 12)
                content(record)
                actions(record)
                if let notice {
                    Text(notice)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 10)
                }
            } else {
                Text("No artifacts yet. Make one above, or ask a bot for a document, a program, a diagram, or a small React app. Artifacts are shared across every bot on this Mac and mirrored into the working folder as files.")
                    .font(.system(size: 13.5))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { store.reloadArtifacts() }
        .onChange(of: store.activeArtifactId) { _, _ in cancelEdit() }
        .confirmationDialog(
            "Delete this artifact?",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let id = store.activeArtifactId { store.deleteArtifact(id: id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The artifact and all of its saved versions are removed. Any file already mirrored into the working folder stays.")
        }
    }

    private var header: some View {
        HStack {
            Text("Artifacts")
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            Button {
                store.openPanel(nil)
            } label: {
                Text("✕")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textBright)
            }
            .buttonStyle(.plain)
        }
        .padding(.bottom, 16)
    }

    private var createRow: some View {
        HStack(spacing: 8) {
            TextField("New artifact", text: $newTitle)
                .textFieldStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Theme.bgSearch)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .onSubmit { create() }
            Picker("", selection: $newKind) {
                ForEach(ArtifactKind.allCases, id: \.self) { kind in
                    Text(kind.label).tag(kind)
                }
            }
            .labelsHidden()
            .frame(width: 110)
            GrizzyButton(title: "New", variant: .cream, size: .sm) {
                create()
            }
        }
        .padding(.bottom, 16)
    }

    private func create() {
        store.createArtifact(title: newTitle, kind: newKind)
        newTitle = ""
        showingSource = false
    }

    @ViewBuilder
    private func picker(current: ArtifactRecord) -> some View {
        if store.artifacts.count > 1 {
            Picker("", selection: Binding(
                get: { current.id },
                set: { store.openArtifact(id: $0) }
            )) {
                ForEach(store.artifacts) { record in
                    Text(record.title).tag(record.id)
                }
            }
            .labelsHidden()
            .padding(.bottom, 10)
        }
    }

    private func versionBar(_ record: ArtifactRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(record.title)
                .font(.system(size: 15.5, weight: .semibold))
                .foregroundStyle(.white)
            HStack(spacing: 8) {
                Text(record.summary)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textSecondary)
                if record.versions.count > 1 {
                    Spacer(minLength: 8)
                    Button {
                        step(record, by: -1)
                    } label: {
                        Text("‹").font(.system(size: 14)).foregroundStyle(Theme.textBright)
                    }
                    .buttonStyle(.plain)
                    .disabled(shownIndex(record) == 0)
                    Text("v\(shownIndex(record) + 1) of \(record.versions.count)")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textMuted)
                        .monospacedDigit()
                    Button {
                        step(record, by: 1)
                    } label: {
                        Text("›").font(.system(size: 14)).foregroundStyle(Theme.textBright)
                    }
                    .buttonStyle(.plain)
                    .disabled(shownIndex(record) == record.versions.count - 1)
                }
            }
        }
    }

    @ViewBuilder
    private func content(_ record: ArtifactRecord) -> some View {
        let body = store.artifactContent(record)
        if editing {
            CodeEditorView(
                text: $draft,
                language: syntaxLanguage(record),
                dark: colorScheme == .dark
            )
            .frame(minHeight: 300, maxHeight: 560)
            .background(Theme.bgSearch)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Theme.orange.opacity(0.35), lineWidth: 1)
            )
        } else if record.kind.needsWebFrame, !showingSource {
            ArtifactWebFrame(
                html: ArtifactRuntime.document(
                    for: versioned(record, body: body),
                    dark: colorScheme == .dark
                ),
                revision: store.artifactRevision
            )
            .frame(minHeight: 380)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else if record.kind == .markdown, !showingSource {
            MarkdownText(source: body, textColor: Theme.textPrimary, fontSize: 14.5)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HighlightedSourceView(
                text: body,
                language: syntaxLanguage(record),
                dark: colorScheme == .dark
            )
            .frame(minHeight: 280, maxHeight: 520)
            .background(Theme.bgSearch)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func syntaxLanguage(_ record: ArtifactRecord) -> SyntaxLanguage {
        SyntaxLanguage.of(kind: record.kind, language: record.language)
    }

    @ViewBuilder
    private func actions(_ record: ArtifactRecord) -> some View {
        if editing {
            editActions(record)
        } else {
            viewActions(record)
        }
    }

    private func editActions(_ record: ArtifactRecord) -> some View {
        HStack(spacing: 8) {
            GrizzyButton(title: "Save", variant: .cream, size: .sm) {
                save(record)
            }
            GrizzyButton(title: "Cancel", variant: .outline, size: .sm) {
                cancelEdit()
            }
            Spacer()
            Text(saveHint(record))
                .font(.system(size: 12))
                .foregroundStyle(Theme.textMuted)
                .multilineTextAlignment(.trailing)
        }
        .padding(.top, 14)
    }

    /// A skill document saves to the skill library, not just to the artifact —
    /// worth saying on the button that does it.
    private func saveHint(_ record: ArtifactRecord) -> String {
        if let skillId = record.linkedSkillId {
            return "Saves the \(skillId) skill"
        }
        return editingOlderVersion(record) ? "Saving makes this the newest version" : "Saves as a new version"
    }

    private func viewActions(_ record: ArtifactRecord) -> some View {
        HStack(spacing: 8) {
            GrizzyButton(title: "Edit", variant: .outline, size: .sm) {
                beginEdit(record)
            }
            if record.kind.needsWebFrame || record.kind == .markdown {
                GrizzyButton(
                    title: showingSource ? "Preview" : "Source",
                    variant: .outline,
                    size: .sm
                ) {
                    showingSource.toggle()
                }
            }
            GrizzyButton(title: copied ? "Copied" : "Copy", variant: .outline, size: .sm) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(store.artifactContent(record), forType: .string)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
            }
            GrizzyButton(title: "Save as…", variant: .outline, size: .sm) {
                export(record)
            }
            Spacer()
            GrizzyButton(title: "Delete", variant: .outline, size: .sm) {
                confirmDelete = true
            }
        }
        .padding(.top, 14)
    }

    // MARK: - Helpers

    // MARK: - Editing

    /// Edits whatever version is on screen. Editing an older version and saving
    /// is therefore also how you restore one: it lands as a new version rather
    /// than rewriting history.
    private func beginEdit(_ record: ArtifactRecord) {
        draft = store.artifactContent(record)
        draftBaseVersions = record.versions.count
        notice = nil
        editing = true
    }

    private func cancelEdit() {
        editing = false
        draft = ""
        draftBaseVersions = 0
    }

    private func editingOlderVersion(_ record: ArtifactRecord) -> Bool {
        store.artifactVersionIndex != nil && shownIndex(record) < record.versions.count - 1
    }

    private func save(_ record: ArtifactRecord) {
        let outcome = store.saveArtifactEdit(
            id: record.id,
            content: draft,
            baseVersionCount: draftBaseVersions
        )
        switch outcome {
        case .saved:
            notice = nil
            cancelEdit()
        case .unchanged:
            notice = "Nothing changed, so no new version was saved."
            cancelEdit()
        case .savedOverNewerVersions(let count):
            notice = """
                Saved — but this artifact gained \(count) version\(count == 1 ? "" : "s") \
                while you were editing, probably from a bot or a routine. \
                Nothing was lost: step back through the versions to see them.
                """
            cancelEdit()
        case .failed(let message):
            // Keep the draft: the edit is the user's work, not ours to discard.
            notice = "Could not save: \(message)"
        }
    }

    /// The web frame renders whatever version is selected, so history is
    /// previewable and not just readable as source.
    private func versioned(_ record: ArtifactRecord, body: String) -> ArtifactRecord {
        var copy = record
        copy.content = body
        return copy
    }

    private func shownIndex(_ record: ArtifactRecord) -> Int {
        store.artifactVersionIndex ?? max(0, record.versions.count - 1)
    }

    private func step(_ record: ArtifactRecord, by delta: Int) {
        let next = shownIndex(record) + delta
        guard record.versions.indices.contains(next) else { return }
        store.showArtifactVersion(next == record.versions.count - 1 ? nil : next)
    }

    private func export(_ record: ArtifactRecord) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = record.fileName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? Data(store.artifactContent(record).utf8).write(to: url, options: .atomic)
    }
}
