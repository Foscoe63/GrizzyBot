import AppKit
import SwiftUI

/// Dark rakazo-style chrome using AppKit window flags instead of `.hiddenTitleBar`,
/// which avoids CoreUI `scaleFactor == 0` spam for system traffic-light glyphs.
@MainActor
enum GrizzyWindowChrome {
    static let background = NSColor(red: 5 / 255, green: 5 / 255, blue: 6 / 255, alpha: 1)

    static func apply(to window: NSWindow) {
        window.title = "GrizzyBot"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = true
        window.isOpaque = true
        window.backgroundColor = background
        window.titlebarSeparatorStyle = .none
        window.toolbar = nil
    }
}

@MainActor
private struct GrizzyWindowConfigurator: NSViewRepresentable {
    final class HostView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                GrizzyWindowChrome.apply(to: window)
            }
        }
    }

    func makeNSView(context: Context) -> NSView {
        HostView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let window = nsView.window {
            GrizzyWindowChrome.apply(to: window)
        }
    }
}

extension View {
    /// Transparent title bar + full-size dark content; keeps native traffic lights.
    func grizzyWindowChrome() -> some View {
        background {
            GrizzyWindowConfigurator()
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }
}
