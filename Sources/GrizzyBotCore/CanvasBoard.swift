import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct CanvasPoint: Codable, Sendable, Hashable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct CanvasStroke: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var points: [CanvasPoint]
    public var width: Double
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(
        id: String = Ids.new(),
        points: [CanvasPoint] = [],
        width: Double = 3,
        red: Double = 0.12,
        green: Double = 0.12,
        blue: Double = 0.14,
        alpha: Double = 1
    ) {
        self.id = id
        self.points = points
        self.width = width
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
}

public struct CanvasImageLayer: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var fileName: String
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(
        id: String = Ids.new(),
        fileName: String,
        x: Double = 0.05,
        y: Double = 0.05,
        width: Double = 0.9,
        height: Double = 0.9
    ) {
        self.id = id
        self.fileName = fileName
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// Shared drawing on this Mac. Every bot can list, open, save, and delete the same boards.
public struct CanvasRecord: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var width: Double
    public var height: Double
    public var strokes: [CanvasStroke]
    public var images: [CanvasImageLayer]

    public init(
        id: String = Ids.new(),
        title: String,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        width: Double = CanvasBoardStore.defaultWidth,
        height: Double = CanvasBoardStore.defaultHeight,
        strokes: [CanvasStroke] = [],
        images: [CanvasImageLayer] = []
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.width = width
        self.height = height
        self.strokes = strokes
        self.images = images
    }
}

public struct CanvasBoardStore: Sendable {
    public static let defaultWidth: Double = 1280
    public static let defaultHeight: Double = 800
    public static let toolIds: [String] = [
        "canvas_list", "canvas_open", "canvas_save", "canvas_delete", "canvas_place_image",
    ]

    public let root: URL

    public init(root: URL) {
        self.root = root.appendingPathComponent("canvases", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
    }

    public func list() -> [CanvasRecord] {
        loadIndex().sorted { $0.updatedAt > $1.updatedAt }
    }

    public func load(id: String) -> CanvasRecord? {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return loadIndex().first { $0.id == trimmed || $0.title.compare(trimmed, options: .caseInsensitive) == .orderedSame }
    }

    @discardableResult
    public func save(_ record: CanvasRecord) throws -> CanvasRecord {
        var copy = record
        copy.updatedAt = .now
        try FileManager.default.createDirectory(at: folder(for: copy.id), withIntermediateDirectories: true)
        var records = loadIndex().filter { $0.id != copy.id }
        records.append(copy)
        try writeIndex(records)
        if let png = renderPNG(copy) {
            try png.write(to: previewURL(id: copy.id), options: .atomic)
        }
        return copy
    }

    public func delete(id: String) throws {
        guard let match = load(id: id) else {
            throw CanvasBoardError.notFound
        }
        var records = loadIndex()
        records.removeAll { $0.id == match.id }
        try writeIndex(records)
        try? FileManager.default.removeItem(at: folder(for: match.id))
    }

    @discardableResult
    public func placeImage(canvasId: String?, title: String, jpeg: Data) throws -> CanvasRecord {
        var record = canvasId.flatMap { load(id: $0) } ?? CanvasRecord(title: title)
        if canvasId == nil, title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            record.title = title
        }
        try FileManager.default.createDirectory(at: folder(for: record.id), withIntermediateDirectories: true)
        let fileName = "img-\(Ids.new()).jpg"
        try jpeg.write(to: folder(for: record.id).appendingPathComponent(fileName), options: .atomic)
        let size = imageSize(jpeg) ?? CGSize(width: record.width, height: record.height)
        let fitted = fit(size, in: CGSize(width: record.width, height: record.height))
        let layer = CanvasImageLayer(
            fileName: fileName,
            x: fitted.origin.x / record.width,
            y: fitted.origin.y / record.height,
            width: fitted.width / record.width,
            height: fitted.height / record.height
        )
        record.images.append(layer)
        return try save(record)
    }

    public func previewURL(id: String) -> URL {
        folder(for: id).appendingPathComponent("preview.png")
    }

    public func imageURL(id: String, fileName: String) -> URL {
        folder(for: id).appendingPathComponent(fileName)
    }

    public func renderPNG(_ record: CanvasRecord) -> Data? {
        let width = max(64, Int(record.width.rounded()))
        let height = max(64, Int(record.height.rounded()))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        for layer in record.images {
            let url = imageURL(id: record.id, fileName: layer.fileName) as CFURL
            if let source = CGImageSourceCreateWithURL(url, nil),
               let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                let rect = CGRect(
                    x: layer.x * record.width,
                    y: layer.y * record.height,
                    width: layer.width * record.width,
                    height: layer.height * record.height
                )
                context.draw(image, in: rect)
            }
        }
        for stroke in record.strokes where stroke.points.count >= 2 {
            context.setStrokeColor(CGColor(
                red: stroke.red,
                green: stroke.green,
                blue: stroke.blue,
                alpha: stroke.alpha
            ))
            context.setLineWidth(stroke.width)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.beginPath()
            context.move(to: CGPoint(
                x: stroke.points[0].x * record.width,
                y: stroke.points[0].y * record.height
            ))
            for point in stroke.points.dropFirst() {
                context.addLine(to: CGPoint(x: point.x * record.width, y: point.y * record.height))
            }
            context.strokePath()
        }
        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private func folder(for id: String) -> URL {
        root.appendingPathComponent(id, isDirectory: true)
    }

    private func indexURL() -> URL {
        root.appendingPathComponent("index.json")
    }

    private func loadIndex() -> [CanvasRecord] {
        guard let data = try? Data(contentsOf: indexURL()) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([CanvasRecord].self, from: data)) ?? []
    }

    private func writeIndex(_ records: [CanvasRecord]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(records)
        try data.write(to: indexURL(), options: .atomic)
    }

    private func imageSize(_ jpeg: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return CGSize(width: image.width, height: image.height)
    }

    private func fit(_ size: CGSize, in bounds: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else {
            return CGRect(origin: .zero, size: bounds)
        }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let width = size.width * scale
        let height = size.height * scale
        return CGRect(
            x: (bounds.width - width) / 2,
            y: (bounds.height - height) / 2,
            width: width,
            height: height
        )
    }
}

public enum CanvasBoardError: Error, Sendable {
    case notFound
}
