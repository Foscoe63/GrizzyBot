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
    private var navDelegates: [String: ComputerNavigationDelegate] = [:]
    private var homes: [String: URL] = [:]
    private var lastJPEG: [String: Data] = [:]
    private var lastFrames: [String: ComputerScreenFrame] = [:]
    private var cocoaFrames: [String: CGRect] = [:]
    private var primaryMaxY: [String: CGFloat] = [:]
    private var thisMac: Set<String> = []
    private var persistent: Set<String> = []

    func cachedJPEG(for botId: String) -> Data? { lastJPEG[botId] }

    func usesThisMac(_ botId: String) -> Bool { thisMac.contains(botId) }

    func setSession(botId: String, thisMac: Bool, persistent: Bool) async {
        if thisMac { self.thisMac.insert(botId) } else { self.thisMac.remove(botId) }
        if persistent { self.persistent.insert(botId) } else { self.persistent.remove(botId) }
        if !persistent || thisMac, let old = webs.removeValue(forKey: botId) {
            old.stopLoading()
            navDelegates.removeValue(forKey: botId)
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
        web.customUserAgent = Self.safariUserAgent
        let delegate = ComputerNavigationDelegate()
        web.navigationDelegate = delegate
        navDelegates[botId] = delegate
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

    func lastFrame(botId: String) async -> ComputerScreenFrame? {
        lastFrames[botId]
    }

    func snapshot(botId: String) async -> ComputerSnapshot? {
        if thisMac.contains(botId) {
            guard let snap = await MacDesktop.snapshot() else { return nil }
            lastJPEG[botId] = snap.snapshot.jpeg
            lastFrames[botId] = snap.snapshot.frame
            cocoaFrames[botId] = snap.cocoaFrame
            primaryMaxY[botId] = snap.primaryMaxY
            return snap.snapshot
        }
        let web = webView(for: botId)
        web.frame = CGRect(x: 0, y: 0, width: 1280, height: 800)
        guard let image = try? await web.takeSnapshot(configuration: nil) else {
            return nil
        }
        let jpeg = jpegData(image) ?? Data()
        lastJPEG[botId] = jpeg
        let pixelW = Int((image.representations.first as? NSBitmapImageRep)?.pixelsWide ?? Int(image.size.width))
        let pixelH = Int((image.representations.first as? NSBitmapImageRep)?.pixelsHigh ?? Int(image.size.height))
        let frame = ComputerScreenFrame(
            pointWidth: max(1, web.bounds.width),
            pointHeight: max(1, web.bounds.height),
            pixelWidth: max(1, pixelW),
            pixelHeight: max(1, pixelH)
        )
        lastFrames[botId] = frame
        let scaleX = frame.pointWidth > 0 ? Double(frame.pixelWidth) / frame.pointWidth : 1
        let scaleY = frame.pointHeight > 0 ? Double(frame.pixelHeight) / frame.pointHeight : 1
        let rawOutline = try? await web.evaluateJavaScript(BrowserComputerJS.outline(scaleX: scaleX, scaleY: scaleY))
        let outline = BrowserComputerJS.outlineText(from: rawOutline)
        return ComputerSnapshot(
            jpeg: jpeg,
            width: frame.pixelWidth,
            height: frame.pixelHeight,
            url: web.url?.absoluteString ?? homes[botId]?.absoluteString ?? "",
            frame: frame,
            outline: outline
        )
    }

    func send(_ input: ComputerInput, botId: String) async -> ComputerActionResult {
        if input.kind.usesScreenshotPoint, lastFrames[botId] == nil {
            _ = await snapshot(botId: botId)
        }
        if thisMac.contains(botId) {
            let frame = lastFrames[botId] ?? ComputerScreenFrame.square(Int(input.x), Int(input.y))
            let cocoa = cocoaFrames[botId] ?? NSScreen.main?.frame ?? .zero
            let maxY = primaryMaxY[botId] ?? NSScreen.screens.first?.frame.maxY ?? cocoa.maxY
            let point = ComputerCoordinates.cgEventPoint(
                screenshotX: input.x,
                screenshotY: input.y,
                frame: frame,
                cocoaFrameOriginX: cocoa.origin.x,
                cocoaFrameOriginY: cocoa.origin.y,
                cocoaFrameHeight: cocoa.height,
                primaryMaxY: maxY
            )
            let mapped = input.kind.usesScreenshotPoint ? point : CGPoint(x: input.x, y: input.y)
            return MacAccessibility.perform(input, at: mapped)
        }
        let web = webView(for: botId)
        switch input.kind {
        case .open:
            if let url = URL(string: input.text), ComputerURLPolicy.allows(url) {
                web.load(URLRequest(url: url))
                return ComputerActionResult(summary: "Opened \(input.text)")
            }
            return ComputerActionResult(ok: false, summary: "Blocked or invalid URL")
        case .click, .rightClick, .doubleClick:
            let frame = lastFrames[botId] ?? ComputerScreenFrame.square(Int(web.bounds.width), Int(web.bounds.height))
            let client = ComputerCoordinates.pointInFrame(x: input.x, y: input.y, frame: frame)
            let count = input.kind == .doubleClick ? 2 : 1
            let button = input.kind == .rightClick ? "right" : "left"
            let js = BrowserComputerJS.click(x: client.x, y: client.y, button: button, count: count)
            let raw = try? await web.evaluateJavaScript(js)
            let label = input.kind == .rightClick
                ? "Right-clicked"
                : (input.kind == .doubleClick ? "Double-clicked" : "Clicked")
            return BrowserComputerJS.result(from: raw, fallback: "\(label) (\(Int(input.x)), \(Int(input.y)))")
        case .scroll:
            let frame = lastFrames[botId] ?? ComputerScreenFrame.square(Int(web.bounds.width), Int(web.bounds.height))
            let client = ComputerCoordinates.pointInFrame(x: input.x, y: input.y, frame: frame)
            let delta = Double(input.text) ?? 120
            let js = BrowserComputerJS.scroll(x: client.x, y: client.y, delta: delta)
            let raw = try? await web.evaluateJavaScript(js)
            return BrowserComputerJS.result(from: raw, fallback: "Scrolled \(Int(delta)) at (\(Int(input.x)), \(Int(input.y)))")
        case .type:
            let escaped = BotDesktopHTML.jsStringLiteral(input.text)
            let js = BrowserComputerJS.type(escapedText: escaped)
            let raw = try? await web.evaluateJavaScript(js)
            return BrowserComputerJS.result(from: raw, fallback: "Typed \(input.text.count) characters")
        case .key:
            let js = BrowserComputerJS.key(chord: ComputerKeyMap.parse(input.text))
            let raw = try? await web.evaluateJavaScript(js)
            return BrowserComputerJS.result(from: raw, fallback: "Pressed \(input.text)")
        }
    }

    private static let safariUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Safari/605.1.15"

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

enum BrowserComputerJS {
    static func click(x: Double, y: Double, button: String = "left", count: Int = 1) -> String {
        """
        (function(){
          const x = \(x), y = \(y);
          const button = '\(button)';
          const count = \(count);
          const el = document.elementFromPoint(x, y);
          if (!el) return JSON.stringify({ok:false, reason:'no element'});
          el.scrollIntoView({block:'nearest', inline:'nearest'});
          const opts = {bubbles:true, cancelable:true, view:window, clientX:x, clientY:y, button: button === 'right' ? 2 : 0};
          if (button === 'right') {
            el.dispatchEvent(new MouseEvent('contextmenu', opts));
          } else if (count >= 2) {
            el.dispatchEvent(new MouseEvent('dblclick', opts));
          } else if (typeof el.click === 'function') {
            el.click();
          } else {
            el.dispatchEvent(new MouseEvent('click', opts));
          }
          const href = el.href || (el.closest && el.closest('a') && el.closest('a').href) || '';
          const text = (el.getAttribute('aria-label') || el.innerText || el.value || '').trim().slice(0, 80);
          return JSON.stringify({ok:true, tag: el.tagName, id: el.id || '', role: el.getAttribute('role') || '', title: text, href: href});
        })()
        """
    }

    static func scroll(x: Double, y: Double, delta: Double) -> String {
        """
        (function(){
          const x = \(x), y = \(y), dy = \(delta);
          const el = document.elementFromPoint(x, y) || document.scrollingElement || document.documentElement;
          if (el && typeof el.scrollBy === 'function') el.scrollBy(0, dy);
          else window.scrollBy(0, dy);
          if (el) el.dispatchEvent(new WheelEvent('wheel', {bubbles:true, cancelable:true, clientX:x, clientY:y, deltaY:dy}));
          return JSON.stringify({ok:true, tag: (el && el.tagName) || 'WINDOW', title: 'scroll ' + dy});
        })()
        """
    }

    static func type(escapedText: String) -> String {
        """
        (function(){
          const text = '\(escapedText)';
          let el = document.activeElement;
          if (!el || el === document.body) {
            const fallback = document.querySelector('input,textarea,[contenteditable="true"]');
            if (fallback) { fallback.focus(); el = fallback; }
          }
          if (!el) return JSON.stringify({ok:false, reason:'no focused field'});
          if (el.isContentEditable) {
            document.execCommand('insertText', false, text);
          } else if ('value' in el) {
            const proto = el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
            const setter = Object.getOwnPropertyDescriptor(proto, 'value')?.set;
            const start = el.selectionStart ?? el.value.length;
            const end = el.selectionEnd ?? start;
            const next = el.value.slice(0, start) + text + el.value.slice(end);
            if (setter) setter.call(el, next); else el.value = next;
            try { el.selectionStart = el.selectionEnd = start + text.length; } catch (e) {}
            el.dispatchEvent(new InputEvent('input', {bubbles:true, data:text, inputType:'insertText'}));
            el.dispatchEvent(new Event('change', {bubbles:true}));
          }
          const label = (el.getAttribute('aria-label') || el.id || el.name || el.tagName || '').toString();
          return JSON.stringify({ok:true, tag: el.tagName, title: label});
        })()
        """
    }

    static func key(chord: ComputerKeyChord) -> String {
        let key = BotDesktopHTML.jsStringLiteral(domKey(chord.key))
        return """
        (function(){
          const key = '\(key)';
          const el = document.activeElement || document.body;
          const opts = {
            key:key, bubbles:true, cancelable:true,
            metaKey: \(chord.command ? "true" : "false"),
            shiftKey: \(chord.shift ? "true" : "false"),
            altKey: \(chord.option ? "true" : "false"),
            ctrlKey: \(chord.control ? "true" : "false")
          };
          el.dispatchEvent(new KeyboardEvent('keydown', opts));
          el.dispatchEvent(new KeyboardEvent('keyup', opts));
          if (key === 'Enter' && el && typeof el.click === 'function') el.click();
          return JSON.stringify({ok:true, tag: el.tagName, title: key});
        })()
        """
    }

    private static func domKey(_ name: String) -> String {
        switch name.lowercased() {
        case "enter", "return": return "Enter"
        case "escape", "esc": return "Escape"
        case "tab": return "Tab"
        case "backspace", "delete": return "Backspace"
        case "space": return " "
        case "up": return "ArrowUp"
        case "down": return "ArrowDown"
        case "left": return "ArrowLeft"
        case "right": return "ArrowRight"
        default: return name
        }
    }

    static func outline(scaleX: Double, scaleY: Double) -> String {
        """
        (function(){
          const sx = \(scaleX), sy = \(scaleY);
          const sel = 'a,button,input,textarea,select,[role="button"],[role="link"],[role="tab"],[contenteditable="true"]';
          const nodes = Array.from(document.querySelectorAll(sel));
          const vw = window.innerWidth || document.documentElement.clientWidth || 0;
          const vh = window.innerHeight || document.documentElement.clientHeight || 0;
          const lines = [];
          for (const el of nodes) {
            if (lines.length >= 60) break;
            const r = el.getBoundingClientRect();
            if (r.width < 2 || r.height < 2) continue;
            if (r.bottom < 0 || r.right < 0 || r.top > vh || r.left > vw) continue;
            const label = (el.getAttribute('aria-label') || el.getAttribute('title') || el.innerText || el.value || el.href || el.tagName || '').trim().replace(/\\s+/g, ' ').slice(0, 72);
            const tag = (el.tagName || 'el').toLowerCase();
            lines.push(tag + ' "' + label + '" @ (' + Math.round(r.left * sx) + ',' + Math.round(r.top * sy) + ',' + Math.round(r.width * sx) + 'x' + Math.round(r.height * sy) + ')');
          }
          return lines.join('\\n');
        })()
        """
    }

    static func outlineText(from raw: Any?) -> String {
        let text: String
        if let string = raw as? String {
            text = string
        } else if let string = raw as? NSString {
            text = string as String
        } else {
            return ""
        }
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return ComputerOutline.format(lines: lines)
    }

    static func result(from raw: Any?, fallback: String) -> ComputerActionResult {
        let text: String
        if let string = raw as? String {
            text = string
        } else if let string = raw as? NSString {
            text = string as String
        } else {
            return ComputerActionResult(summary: fallback)
        }
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return ComputerActionResult(summary: fallback)
        }
        let ok = json["ok"] as? Bool ?? true
        let hit = ComputerHit(
            role: json["role"] as? String ?? "",
            title: json["title"] as? String ?? json["id"] as? String ?? "",
            href: json["href"] as? String ?? "",
            tag: json["tag"] as? String ?? ""
        )
        let reason = json["reason"] as? String
        let summary = ok ? fallback : (reason.map { "\(fallback) (\($0))" } ?? fallback)
        return ComputerActionResult(ok: ok, summary: summary, hit: hit)
    }
}

struct MacDesktopCapture {
    var snapshot: ComputerSnapshot
    var cocoaFrame: CGRect
    var primaryMaxY: CGFloat
}

enum MacDesktop {
    static func snapshot() async -> MacDesktopCapture? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        else { return nil }
        let display = preferredDisplay(in: content) ?? content.displays.first
        guard let display else { return nil }
        let screen = screen(for: display)
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
        let cocoa = screen?.frame ?? CGRect(x: 0, y: 0, width: display.width, height: display.height)
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? cocoa.maxY
        let frame = ComputerScreenFrame(
            pointWidth: cocoa.width,
            pointHeight: cocoa.height,
            pixelWidth: image.width,
            pixelHeight: image.height
        )
        let outline = MacAccessibility.outline(cocoaFrame: cocoa, frame: frame, primaryMaxY: primaryMaxY)
        return MacDesktopCapture(
            snapshot: ComputerSnapshot(
                jpeg: jpeg,
                width: image.width,
                height: image.height,
                url: "this-mac://",
                frame: frame,
                outline: outline
            ),
            cocoaFrame: cocoa,
            primaryMaxY: primaryMaxY
        )
    }

    private static func preferredDisplay(in content: SCShareableContent) -> SCDisplay? {
        let mainID = NSScreen.main
            .flatMap { $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID }
        if let mainID, let match = content.displays.first(where: { $0.displayID == mainID }) {
            return match
        }
        return content.displays.first
    }

    private static func screen(for display: SCDisplay) -> NSScreen? {
        NSScreen.screens.first { screen in
            let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            return num == display.displayID
        }
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
    }
}
