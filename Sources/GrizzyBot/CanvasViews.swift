import AppKit
import GrizzyBotCore
import SwiftUI

struct CanvasPanelView: View {
    @Environment(AppStore.self) private var store
    @State private var newTitle = ""
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Canvas")
                    .font(.system(size: 13.5))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Button {
                    store.openPanel(nil)
                } label: {
                    Text("✕")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.textBright)
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 16)

            HStack(spacing: 8) {
                GrizzyButton(title: "Open", variant: .outline, size: .sm, disabled: store.activeCanvas() == nil) {
                    store.openCanvas(id: store.activeCanvasId)
                }
                GrizzyButton(title: "Save", variant: .outline, size: .sm) {
                    saveSelected()
                }
                GrizzyButton(title: "Delete", variant: .outline, size: .sm, disabled: store.activeCanvas() == nil) {
                    confirmDelete = true
                }
            }
            .padding(.bottom, 16)

            HStack(spacing: 8) {
                TextField("New canvas", text: $newTitle)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Theme.bgSearch)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                GrizzyButton(title: "New", variant: .cream, size: .sm) {
                    let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    store.createCanvas(title: title.isEmpty ? "Untitled" : title)
                    newTitle = ""
                    store.openCanvas(id: store.activeCanvasId)
                }
            }
            .padding(.bottom, 16)

            if store.canvases.isEmpty {
                Text("Shared boards on this Mac. Any bot can list, open, save, and drop a screenshot here.")
                    .font(.system(size: 13.5))
                    .foregroundStyle(Theme.textMuted)
            } else {
                ForEach(store.canvases) { canvas in
                    Button {
                        store.activeCanvasId = canvas.id
                    } label: {
                        HStack(spacing: 10) {
                            canvasThumb(canvas)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(canvas.title)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(Theme.textBright)
                                    .lineLimit(1)
                                Text("\(canvas.images.count) image\(canvas.images.count == 1 ? "" : "s") · \(canvas.strokes.count) stroke\(canvas.strokes.count == 1 ? "" : "s")")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.textMuted)
                            }
                            Spacer()
                        }
                        .padding(10)
                        .background(store.activeCanvasId == canvas.id ? Theme.bgCard : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .onAppear { store.reloadCanvases() }
        .alert("Delete this canvas?", isPresented: $confirmDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                if let id = store.activeCanvas()?.id {
                    store.deleteCanvas(id: id)
                }
            }
        } message: {
            Text(store.activeCanvas()?.title ?? "")
        }
    }

    private func saveSelected() {
        if let record = store.activeCanvas() {
            _ = store.saveCanvas(record)
            store.openCanvas(id: record.id)
        } else {
            store.createCanvas(title: newTitle)
            store.openCanvas(id: store.activeCanvasId)
        }
    }

    @ViewBuilder
    private func canvasThumb(_ canvas: CanvasRecord) -> some View {
        let url = store.previewURL(forCanvas: canvas.id)
        if let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 44, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Theme.bgScreen)
                .frame(width: 44, height: 28)
        }
    }
}

struct CanvasEditorOverlay: View {
    @Environment(AppStore.self) private var store
    @State private var draft: CanvasRecord = CanvasRecord(title: "Untitled")
    @State private var currentStroke: CanvasStroke?
    @State private var confirmDelete = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Image(systemName: "paintbrush.pointed")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.orange)
                    TextField("Title", text: $draft.title)
                        .textFieldStyle(.plain)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.textBright)
                    Spacer(minLength: 8)
                    Button {
                        store.closeCanvasOverlay()
                    } label: {
                        Text("✕")
                            .font(.system(size: 16))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                }
                HStack(spacing: 8) {
                    GrizzyButton(title: "Place screenshot", variant: .outline, size: .sm) {
                        placeScreenshot()
                    }
                    GrizzyButton(title: "Save", variant: .cream, size: .sm) {
                        if let saved = store.saveCanvas(draft) {
                            draft = saved
                        }
                    }
                    GrizzyButton(title: "Delete", variant: .outline, size: .sm) {
                        confirmDelete = true
                    }
                    Spacer()
                }
            }
            .padding(.leading, 18)
            .padding(.trailing, 18)
            .padding(.top, 36)
            .padding(.bottom, 12)
            .background(Theme.bgApp)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.borderSidebar).frame(height: 1)
            }

            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    Color.white
                    ForEach(draft.images) { layer in
                        let url = store.canvasImageURL(id: draft.id, fileName: layer.fileName)
                        if let nsImage = NSImage(contentsOf: url) {
                            Image(nsImage: nsImage)
                                .resizable()
                                .interpolation(.high)
                                .frame(
                                    width: max(1, layer.width * geo.size.width),
                                    height: max(1, layer.height * geo.size.height)
                                )
                                .offset(
                                    x: layer.x * geo.size.width,
                                    y: layer.y * geo.size.height
                                )
                                .allowsHitTesting(false)
                        }
                    }
                    Canvas { context, size in
                        for stroke in visibleStrokes {
                            guard stroke.points.count >= 2 else { continue }
                            var path = Path()
                            path.move(to: CGPoint(
                                x: stroke.points[0].x * size.width,
                                y: stroke.points[0].y * size.height
                            ))
                            for point in stroke.points.dropFirst() {
                                path.addLine(to: CGPoint(
                                    x: point.x * size.width,
                                    y: point.y * size.height
                                ))
                            }
                            context.stroke(
                                path,
                                with: .color(Color(
                                    red: stroke.red,
                                    green: stroke.green,
                                    blue: stroke.blue,
                                    opacity: stroke.alpha
                                )),
                                style: StrokeStyle(lineWidth: stroke.width, lineCap: .round, lineJoin: .round)
                            )
                        }
                    }
                    .allowsHitTesting(true)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                appendPoint(value.location, in: geo.size)
                            }
                            .onEnded { _ in
                                if let stroke = currentStroke {
                                    draft.strokes.append(stroke)
                                }
                                currentStroke = nil
                            }
                    )
                }
            }
            .padding(18)
            .background(Theme.bgScreen)
        }
        .background(Theme.bgApp)
        .ignoresSafeArea()
        .onAppear { loadDraft() }
        .onChange(of: store.activeCanvasId) { _, _ in loadDraft() }
        .onChange(of: store.canvasRevision) { _, _ in loadDraft() }
        .alert("Delete this canvas?", isPresented: $confirmDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                store.deleteCanvas(id: draft.id)
                store.closeCanvasOverlay()
            }
        } message: {
            Text(draft.title)
        }
    }

    private var visibleStrokes: [CanvasStroke] {
        if let currentStroke { return draft.strokes + [currentStroke] }
        return draft.strokes
    }

    private func loadDraft() {
        if let record = store.activeCanvas() {
            draft = record
        }
    }

    private func appendPoint(_ location: CGPoint, in size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let point = CanvasPoint(x: location.x / size.width, y: location.y / size.height)
        var stroke = currentStroke ?? CanvasStroke(points: [])
        stroke.points.append(point)
        currentStroke = stroke
    }

    private func placeScreenshot() {
        _ = store.saveCanvas(draft)
        if let botId = store.activeBotId {
            _ = store.placeActiveScreenshot(botId: botId)
            loadDraft()
        }
    }
}
