import Foundation
#if canImport(ImagePlayground)
import ImagePlayground
#endif
#if canImport(AppKit)
import AppKit
#endif

/// On-device image generation through Apple's Image Playground (macOS 15.4+ with Apple Intelligence).
/// Nothing is sent anywhere, and the pictures are saved as PNG files in the bot's home.
public enum ImageGeneration {
    public enum Style: String, CaseIterable, Sendable {
        case animation, illustration, sketch
    }

    public enum Failure: Error, LocalizedError, Equatable {
        case unavailable
        case emptyPrompt
        case nothingCreated
        case refused(String)
        public var errorDescription: String? {
            switch self {
            case .unavailable: return "On-device image generation isn't available here. It needs macOS 15.4+ with Apple Intelligence turned on."
            case .emptyPrompt: return "prompt is required — describe the picture."
            case .nothingCreated: return "The image generator returned nothing for that prompt. Try rewording it."
            case .refused(let why): return "Image Playground wouldn't make that: \(why). Check that Apple Intelligence and Image Playground are set up in System Settings, then try again."
            }
        }
    }

    public static var isAvailable: Bool {
        #if canImport(ImagePlayground)
        if #available(macOS 15.4, *) { return ImagePlaygroundViewController.isAvailable }
        #endif
        return false
    }

    /// A file-safe name for a prompt.
    public static func fileName(for prompt: String, index: Int = 0, now: Date = .now) -> String {
        let slug = SkillMarkdown.slug(String(prompt.prefix(40)))
        let stamp = Int(now.timeIntervalSince1970)
        return "images/\(slug.isEmpty ? "image" : slug)-\(stamp)\(index > 0 ? "-\(index)" : "").png"
    }

    /// Makes up to `count` images and returns their PNG data.
    public static func generate(prompt: String, style: Style = .illustration, count: Int = 1) async throws -> [Data] {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw Failure.emptyPrompt }
        #if canImport(ImagePlayground) && canImport(AppKit)
        if #available(macOS 15.4, *), await MainActor.run(body: { ImagePlaygroundViewController.isAvailable }) {
            let creator: ImageCreator
            do { creator = try await ImageCreator() } catch { throw Failure.refused(String(describing: error)) }
            let wanted: ImagePlaygroundStyle
            switch style {
            case .animation: wanted = .animation
            case .illustration: wanted = .illustration
            case .sketch: wanted = .sketch
            }
            let style = creator.availableStyles.contains(wanted) ? wanted : (creator.availableStyles.first ?? wanted)
            var out: [Data] = []
            do {
                for try await created in creator.images(for: [.text(text)], style: style, limit: max(1, min(count, 4))) {
                    let rep = NSBitmapImageRep(cgImage: created.cgImage)
                    if let png = rep.representation(using: .png, properties: [:]) { out.append(png) }
                }
            } catch { throw Failure.refused(String(describing: error)) }
            guard !out.isEmpty else { throw Failure.nothingCreated }
            return out
        }
        #endif
        throw Failure.unavailable
    }
}
