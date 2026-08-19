import AppKit

/// Shows or hides the main GrizzyBot window for menu bar–only mode.
@MainActor
enum MainWindowController {
    static func applyMenuBarOnly(_ enabled: Bool) {
        if enabled {
            NSApp.setActivationPolicy(.accessory)
            hideMainWindow()
        } else {
            NSApp.setActivationPolicy(.regular)
            showMainWindow()
        }
    }

    static func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        for window in NSApp.windows where window.canBecomeKey {
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    static func hideMainWindow() {
        for window in NSApp.windows {
            window.orderOut(nil)
        }
    }
}
