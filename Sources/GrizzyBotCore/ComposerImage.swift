import CoreGraphics
import Foundation
import ImageIO

/// Load dropped / pasted image files into JPEG for vision models.
public enum ComposerImage: Sendable {
    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "gif", "tif", "tiff", "bmp", "webp",
    ]

    public static func isImageURL(_ url: URL) -> Bool {
        imageExtensions.contains(url.pathExtension.lowercased())
    }

    public static func isImagePath(_ path: String) -> Bool {
        let expanded = (path as NSString).expandingTildeInPath
        return isImageURL(URL(fileURLWithPath: expanded))
    }

    /// First usable JPEG from file URLs (largest reasonable size kept via compression).
    public static func jpegBase64(from urls: [URL], maxBytes: Int = 4_500_000) -> String? {
        for url in urls {
            if let data = jpegData(from: url), !data.isEmpty {
                // Screenshot blank check needs enough pixels; tiny icons would false-positive.
                if data.count > 8_000, ScreenshotQuality.isBlankJPEG(data) { continue }
                if data.count <= maxBytes {
                    return data.base64EncodedString()
                }
                if let smaller = recompress(data, quality: 0.55), !smaller.isEmpty {
                    return smaller.base64EncodedString()
                }
                return data.base64EncodedString()
            }
        }
        return nil
    }

    /// If the composer text is (or starts with) a filesystem image path, load it.
    public static func jpegBase64(fromPathInText text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let token = trimmed.split(whereSeparator: \.isNewline).first.map(String.init) ?? trimmed
        let pathToken = token.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? token
        let path = (pathToken as NSString).expandingTildeInPath
        guard path.hasPrefix("/"), isImagePath(path) else { return nil }
        return jpegBase64(from: [URL(fileURLWithPath: path)])
    }

    public static func jpegData(from url: URL) -> Data? {
        guard isImageURL(url) else { return nil }
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return encodeJPEG(image, quality: 0.85)
    }

    private static func recompress(_ jpeg: Data, quality: CGFloat) -> Data? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return encodeJPEG(image, quality: quality)
    }

    private static func encodeJPEG(_ image: CGImage, quality: CGFloat) -> Data? {
        let dest = NSMutableData()
        guard let destId = CGImageDestinationCreateWithData(dest, "public.jpeg" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(
            destId,
            image,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destId) else { return nil }
        return dest as Data
    }
}
