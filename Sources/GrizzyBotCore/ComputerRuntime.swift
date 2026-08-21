import CoreGraphics
import Foundation
import ImageIO

public struct ComputerInput: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case click, rightClick, doubleClick, scroll, type, key, open

        public var usesScreenshotPoint: Bool {
            switch self {
            case .click, .rightClick, .doubleClick, .scroll: return true
            case .type, .key, .open: return false
            }
        }
    }
    public var kind: Kind
    public var x: Double
    public var y: Double
    public var text: String

    public init(kind: Kind, x: Double = 0, y: Double = 0, text: String = "") {
        self.kind = kind
        self.x = x
        self.y = y
        self.text = text
    }
}

/// Parse `cmd+c`, `shift+enter`, `Escape` into a CG keycode + modifier flags.
public struct ComputerKeyChord: Sendable, Equatable {
    public var key: String
    public var virtualKey: UInt16
    public var command: Bool
    public var shift: Bool
    public var option: Bool
    public var control: Bool

    public var flags: CGEventFlags {
        var bits: CGEventFlags = []
        if command { bits.insert(.maskCommand) }
        if shift { bits.insert(.maskShift) }
        if option { bits.insert(.maskAlternate) }
        if control { bits.insert(.maskControl) }
        return bits
    }
}

public enum ComputerKeyMap {
    public static func parse(_ raw: String) -> ComputerKeyChord {
        let parts = raw.lowercased().split(whereSeparator: { $0 == "+" || $0 == "-" }).map(String.init)
        var command = false, shift = false, option = false, control = false
        let key = parts.last ?? raw.lowercased()
        for part in parts.dropLast() {
            switch part {
            case "cmd", "command", "super", "meta": command = true
            case "shift": shift = true
            case "opt", "option", "alt": option = true
            case "ctrl", "control": control = true
            default: break
            }
        }
        return ComputerKeyChord(
            key: key,
            virtualKey: virtualKey(key),
            command: command,
            shift: shift,
            option: option,
            control: control
        )
    }

    public static func virtualKey(_ name: String) -> UInt16 {
        switch name {
        case "enter", "return": return 36
        case "escape", "esc": return 53
        case "tab": return 48
        case "backspace", "delete": return 51
        case "space": return 49
        case "up": return 126
        case "down": return 125
        case "left": return 123
        case "right": return 124
        case "a": return 0
        case "c": return 8
        case "v": return 9
        case "x": return 7
        case "z": return 6
        default: return 0
        }
    }
}

public struct ComputerSnapshot: Sendable {
    public var jpeg: Data
    public var width: Int
    public var height: Int
    public var url: String
    public var frame: ComputerScreenFrame
    /// Clickable targets in screenshot-pixel space (empty if unknown).
    public var outline: String

    public init(
        jpeg: Data,
        width: Int,
        height: Int,
        url: String,
        frame: ComputerScreenFrame? = nil,
        outline: String = ""
    ) {
        self.jpeg = jpeg
        self.width = width
        self.height = height
        self.url = url
        self.frame = frame ?? ComputerScreenFrame.square(width, height)
        self.outline = outline
    }
}

/// Hosted by the SwiftUI app (WKWebView). Core talks to this for live screen I/O.
public protocol ComputerRuntime: AnyObject, Sendable {
    func attach(botId: String, homeURL: URL) async
    func snapshot(botId: String) async -> ComputerSnapshot?
    func send(_ input: ComputerInput, botId: String) async -> ComputerActionResult
    func lastFrame(botId: String) async -> ComputerScreenFrame?
    func currentURL(botId: String) async -> String
    func setSession(botId: String, thisMac: Bool, persistent: Bool) async
    func sessionDescription(botId: String) async -> String
    /// Ready the surface for the full-window overlay (load browser page / refresh This Mac preview).
    func prepareForDisplay(botId: String) async
}

public extension ComputerRuntime {
    func setSession(botId: String, thisMac: Bool, persistent: Bool) async {
        _ = botId
        _ = thisMac
        _ = persistent
    }

    func lastFrame(botId: String) async -> ComputerScreenFrame? {
        _ = botId
        return nil
    }

    func sessionDescription(botId: String) async -> String {
        _ = botId
        return "ephemeral desktop (logins do not persist)"
    }

    func prepareForDisplay(botId: String) async {
        _ = botId
    }
}

