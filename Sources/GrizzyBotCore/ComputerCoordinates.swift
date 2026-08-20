import CoreGraphics
import Foundation

/// Screenshot pixel space plus the on-screen rectangle those pixels represent.
public struct ComputerScreenFrame: Sendable, Equatable {
    /// Global origin of the captured surface (CG points for This Mac, CSS pixels for the in-app browser).
    public var originX: Double
    public var originY: Double
    public var pointWidth: Double
    public var pointHeight: Double
    public var pixelWidth: Int
    public var pixelHeight: Int

    public init(
        originX: Double = 0,
        originY: Double = 0,
        pointWidth: Double,
        pointHeight: Double,
        pixelWidth: Int,
        pixelHeight: Int
    ) {
        self.originX = originX
        self.originY = originY
        self.pointWidth = pointWidth
        self.pointHeight = pointHeight
        self.pixelWidth = max(1, pixelWidth)
        self.pixelHeight = max(1, pixelHeight)
    }

    public static func square(_ width: Int, _ height: Int) -> ComputerScreenFrame {
        ComputerScreenFrame(
            pointWidth: Double(width),
            pointHeight: Double(height),
            pixelWidth: width,
            pixelHeight: height
        )
    }
}

/// Map model/screenshot coordinates into the same space the screenshot was taken in.
public enum ComputerCoordinates {
    /// Point in the snapshot’s frame (CSS or display-local, top-left origin).
    public static func pointInFrame(x: Double, y: Double, frame: ComputerScreenFrame) -> CGPoint {
        let fx = x / Double(frame.pixelWidth)
        let fy = y / Double(frame.pixelHeight)
        return CGPoint(
            x: frame.originX + fx * frame.pointWidth,
            y: frame.originY + fy * frame.pointHeight
        )
    }

    /// Cocoa bottom-left `NSScreen.frame` point → CGEvent / AX (top-left of the primary display).
    public static func cgEventPoint(cocoaX: Double, cocoaY: Double, primaryMaxY: Double) -> CGPoint {
        CGPoint(x: cocoaX, y: primaryMaxY - cocoaY)
    }

    /// Screenshot pixel (top-left of that display) → CGEvent point.
    public static func cgEventPoint(
        screenshotX: Double,
        screenshotY: Double,
        frame: ComputerScreenFrame,
        cocoaFrameOriginX: Double,
        cocoaFrameOriginY: Double,
        cocoaFrameHeight: Double,
        primaryMaxY: Double
    ) -> CGPoint {
        let local = pointInFrame(x: screenshotX, y: screenshotY, frame: frame)
        let cocoaX = cocoaFrameOriginX + (local.x - frame.originX)
        let cocoaY = cocoaFrameOriginY + cocoaFrameHeight - (local.y - frame.originY)
        return cgEventPoint(cocoaX: cocoaX, cocoaY: cocoaY, primaryMaxY: primaryMaxY)
    }

    /// CGEvent point → screenshot pixels. `primaryMaxY` must be the **primary**
    /// screen’s `NSScreen.frame.maxY` (the menu-bar display), not the tallest screen.
    public static func screenshotPoint(
        cgEventX: Double,
        cgEventY: Double,
        frame: ComputerScreenFrame,
        cocoaFrameOriginX: Double,
        cocoaFrameOriginY: Double,
        cocoaFrameHeight: Double,
        primaryMaxY: Double
    ) -> CGPoint {
        let cocoaX = cgEventX
        let cocoaY = primaryMaxY - cgEventY
        let localX = cocoaX - cocoaFrameOriginX
        let localY = (cocoaFrameOriginY + cocoaFrameHeight) - cocoaY
        return CGPoint(
            x: localX / frame.pointWidth * Double(frame.pixelWidth),
            y: localY / frame.pointHeight * Double(frame.pixelHeight)
        )
    }
}

/// Compact click-target list attached to screenshots so non-vision models can aim.
public enum ComputerOutline {
    public static let maxLines = 60
    public static let maxChars = 2_400

    public static func line(tag: String, title: String, x: Int, y: Int, width: Int = 0, height: Int = 0) -> String {
        let label = title.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let clipped = String(label.prefix(72))
        if width > 0, height > 0 {
            return "\(tag) \"\(clipped)\" @ (\(x),\(y),\(width)x\(height))"
        }
        return "\(tag) \"\(clipped)\" @ (\(x),\(y))"
    }

