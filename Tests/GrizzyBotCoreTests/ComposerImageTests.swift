import CoreGraphics
import Foundation
import GrizzyBotCore
import ImageIO
import Testing

@Suite("ComposerImage")
struct ComposerImageTests {
    @Test("encodes png drop to jpeg base64")
    func encodesPNG() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("composer-img-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("shot.png")
        try writeTinyPNG(to: url)
        let b64 = ComposerImage.jpegBase64(from: [url])
        #expect(b64 != nil)
        #expect(!(b64 ?? "").isEmpty)
        let fromPath = ComposerImage.jpegBase64(fromPathInText: url.path)
        #expect(fromPath != nil)
    }

    private func writeTinyPNG(to url: URL) throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let rgba: [UInt8] = [30, 180, 120, 255]
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let image = CGImage(
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: 4,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              )
        else {
            throw NSError(domain: "ComposerImageTests", code: 1)
        }
        let dest = NSMutableData()
        guard let destId = CGImageDestinationCreateWithData(dest, "public.png" as CFString, 1, nil) else {
            throw NSError(domain: "ComposerImageTests", code: 2)
        }
        CGImageDestinationAddImage(destId, image, nil)
        guard CGImageDestinationFinalize(destId) else {
            throw NSError(domain: "ComposerImageTests", code: 3)
        }
        try (dest as Data).write(to: url)
    }
}