/// Fallback desktop when no WKWebView is attached (tests / headless).
public actor FileDesktopRuntime: ComputerRuntime {
    private var urls: [String: String] = [:]
    private var frames: [String: ComputerScreenFrame] = [:]

    public init() {}

    public func attach(botId: String, homeURL: URL) async {
        urls[botId] = homeURL.absoluteString
        try? FileManager.default.createDirectory(
            at: homeURL.appendingPathComponent(".computer", isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    public func snapshot(botId: String) async -> ComputerSnapshot? {
        let url = urls[botId] ?? ""
        let jpeg = DesktopImage.render(text: "GrizzyBot computer\n\(url)")
        let frame = ComputerScreenFrame.square(1024, 640)
        frames[botId] = frame
        let outline = ComputerOutline.format(lines: [
            ComputerOutline.line(tag: "placeholder", title: url.isEmpty ? "GrizzyBot computer" : url, x: 24, y: 24, width: 180, height: 28),
            ComputerOutline.line(tag: "button", title: "Submit", x: 40, y: 80, width: 100, height: 28),
        ])
        return ComputerSnapshot(jpeg: jpeg, width: 1024, height: 640, url: url, frame: frame, outline: outline)
    }

    public func send(_ input: ComputerInput, botId: String) async -> ComputerActionResult {
        if input.kind == .open, !input.text.isEmpty {
            urls[botId] = input.text
            return ComputerActionResult(summary: "Opened \(input.text)")
        }
        let hit = ComputerHit(role: "file-desktop", title: urls[botId] ?? "")
        switch input.kind {
        case .click:
            return ComputerActionResult(summary: "Clicked (\(Int(input.x)), \(Int(input.y)))", hit: hit)
        case .rightClick:
            return ComputerActionResult(summary: "Right-clicked (\(Int(input.x)), \(Int(input.y)))", hit: hit)
        case .doubleClick:
            return ComputerActionResult(summary: "Double-clicked (\(Int(input.x)), \(Int(input.y)))", hit: hit)
        case .scroll:
            return ComputerActionResult(summary: "Scrolled at (\(Int(input.x)), \(Int(input.y)))", hit: hit)
        case .type:
            return ComputerActionResult(summary: "Typed \(input.text.count) characters", hit: hit)
        case .key:
            return ComputerActionResult(summary: "Pressed \(input.text)", hit: hit)
        case .open:
            return ComputerActionResult(summary: "Opened")
        }
    }

    public func lastFrame(botId: String) async -> ComputerScreenFrame? {
        frames[botId]
    }

    public func currentURL(botId: String) async -> String {
        urls[botId] ?? ""
    }
}

enum DesktopImage {
    static func render(text: String) -> Data {
        _ = text
        let width = 1024
        let height = 640
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return Data() }
        ctx.setFillColor(CGColor(red: 0.08, green: 0.09, blue: 0.11, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(red: 0.22, green: 0.78, blue: 0.66, alpha: 1))
        ctx.fill(CGRect(x: 24, y: height - 64, width: 180, height: 28))
        guard let image = ctx.makeImage() else { return Data() }
        let dest = NSMutableData()
        guard let destId = CGImageDestinationCreateWithData(dest, "public.jpeg" as CFString, 1, nil) else {
            return Data()
        }
        CGImageDestinationAddImage(destId, image, [kCGImageDestinationLossyCompressionQuality: 0.5] as CFDictionary)
        CGImageDestinationFinalize(destId)
        return dest as Data
    }
}

/// Detects empty / all-white JPEG captures from a failed WebView snapshot.
public enum ScreenshotQuality: Sendable {
    public static func isBlankJPEG(_ data: Data) -> Bool {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return true }
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return true }
        let sampleW = min(32, width)
        let sampleH = min(24, height)
        var pixels = [UInt8](repeating: 0, count: sampleW * sampleH * 4)
        guard let ctx = CGContext(
            data: &pixels,
            width: sampleW,
            height: sampleH,
            bitsPerComponent: 8,
            bytesPerRow: sampleW * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return true }
        ctx.interpolationQuality = .low
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: sampleW, height: sampleH))
        var nonWhite = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            if pixels[i] < 250 || pixels[i + 1] < 250 || pixels[i + 2] < 250 {
                nonWhite += 1
                if nonWhite >= 8 { return false }
            }
        }
        return true
    }
}
