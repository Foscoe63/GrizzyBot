import AppKit
import Testing
@testable import GrizzyBot

/// The comparator is the contract these snapshots now rest on, so it is tested
/// directly rather than only through the overlays it guards.
@Suite("Snapshot comparison")
struct SnapshotDiffTests {
    /// A flat image with an optional filled rectangle, as PNG.
    private func png(
        width: Int = 200,
        height: Int = 200,
        background: CGFloat = 0.1,
        rect: NSRect? = nil,
        rectGray: CGFloat = 0.9
    ) throws -> Data {
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: width * 4,
            bitsPerPixel: 32
        ))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(white: background, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        if let rect {
            NSColor(white: rectGray, alpha: 1).setFill()
            rect.fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    private func fraction(_ a: Data, _ b: Data) throws -> Double {
        try SnapshotDiff.compare(render: a, golden: b, name: "t", channelTolerance: 12, downsample: 4)
            .differingFraction
    }

    @Test("An identical image differs by nothing")
    func identicalIsZero() throws {
        let image = try png()
        #expect(try fraction(image, image) == 0)
    }

    @Test("Sub-tolerance colour drift is ignored, the way anti-aliasing should be")
    func smallDriftIgnored() throws {
        // Two shades apart per channel — under the tolerance.
        let a = try png(background: 0.100)
        let b = try png(background: 0.108)
        #expect(try fraction(a, b) == 0)
    }

    @Test("A moved element registers as a difference")
    func movedElementDetected() throws {
        let a = try png(rect: NSRect(x: 20, y: 20, width: 80, height: 80))
        let b = try png(rect: NSRect(x: 60, y: 60, width: 80, height: 80))
        let diff = try fraction(a, b)
        #expect(diff > 0.05, "a moved block should be obvious, got \(diff)")
    }

    @Test("A missing element registers as a difference")
    func missingElementDetected() throws {
        let a = try png(rect: NSRect(x: 20, y: 20, width: 80, height: 80))
        let b = try png(rect: nil)
        let diff = try fraction(a, b)
        #expect(diff > 0.05, "a missing block should be obvious, got \(diff)")
    }

    @Test("A change smaller than the overlays' own threshold is still caught")
    func smallStructuralChangeDetected() throws {
        // 12×12 of 200×200 is 0.36% — just above the 0.25% limit the overlay
        // snapshots use, and the scale the real UI changes measured at.
        let a = try png(rect: NSRect(x: 20, y: 20, width: 12, height: 12))
        let b = try png(rect: nil)
        let diff = try fraction(a, b)
        #expect(diff > 0.0025, "a 0.36% change should exceed the overlay limit, got \(diff)")
    }

    @Test("A different size is reported rather than compared")
    func sizeMismatchThrows() throws {
        let a = try png(width: 200, height: 200)
        let b = try png(width: 220, height: 200)
        #expect(throws: SnapshotDiff.Failure.self) {
            _ = try SnapshotDiff.compare(render: a, golden: b, name: "t", channelTolerance: 12, downsample: 4)
        }
    }

    @Test("Undecodable data is reported rather than treated as blank")
    func garbageThrows() throws {
        let good = try png()
        #expect(throws: SnapshotDiff.Failure.self) {
            _ = try SnapshotDiff.compare(
                render: Data("not a png".utf8), golden: good, name: "t", channelTolerance: 12, downsample: 4
            )
        }
    }
}
