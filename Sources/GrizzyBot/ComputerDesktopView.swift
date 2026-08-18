import AppKit
import CryptoKit
import GrizzyBotCore
import ScreenCaptureKit
import SwiftUI
import WebKit

@MainActor
final class AppComputerRuntime: ComputerRuntime, @unchecked Sendable {
    static let shared = AppComputerRuntime()

    private var webs: [String: WKWebView] = [:]
    private var homes: [String: URL] = [:]
    private var lastJPEG: [String: Data] = [:]
    private var thisMac: Set<String> = []
    private var persistent: Set<String> = []

    func cachedJPEG(for botId: String) -> Data? { lastJPEG[botId] }

    func usesThisMac(_ botId: String) -> Bool { thisMac.contains(botId) }

    func setSession(botId: String, thisMac: Bool, persistent: Bool) async {
        if thisMac { self.thisMac.insert(botId) } else { self.thisMac.remove(botId) }
        if persistent { self.persistent.insert(botId) } else { self.persistent.remove(botId) }
        if !persistent || thisMac, let old = webs.removeValue(forKey: botId) {
            old.stopLoading()
        }
    }

    func sessionDescription(botId: String) async -> String {
        if thisMac.contains(botId) {
            return "this Mac (Accessibility)"
        }
        if persistent.contains(botId) {
            return "persistent in-app browser"
        }
        return "ephemeral browser"
    }

    func webView(for botId: String) -> WKWebView {
        if let existing = webs[botId] { return existing }
        let config = WKWebViewConfiguration()
        if persistent.contains(botId) {
            config.websiteDataStore = WKWebsiteDataStore(forIdentifier: Self.storeID(for: botId))
        } else {
            config.websiteDataStore = .nonPersistent()
        }
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 800), configuration: config)
        web.customUserAgent = "GrizzyBotComputer/1.0"
        webs[botId] = web
        return web
    }

    func attach(botId: String, homeURL: URL) async {
        homes[botId] = homeURL
        guard !thisMac.contains(botId) else { return }
        let web = webView(for: botId)
        if web.url == nil {
            let desktop = BotDesktopHTML.page(homeURL: homeURL)
            web.loadHTMLString(desktop, baseURL: homeURL)
        }
    }

    func snapshot(botId: String) async -> ComputerSnapshot? {
        if thisMac.contains(botId), let snap = await MacDesktop.snapshot() {
            lastJPEG[botId] = snap.jpeg
            return snap
        }
        let web = webView(for: botId)
        let config = WKSnapshotConfiguration()
        config.rect = CGRect(x: 0, y: 0, width: 1024, height: 640)
        guard let image = try? await web.takeSnapshot(configuration: config) else {
            return await FileDesktopRuntime().snapshot(botId: botId)
        }
        let jpeg = jpegData(image) ?? Data()
        lastJPEG[botId] = jpeg
        return ComputerSnapshot(
            jpeg: jpeg,
            width: Int(image.size.width),
            height: Int(image.size.height),
            url: web.url?.absoluteString ?? homes[botId]?.absoluteString ?? ""
        )
    }

    func send(_ input: ComputerInput, botId: String) async {
        if thisMac.contains(botId) {
            MacDesktop.send(input)
            return
        }
        let web = webView(for: botId)
        switch input.kind {
        case .open:
            if let url = URL(string: input.text) {
                web.load(URLRequest(url: url))
            }
        case .click:
            let js = "document.elementFromPoint(\(input.x), \(input.y))?.dispatchEvent(new MouseEvent('click', {bubbles:true,clientX:\(input.x),clientY:\(input.y)}));"
            _ = try? await web.evaluateJavaScript(js)
        case .type:
            let escaped = input.text
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
                .replacingOccurrences(of: "\n", with: "\\n")
            let js = """
            (function(){
              const el = document.activeElement;
              if (el && (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA' || el.isContentEditable)) {
                el.value = (el.value || '') + '\(escaped)';
                el.dispatchEvent(new Event('input', {bubbles:true}));
              } else {
                document.body.insertAdjacentText('beforeend', '\(escaped)');
              }
            })();
            """
            _ = try? await web.evaluateJavaScript(js)
        case .key:
            let js = "document.dispatchEvent(new KeyboardEvent('keydown', {key: '\(input.text)', bubbles: true}));"
            _ = try? await web.evaluateJavaScript(js)
        }
    }

    func currentURL(botId: String) async -> String {
        if thisMac.contains(botId) { return "this-mac://" }
        return webs[botId]?.url?.absoluteString ?? homes[botId]?.absoluteString ?? ""
    }

    private func jpegData(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.55])
    }

    static func storeID(for botId: String) -> UUID {
        let digest = SHA256.hash(data: Data(botId.utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

enum MacDesktop {
    static func snapshot() async -> ComputerSnapshot? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let display = content.displays.first else { return nil }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = display.width
        config.height = display.height
        guard let image = try? await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        ) else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: image)
        let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.45]) ?? Data()
        return ComputerSnapshot(
            jpeg: jpeg,
            width: image.width,
            height: image.height,
            url: "this-mac://"
        )
    }

    static func send(_ input: ComputerInput) {
        switch input.kind {
        case .open:
            if let url = URL(string: input.text) {
                NSWorkspace.shared.open(url)
            }
        case .click:
            let point = CGPoint(x: input.x, y: input.y)
            let down = CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseDown,
                mouseCursorPosition: point,
                mouseButton: .left
            )
            let up = CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseUp,
                mouseCursorPosition: point,
                mouseButton: .left
            )
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
        case .type:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(input.text, forType: .string)
            let paste = CGEvent(keyboardEventSource: nil, virtualKey: 0x09, keyDown: true)
            paste?.flags = .maskCommand
            paste?.post(tap: .cghidEventTap)
            let pasteUp = CGEvent(keyboardEventSource: nil, virtualKey: 0x09, keyDown: false)
            pasteUp?.flags = .maskCommand
            pasteUp?.post(tap: .cghidEventTap)
        case .key:
            let code = keyCode(input.text)
            let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)
            let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
        }
    }

    private static func keyCode(_ name: String) -> CGKeyCode {
        switch name.lowercased() {
        case "enter", "return": return 36
        case "escape", "esc": return 53
        case "tab": return 48
        case "backspace", "delete": return 51
        case "space": return 49
        default: return 0
        }
    }
}

