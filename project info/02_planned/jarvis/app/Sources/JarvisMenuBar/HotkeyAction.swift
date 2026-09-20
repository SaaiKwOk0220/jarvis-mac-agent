import AppKit
import SwiftUI

/// Action entry point used by both the Cmd+Shift+J global hotkey and the
/// "Ask Jarvis" App Intent. Surfaces `TaskListView` in a floating
/// `NSPanel`-backed window so the user sees the same view they would see
/// from the menu-bar icon.
@MainActor
public enum HotkeyAction {
    private static var panelController: NSWindowController?

    /// Brings Jarvis's task list panel to the front. If `ServiceClient.shared`
    /// has not been initialized yet (cold start, tests), falls back to
    /// activating the app so the user still gets feedback.
    public static func perform() {
        guard let client = ServiceClient.shared else {
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = panelController ?? makeController(client: client)
        panelController = controller
        let window = controller.window
        // Position the panel near the top-center of the screen the user is
        // currently looking at; `MenuBarExtra` opens under the menu-bar item,
        // which is a reasonable default for a launcher-style popover.
        if let window, let screen = NSScreen.main {
            let visibleFrame = screen.visibleFrame
            let panelSize = window.frame.size
            let origin = NSPoint(
                x: visibleFrame.midX - panelSize.width / 2,
                y: visibleFrame.maxY - panelSize.height - 24
            )
            window.setFrameOrigin(origin)
        }
        controller.showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Test-only reset hook. Drops the cached panel so the next call rebuilds
    /// it. Lets tests verify `perform()` from a clean slate without leaking
    /// `NSWindow` references across test cases.
    internal static func resetForTesting() {
        panelController = nil
    }

    private static func makeController(client: ServiceClient) -> NSWindowController {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 400),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Jarvis"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        // `.nonactivatingPanel` already prevents key stealing, but keep
        // `becomesKeyOnlyIfNeeded` for spotlight-style focus.
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = NSHostingView(rootView: TaskListView(client: client))
        return NSWindowController(window: panel)
    }
}
