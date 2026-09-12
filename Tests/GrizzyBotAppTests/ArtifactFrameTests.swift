import AppKit
import GrizzyBotCore
import Testing
import WebKit
@testable import GrizzyBot

/// End-to-end checks for the artifact web frame: the private scheme handler,
/// the bundled runtimes, and the boot scripts, driven through a real WKWebView.
///
/// The string-level checks live in GrizzyBotCoreTests; these exist because a
/// frame can generate perfect HTML and still render blank if the scheme handler
/// cannot find a runtime or the policy blocks its own scripts.
@Suite("Artifact frame rendering")
@MainActor
struct ArtifactFrameTests {
    /// Loads an artifact and returns the rendered HTML once it settles.
    ///
    /// Generated frames mount into `#root`; an HTML artifact *is* the document,
    /// so it has no `#root` and the body is what was rendered.
    private func render(_ record: ArtifactRecord, timeout: Duration = .seconds(20)) async throws -> String {
        let handler = ArtifactSchemeHandler()
        handler.setDocument(ArtifactRuntime.document(for: record, dark: true))

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(handler, forURLScheme: ArtifactRuntime.scheme)

        let navigation = ArtifactNavigationDelegate()
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 600), configuration: config)
        web.navigationDelegate = navigation
        // Off-screen views can skip layout; hosting it in a window keeps React
        // and Mermaid on the normal paint path.
        let window = NSWindow(
            contentRect: web.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView?.addSubview(web)

        let url = try #require(ArtifactRuntime.indexURL)
        web.load(URLRequest(url: url))

        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(120))
            let html = try? await web.evaluateJavaScript(
                "(document.getElementById('root') || document.body || {}).innerHTML || ''"
            ) as? String
            if let html, !html.isEmpty { return html }
        }
        return ""
    }

    @Test("A React artifact compiles and mounts in the frame")
    func reactMounts() async throws {
        let record = ArtifactRecord(
            id: "counter",
            title: "Counter",
            kind: .react,
            content: """
            import React, { useState } from 'react';
            export default function App() {
              const [n] = useState(7);
              return <div className="p-4"><h1 id="headline">Count {n}</h1></div>;
            }
            """
        )
        let html = try await render(record)
        #expect(html.contains("Count"), "React did not mount: \(html.prefix(300))")
        #expect(html.contains("7"), "state did not render: \(html.prefix(300))")
    }

    @Test("An SVG artifact renders without any runtime")
    func svgRenders() async throws {
        let record = ArtifactRecord(
            id: "dot",
            title: "Dot",
            kind: .svg,
            content: "<svg viewBox=\"0 0 10 10\"><circle cx=\"5\" cy=\"5\" r=\"4\" fill=\"red\"/></svg>"
        )
        let html = try await render(record)
        #expect(html.contains("circle"))
    }

    @Test("A Mermaid artifact draws a diagram")
    func mermaidRenders() async throws {
        let record = ArtifactRecord(
            id: "flow",
            title: "Flow",
            kind: .mermaid,
            content: "graph TD; Start-->Finish;"
        )
        let html = try await render(record)
        #expect(html.contains("<svg"), "mermaid produced no svg: \(html.prefix(300))")
    }

    @Test("An unsupported import fails visibly instead of rendering blank")
    func badImportShowsError() async throws {
        let record = ArtifactRecord(
            id: "charts",
            title: "Charts",
            kind: .react,
            content: "import Chart from 'recharts';\nexport default function App() { return <div/>; }"
        )
        let html = try await render(record)
        #expect(html.contains("artifact-error"), "no error surfaced: \(html.prefix(300))")
        #expect(html.contains("recharts"), "error does not name the import: \(html.prefix(300))")
    }

    @Test("Every visual kind's starter content renders, so a new artifact is never a blank frame")
    func starterContentRenders() async throws {
        for kind in ArtifactKind.allCases where kind.needsWebFrame {
            let record = ArtifactRecord(
                id: "start-\(kind.rawValue)",
                title: "Start",
                kind: kind,
                content: kind.starterContent
            )
            let html = try await render(record)
            #expect(!html.isEmpty, "\(kind) starter rendered nothing")
            #expect(
                !html.contains("artifact-error"),
                "\(kind) starter rendered an error: \(html.prefix(200))"
            )
        }
    }

    /// The bug that shipped was not logic — it was dispatch. The delegate
    /// method's signature did not match what WebKit calls, so the runtime
    /// never reached it and the frame fell back to WebKit's default of
    /// allowing everything.
    ///
    /// Asserting the behaviour instead turned out to prove nothing: the
    /// frame's own CSP blocks a scripted navigation whether or not the
    /// delegate is consulted, so that test passed happily against a
    /// deliberately broken delegate. This checks the one thing that actually
    /// failed — that the Objective-C runtime can find the method under a
    /// selector WebKit dispatches.
    @Test("WebKit can dispatch to the frame's navigation delegate")
    func navigationDelegateIsReachable() {
        let delegate = ArtifactNavigationDelegate()
        let withPreferences = NSSelectorFromString(
            "webView:decidePolicyForNavigationAction:preferences:decisionHandler:"
        )
        let withoutPreferences = NSSelectorFromString(
            "webView:decidePolicyForNavigationAction:decisionHandler:"
        )
        #expect(
            delegate.responds(to: withPreferences) || delegate.responds(to: withoutPreferences),
            """
            WebKit cannot dispatch to ArtifactNavigationDelegate: it implements \
            neither decidePolicyForNavigationAction:preferences:decisionHandler: \
            nor decidePolicyForNavigationAction:decisionHandler:, so every \
            navigation falls back to WebKit's default of allow and the frame is \
            not sandboxed at all.
            """
        )
    }

    @Test("The delegate allows its own scheme and refuses everything else")
    @MainActor
    func navigationPolicyDecisions() async {
        let delegate = ArtifactNavigationDelegate()
        let web = WKWebView(frame: .zero)

        func decision(for urlString: String) async -> WKNavigationActionPolicy {
            await withCheckedContinuation { continuation in
                let request = URLRequest(url: URL(string: urlString)!)
                delegate.webView(
                    web,
                    decidePolicyFor: StubNavigationAction(request: request),
                    preferences: WKWebpagePreferences()
                ) { policy, _ in
                    continuation.resume(returning: policy)
                }
            }
        }

        #expect(await decision(for: "grizzy-artifact://frame/index.html") == .allow)
        #expect(await decision(for: "grizzy-artifact://frame/react.js") == .allow)
        #expect(await decision(for: "https://example.com") == .cancel)
        #expect(await decision(for: "http://127.0.0.1:9/") == .cancel)
        #expect(await decision(for: "file:///etc/passwd") == .cancel)
        #expect(await decision(for: "javascript:alert(1)") == .cancel)
    }

    @Test("The scheme handler serves only the frame and its runtimes")
    func schemeHandlerRefusesUnknownPaths() throws {
        // Anything that is not index.html or a known runtime has no business
        // being served, however it is asked for.
        for name in ["evil.js", "../../etc/passwd", "secrets.json", "react.js.map"] {
            #expect(
                ArtifactRuntime.Runtime(rawValue: (name as NSString).lastPathComponent) == nil,
                "\(name) resolved to a servable runtime"
            )
        }
        for runtime in ArtifactRuntime.Runtime.allCases {
            #expect(ArtifactRuntime.Runtime(rawValue: runtime.rawValue) != nil)
        }
    }

    @Test("Every bundled runtime is present in the built app")
    func runtimesAreBundled() throws {
        for runtime in ArtifactRuntime.Runtime.allCases {
            let url = ArtifactSchemeHandler.runtimeURL(runtime)
            #expect(url != nil, "\(runtime.rawValue) is not in the bundle")
            let size = (try? Data(contentsOf: #require(url)).count) ?? 0
            #expect(size > 1024, "\(runtime.rawValue) is empty or truncated")
        }
    }
}


/// `WKNavigationAction` has no public initialiser, so the policy test supplies
/// its own with the one property the delegate reads.
private final class StubNavigationAction: WKNavigationAction {
    private let stubRequest: URLRequest

    init(request: URLRequest) {
        self.stubRequest = request
        super.init()
    }

    override var request: URLRequest { stubRequest }
    override var navigationType: WKNavigationType { .other }
}
