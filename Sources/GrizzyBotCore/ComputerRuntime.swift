import CoreGraphics
import Foundation
import ImageIO

public struct ComputerInput: Sendable, Equatable {
    public enum Kind: String, Sendable { case click, type, key, open }
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

public struct ComputerSnapshot: Sendable {
    public var jpeg: Data
    public var width: Int
    public var height: Int
    public var url: String

    public init(jpeg: Data, width: Int, height: Int, url: String) {
        self.jpeg = jpeg
        self.width = width
        self.height = height
        self.url = url
    }
}

/// Hosted by the SwiftUI app (WKWebView). Core talks to this for live screen I/O.
public protocol ComputerRuntime: AnyObject, Sendable {
    func attach(botId: String, homeURL: URL) async
    func snapshot(botId: String) async -> ComputerSnapshot?
    func send(_ input: ComputerInput, botId: String) async
    func currentURL(botId: String) async -> String
    func setSession(botId: String, thisMac: Bool, persistent: Bool) async
    func sessionDescription(botId: String) async -> String
}

public extension ComputerRuntime {
    func setSession(botId: String, thisMac: Bool, persistent: Bool) async {
        _ = botId
        _ = thisMac
        _ = persistent
    }

    func sessionDescription(botId: String) async -> String {
        _ = botId
        return "ephemeral desktop (logins do not persist)"
    }
}

/// Fallback desktop when no WKWebView is attached (tests / headless).
public actor FileDesktopRuntime: ComputerRuntime {
    private var urls: [String: String] = [:]

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
        return ComputerSnapshot(jpeg: jpeg, width: 1024, height: 640, url: url)
    }

    public func send(_ input: ComputerInput, botId: String) async {
        if input.kind == .open, !input.text.isEmpty {
            urls[botId] = input.text
        }
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
