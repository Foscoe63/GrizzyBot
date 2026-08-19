import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import GrizzyBotCore
import WebKit

/// This Mac computer input via Accessibility when possible; CGEvent fallback.
enum MacAccessibility {
    static func perform(_ input: ComputerInput, at cgPoint: CGPoint) -> ComputerActionResult {
        switch input.kind {
        case .open:
            if let url = URL(string: input.text), ComputerURLPolicy.allows(url) {
                NSWorkspace.shared.open(url)
                return ComputerActionResult(summary: "Opened \(input.text)")
            }
            return ComputerActionResult(ok: false, summary: "Blocked or invalid URL")
        case .click:
            return click(at: cgPoint, button: .left, count: 1)
        case .rightClick:
            return click(at: cgPoint, button: .right, count: 1)
        case .doubleClick:
            return click(at: cgPoint, button: .left, count: 2)
        case .scroll:
            return scroll(at: cgPoint, delta: Double(input.text) ?? 120)
        case .type:
            return typeText(input.text)
        case .key:
            return pressKey(input.text)
        }
    }

    static func permissionStatus() -> (accessibility: Bool, screenRecording: Bool) {
        (AXIsProcessTrusted(), CGPreflightScreenCaptureAccess())
    }

    static func promptAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": kCFBooleanTrue!] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        openSettings("Privacy_Accessibility")
    }

    static func promptScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
        openSettings("Privacy_ScreenCapture")
    }

    static func openSettings(_ pane: String) {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?\(pane)",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(pane)",
        ]
        for raw in urls {
            if let url = URL(string: raw) {
                NSWorkspace.shared.open(url)
                return
            }
        }
    }

    private static func click(at point: CGPoint, button: CGMouseButton, count: Int) -> ComputerActionResult {
        if button == .left, count == 1, let hit = AXClick(at: point) {
            return ComputerActionResult(summary: "Clicked (\(Int(point.x)), \(Int(point.y)))", hit: hit)
        }
        let downType: CGEventType = button == .right ? .rightMouseDown : .leftMouseDown
        let upType: CGEventType = button == .right ? .rightMouseUp : .leftMouseUp
        func post(_ type: CGEventType, clickCount: Int) {
            let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button)
            event?.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
            event?.post(tap: .cghidEventTap)
        }
        if count >= 2 {
            post(downType, clickCount: 1)
            post(upType, clickCount: 1)
            post(downType, clickCount: 2)
            post(upType, clickCount: 2)
        } else {
            post(downType, clickCount: 1)
            post(upType, clickCount: 1)
        }
        let label = button == .right ? "Right-clicked" : (count >= 2 ? "Double-clicked" : "Clicked")
        return ComputerActionResult(
            summary: "\(label) (\(Int(point.x)), \(Int(point.y))) via mouse event",
            hit: ComputerHit(role: "cg-event")
        )
    }

    private static func scroll(at point: CGPoint, delta: Double) -> ComputerActionResult {
        let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 1,
            wheel1: Int32(-delta),
            wheel2: 0,
            wheel3: 0
        )
        event?.location = point
        event?.post(tap: .cghidEventTap)
        return ComputerActionResult(summary: "Scrolled \(Int(delta)) at (\(Int(point.x)), \(Int(point.y)))")
    }

    private static func typeText(_ text: String) -> ComputerActionResult {
        guard !text.isEmpty else {
            return ComputerActionResult(ok: false, summary: "Nothing to type")
        }
        if let hit = AXInsert(text) {
            return ComputerActionResult(summary: "Typed \(text.count) characters", hit: hit)
        }
        for scalar in text.unicodeScalars {
            var uni = UniChar(truncatingIfNeeded: scalar.value)
            let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
            let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
            down?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &uni)
            up?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &uni)
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
        }
        return ComputerActionResult(summary: "Typed \(text.count) characters via key events")
    }

    private static func pressKey(_ name: String) -> ComputerActionResult {
        let chord = ComputerKeyMap.parse(name)
        let down = CGEvent(keyboardEventSource: nil, virtualKey: chord.virtualKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: nil, virtualKey: chord.virtualKey, keyDown: false)
        down?.flags = chord.flags
        up?.flags = chord.flags
        if chord.virtualKey == 0, name.count == 1, let scalar = name.unicodeScalars.first {
            var uni = UniChar(truncatingIfNeeded: scalar.value)
            down?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &uni)
            up?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &uni)
        }
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
        return ComputerActionResult(summary: "Pressed \(name)")
    }

    private static func AXClick(at point: CGPoint) -> ComputerHit? {
        guard AXIsProcessTrusted() else { return nil }
        let system = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        let err = AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &element)
        guard err == .success, let element else { return nil }
        let action = kAXPressAction as CFString
        guard AXUIElementPerformAction(element, action) == .success else { return nil }
        return describe(element)
    }

    private static func AXInsert(_ text: String) -> ComputerHit? {
        guard AXIsProcessTrusted() else { return nil }
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let ref = focused
        else { return nil }
        let element = unsafeDowncast(ref as AnyObject, to: AXUIElement.self)

        var current: CFTypeRef?
        let existing: String
        if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &current) == .success {
            existing = (current as? String) ?? ""
        } else {
            existing = ""
        }

        var insertAt = existing.utf16.count
        var rangeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
           let axValue = rangeRef {
            var cfRange = CFRange()
            if AXValueGetValue(axValue as! AXValue, .cfRange, &cfRange) {
                insertAt = max(0, min(existing.utf16.count, cfRange.location))
            }
        }
        let ns = existing as NSString
        let loc = min(max(0, insertAt), ns.length)
        let prefix = ns.substring(to: loc)
        let suffix = ns.substring(from: loc)
        let next = prefix + text + suffix
        let value = next as CFString
        guard AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value) == .success else {
            return nil
        }
        var newRange = CFRange(location: loc + (text as NSString).length, length: 0)
        if let axRange = AXValueCreate(.cfRange, &newRange) {
            AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, axRange)
        }
        return describe(element)
    }

    /// Visible AX targets in screenshot-pixel space for the captured display.
    static func outline(
        cocoaFrame: CGRect,
        frame: ComputerScreenFrame,
        primaryMaxY: CGFloat
    ) -> String {
        guard AXIsProcessTrusted() else {
            return "Accessibility off. Enable it in Settings → Computer before clicking This Mac."
        }
        var lines: [String] = []
        var visited = 0
        let system = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString, &focusedRef) == .success,
           let focusedRef
        {
            let focused = unsafeDowncast(focusedRef as AnyObject, to: AXUIElement.self)
            collect(
                from: focused,
                cocoaFrame: cocoaFrame,
                frame: frame,
                primaryMaxY: primaryMaxY,
                depth: 0,
                lines: &lines,
                visited: &visited
            )
        }
        if lines.count < 12 {
            collect(
                from: system,
                cocoaFrame: cocoaFrame,
                frame: frame,
                primaryMaxY: primaryMaxY,
                depth: 0,
                lines: &lines,
                visited: &visited
            )
        }
        if lines.isEmpty {
            return "No AX targets on this display. Click (x,y) is screenshot pixels, origin top-left."
        }
        return ComputerOutline.format(lines: lines)
    }

    private static let interactiveRoles: Set<String> = [
        "AXButton", "AXLink", "AXTextField", "AXTextArea", "AXCheckBox",
        "AXRadioButton", "AXPopUpButton", "AXMenuItem", "AXComboBox",
        "AXTab", "AXSlider", "AXIncrementor", "AXDisclosureTriangle",
        "AXMenuButton", "AXSearchField",
    ]

    private static func collect(
        from element: AXUIElement,
        cocoaFrame: CGRect,
        frame: ComputerScreenFrame,
        primaryMaxY: CGFloat,
        depth: Int,
        lines: inout [String],
        visited: inout Int
    ) {
        guard depth < 10, lines.count < ComputerOutline.maxLines, visited < 400 else { return }
        visited += 1
        let role = axString(element, kAXRoleAttribute as String)
        if interactiveRoles.contains(role) || role == "AXWindow" {
            if let line = outlineLine(
                element,
                role: role,
                cocoaFrame: cocoaFrame,
                frame: frame,
                primaryMaxY: primaryMaxY
            ) {
                lines.append(line)
            }
        }
        guard depth < 9 else { return }
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let childrenRef
        else { return }
        let cfArray = childrenRef as! CFArray
        let count = CFArrayGetCount(cfArray)
        for i in 0..<count {
            guard lines.count < ComputerOutline.maxLines, visited < 400 else { return }
            let child = unsafeBitCast(CFArrayGetValueAtIndex(cfArray, i), to: AXUIElement.self)
            collect(
                from: child,
                cocoaFrame: cocoaFrame,
                frame: frame,
                primaryMaxY: primaryMaxY,
                depth: depth + 1,
                lines: &lines,
                visited: &visited
            )
        }
    }

    private static func outlineLine(
        _ element: AXUIElement,
        role: String,
        cocoaFrame: CGRect,
        frame: ComputerScreenFrame,
        primaryMaxY: CGFloat
    ) -> String? {
        guard let origin = axPoint(element, kAXPositionAttribute as String),
              let size = axSize(element, kAXSizeAttribute as String),
              size.width >= 2, size.height >= 2
        else { return nil }
        let displayCG = CGRect(
            x: cocoaFrame.minX,
            y: primaryMaxY - cocoaFrame.maxY,
            width: cocoaFrame.width,
            height: cocoaFrame.height
        )
        let elementCG = CGRect(origin: origin, size: size)
        guard displayCG.intersects(elementCG) else { return nil }
        let shot = ComputerCoordinates.screenshotPoint(
            cgEventX: origin.x,
            cgEventY: origin.y,
            frame: frame,
            cocoaFrameOriginX: cocoaFrame.origin.x,
            cocoaFrameOriginY: cocoaFrame.origin.y,
            cocoaFrameHeight: cocoaFrame.height,
            primaryMaxY: primaryMaxY
        )
        let scaleX = frame.pointWidth > 0 ? Double(frame.pixelWidth) / frame.pointWidth : 1
        let scaleY = frame.pointHeight > 0 ? Double(frame.pixelHeight) / frame.pointHeight : 1
        let title = axString(element, kAXTitleAttribute as String)
        let fallback = axString(element, kAXDescriptionAttribute as String)
        let value = axString(element, kAXValueAttribute as String)
        let label = [title, fallback, value].first { !$0.isEmpty } ?? role
        return ComputerOutline.line(
            tag: role.replacingOccurrences(of: "AX", with: "").lowercased(),
            title: label,
            x: Int(shot.x.rounded()),
            y: Int(shot.y.rounded()),
            width: Int((size.width * scaleX).rounded()),
            height: Int((size.height * scaleY).rounded())
        )
    }

    private static func axString(_ element: AXUIElement, _ attr: String) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &value) == .success else { return "" }
        return (value as? String) ?? ""
    }

    private static func axPoint(_ element: AXUIElement, _ attr: String) -> CGPoint? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success, let ref else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(ref as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    private static func axSize(_ element: AXUIElement, _ attr: String) -> CGSize? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success, let ref else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(ref as! AXValue, .cgSize, &size) else { return nil }
        return size
    }

    private static func describe(_ element: AXUIElement) -> ComputerHit {
        func str(_ attr: String) -> String {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attr as CFString, &value) == .success else { return "" }
            return (value as? String) ?? ""
        }
        return ComputerHit(
            role: str(kAXRoleAttribute as String),
            title: str(kAXTitleAttribute as String).isEmpty
                ? (str(kAXDescriptionAttribute as String).isEmpty
                    ? str(kAXValueAttribute as String)
                    : str(kAXDescriptionAttribute as String))
                : str(kAXTitleAttribute as String),
            href: str("AXURL"),
            tag: str(kAXSubroleAttribute as String)
        )
    }
}

enum ComputerURLPolicy {
    static func allows(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        switch scheme {
        case "http", "https", "about": return true
        default: return false
        }
    }

    static func allowsNavigation(to url: URL) -> Bool {
        allows(url)
    }
}

enum BotDesktopHTML {
    static func page(homeURL: URL) -> String {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: homeURL.path)) ?? []
        let items = files.filter { !$0.hasPrefix(".") }.map { name in
            "<li><code>\(escapeHTML(name))</code></li>"
        }.joined()
        let title = escapeHTML(homeURL.lastPathComponent)
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
        <header>GrizzyBot computer — \(title)</header>
        <main>
          <nav><p>Home files</p><ul>\(items)</ul></nav>
          <iframe src="about:blank"></iframe>
        </main>
        </body></html>
        """
    }

    static func escapeHTML(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    /// Escape for single-quoted JavaScript string literals in WKWebView evaluateJavaScript.
    static func jsStringLiteral(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }
}

@MainActor
final class ComputerNavigationDelegate: NSObject, WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(ComputerURLPolicy.allowsNavigation(to: url) ? .allow : .cancel)
    }
}
