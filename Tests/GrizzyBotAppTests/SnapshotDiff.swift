import AppKit
import Foundation

/// Compares two PNG snapshots pixel by pixel, with a tolerance.
///
/// An exact SHA-256 over the encoded PNG is the wrong contract for a rendered
/// view: font smoothing and rasterisation differ between machines, OS versions
/// and Xcode versions, so a byte-exact golden can only ever pass on the machine
/// that recorded it. Comparing pixels keeps what these tests are actually for —
/// did the layout change? — while ignoring what they are not: did this Mac
/// anti-alias a glyph one shade differently.
enum SnapshotDiff {
    struct Result: Sendable {
        /// Share of pixels differing by more than the channel tolerance, 0...1.
        var differingFraction: Double
        /// Largest single-channel difference seen anywhere.
        var maxChannelDelta: Int
        var width: Int
        var height: Int
    }

    enum Failure: Error, CustomStringConvertible {
        case undecodable(String)
        case sizeMismatch(String, expected: String, actual: String)

        var description: String {
            switch self {
            case .undecodable(let name):
                return "Snapshot \(name) could not be decoded as a bitmap."
            case .sizeMismatch(let name, let expected, let actual):
                return "Snapshot \(name) changed size: golden is \(expected), render is \(actual)."
            }
        }
    }

    /// Decodes to a known RGBA8 layout so two PNGs written with different
    /// colour spaces or row padding still compare like for like.
    static func canonical(_ png: Data, downsample: Int = 1) -> (pixels: [UInt8], width: Int, height: Int)? {
        guard let source = NSBitmapImageRep(data: png) else { return nil }
        let divisor = max(1, downsample)
        let width = max(1, source.pixelsWide / divisor)
        let height = max(1, source.pixelsHigh / divisor)
        guard width > 0, height > 0 else { return nil }
        guard let target = NSBitmapImageRep(
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
        ) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: target)
        NSGraphicsContext.current?.imageInterpolation = .high
        source.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()

        guard let bytes = target.bitmapData else { return nil }
        return (Array(UnsafeBufferPointer(start: bytes, count: width * height * 4)), width, height)
    }

    /// A pixel counts as different when any channel moves by more than
    /// `channelTolerance`, which lets sub-shade anti-aliasing pass while a
    /// moved, resized, or missing element still registers.
    static func compare(
        render: Data,
        golden: Data,
        name: String,
        channelTolerance: Int,
        downsample: Int = 1
    ) throws -> Result {
        guard let a = canonical(render, downsample: downsample) else {
            throw Failure.undecodable("\(name) (render)")
        }
        guard let b = canonical(golden, downsample: downsample) else {
            throw Failure.undecodable("\(name) (golden)")
        }
        guard a.width == b.width, a.height == b.height else {
            throw Failure.sizeMismatch(
                name,
                expected: "\(b.width)×\(b.height)",
                actual: "\(a.width)×\(a.height)"
            )
        }

        var differing = 0
        var maxDelta = 0
        for index in stride(from: 0, to: a.pixels.count, by: 4) {
            var pixelMax = 0
            for channel in 0..<4 {
                let delta = abs(Int(a.pixels[index + channel]) - Int(b.pixels[index + channel]))
                if delta > pixelMax { pixelMax = delta }
            }
            if pixelMax > maxDelta { maxDelta = pixelMax }
            if pixelMax > channelTolerance { differing += 1 }
        }

        let total = Double(a.width * a.height)
        return Result(
            differingFraction: total == 0 ? 0 : Double(differing) / total,
            maxChannelDelta: maxDelta,
            width: a.width,
            height: a.height
        )
    }
}