enum BotDesktopHTML {
    static func page(homeURL: URL) -> String {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: homeURL.path)) ?? []
        let items = files.filter { !$0.hasPrefix(".") }.map {
            "<li><code>\($0)</code></li>"
        }.joined()
        return """
        <html><head><meta charset="utf-8">
        <style>
        body { margin:0; font: 14px -apple-system, sans-serif; background:#111318; color:#e8eaed; }
        header { padding:14px 18px; background:#1b1e24; border-bottom:1px solid #2a2e36; }
        main { display:flex; height: calc(100vh - 48px); }
        nav { width: 240px; padding: 16px; border-right: 1px solid #2a2e36; overflow:auto; }
        iframe { flex:1; border:0; background:white; }
        </style></head>
        <body>
        <header>GrizzyBot computer — \(homeURL.lastPathComponent)</header>
        <main>
          <nav><p>Home files</p><ul>\(items)</ul></nav>
          <iframe src="about:blank"></iframe>
        </main>
        </body></html>
        """
    }
}

struct ComputerDesktopView: NSViewRepresentable {
    let botId: String
    let userHasControl: Bool

    func makeNSView(context: Context) -> WKWebView {
        let web = AppComputerRuntime.shared.webView(for: botId)
        web.allowsMagnification = true
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        web.allowsBackForwardNavigationGestures = userHasControl
        // Interaction is gated by an overlay in SwiftUI when the bot holds control.
    }
}