    public static func format(lines: [String]) -> String {
        guard !lines.isEmpty else { return "" }
        let clipped = Array(lines.prefix(maxLines))
        var text = clipped.joined(separator: "\n")
        if lines.count > maxLines {
            text += "\n…\(lines.count - maxLines) more"
        }
        if text.count > maxChars {
            text = String(text.prefix(maxChars - 2)) + "\n…"
        }
        return text
    }

    /// One clickable from `line(tag:title:x:y:width:height:)`.
    public struct Target: Sendable, Equatable {
        public var tag: String
        public var name: String
        public var x: Int
        public var y: Int
        public var width: Int
        public var height: Int

        public var role: String { tag }
        public var ref: String { "\(tag):\(x),\(y)" }

        public var policyElement: PolicyElement {
            PolicyElement(ref: ref, role: role, name: name, type: tag)
        }

        var hitWidth: Int { width > 0 ? width : 32 }
        var hitHeight: Int { height > 0 ? height : 16 }
        var area: Int { max(1, hitWidth * hitHeight) }

        func contains(x: Double, y: Double) -> Bool {
            x >= Double(self.x)
                && x <= Double(self.x + hitWidth)
                && y >= Double(self.y)
                && y <= Double(self.y + hitHeight)
        }

        func centerDistance(x: Double, y: Double) -> Double {
            let cx = Double(self.x) + Double(hitWidth) / 2
            let cy = Double(self.y) + Double(hitHeight) / 2
            let dx = x - cx
            let dy = y - cy
            return (dx * dx + dy * dy).squareRoot()
        }
    }

    public static func parse(_ outline: String) -> [Target] {
        let pattern = #"^(\S+)\s+\"([^\"]*)\"\s+@\s+\((-?\d+),(-?\d+)(?:,(\d+)x(\d+))?\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else {
            return []
        }
        let ns = outline as NSString
        let range = NSRange(location: 0, length: ns.length)
        return regex.matches(in: outline, options: [], range: range).compactMap { match in
            guard match.numberOfRanges >= 5,
                  let tag = rangeString(ns, match, 1),
                  let name = rangeString(ns, match, 2),
                  let x = rangeString(ns, match, 3).flatMap(Int.init),
                  let y = rangeString(ns, match, 4).flatMap(Int.init)
            else { return nil }
            let width = match.numberOfRanges > 5 ? rangeString(ns, match, 5).flatMap(Int.init) ?? 0 : 0
            let height = match.numberOfRanges > 6 ? rangeString(ns, match, 6).flatMap(Int.init) ?? 0 : 0
            return Target(tag: tag, name: name, x: x, y: y, width: width, height: height)
        }
    }

    /// Smallest containing target, else nearest center within 48px. Same as OpenBot: the host snapshot, not the model's label.
    public static func hit(outline: String, x: Double, y: Double) -> PolicyElement? {
        let targets = parse(outline)
        guard !targets.isEmpty else { return nil }
        if let best = targets.filter({ $0.contains(x: x, y: y) }).min(by: { $0.area < $1.area }) {
            return best.policyElement
        }
        if let nearest = targets.min(by: { $0.centerDistance(x: x, y: y) < $1.centerDistance(x: x, y: y) }),
           nearest.centerDistance(x: x, y: y) <= 48 {
            return nearest.policyElement
        }
        return nil
    }

    private static func rangeString(_ ns: NSString, _ match: NSTextCheckingResult, _ index: Int) -> String? {
        guard index < match.numberOfRanges else { return nil }
        let range = match.range(at: index)
        guard range.location != NSNotFound, range.length > 0 else { return nil }
        return ns.substring(with: range)
    }
}

public struct ComputerHit: Sendable, Equatable {
    public var role: String
    public var title: String
    public var href: String
    public var tag: String

    public init(role: String = "", title: String = "", href: String = "", tag: String = "") {
        self.role = role
        self.title = title
        self.href = href
        self.tag = tag
    }

    public var summary: String {
        var parts: [String] = []
        if !tag.isEmpty { parts.append(tag) }
        if !role.isEmpty { parts.append(role) }
        if !title.isEmpty { parts.append(title) }
        if !href.isEmpty { parts.append(href) }
        return parts.joined(separator: " ")
    }
}

public struct ComputerActionResult: Sendable, Equatable {
    public var ok: Bool
    public var summary: String
    public var hit: ComputerHit?

    public init(ok: Bool = true, summary: String, hit: ComputerHit? = nil) {
        self.ok = ok
        self.summary = summary
        self.hit = hit
    }

    public var output: String {
        let extra = hit?.summary.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if extra.isEmpty { return summary }
        return "\(summary) → \(extra)"
    }
}
