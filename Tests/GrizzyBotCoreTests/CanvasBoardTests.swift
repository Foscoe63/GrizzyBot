import CoreGraphics
import Foundation
import GrizzyBotCore
import ImageIO
import Testing
import UniformTypeIdentifiers

@Suite("Canvas board")
struct CanvasBoardTests {
    @Test("saves, lists, opens by title, and deletes")
    func crud() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("canvas-\(UUID().uuidString)", isDirectory: true)
        let store = CanvasBoardStore(root: root)
        var board = CanvasRecord(title: "Iran 2026-08-20")
        board.strokes = [
            CanvasStroke(points: [CanvasPoint(x: 0.1, y: 0.1), CanvasPoint(x: 0.4, y: 0.5)])
        ]
        let saved = try store.save(board)
        #expect(store.list().map(\.title) == ["Iran 2026-08-20"])
        #expect(store.load(id: saved.id)?.title == "Iran 2026-08-20")
        #expect(store.load(id: "Iran 2026-08-20")?.id == saved.id)
        #expect(store.renderPNG(saved)?.isEmpty == false)
        try store.delete(id: saved.id)
        #expect(store.list().isEmpty)
    }

    @Test("places a screenshot on a new or existing canvas")
    func placeImage() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("canvas-img-\(UUID().uuidString)", isDirectory: true)
        let store = CanvasBoardStore(root: root)
        let jpeg = jpegData()
        let created = try store.placeImage(canvasId: nil, title: "Screenshot", jpeg: jpeg)
        #expect(created.images.count == 1)
        #expect(store.load(id: created.id)?.images.count == 1)
        let again = try store.placeImage(canvasId: created.id, title: "Screenshot", jpeg: jpeg)
        #expect(again.images.count == 2)
        #expect(CanvasBoardStore.toolIds.contains("canvas_open"))
    }

    private func jpegData() -> Data {
        let color = CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
        let context = CGContext(
            data: nil,
            width: 32,
            height: 24,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        let image = context.makeImage()!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        )!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }
}
