import AppKit

/// Keeps a native status item alive and opens the existing task panel when clicked.
@MainActor
final class StatusItemController: NSObject {
    private let item: NSStatusItem

    override init() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        if let button = item.button {
            button.title = "Jarvis"
            button.image = NSImage(systemSymbolName: "bolt.horizontal.circle", accessibilityDescription: "Jarvis")
            button.imagePosition = .imageLeading
            button.toolTip = "Open Jarvis"
            button.target = self
            button.action = #selector(openPanel)
        }
    }

    @objc private func openPanel() { HotkeyAction.perform() }

}

/// Creates the AppKit item after the application has registered with macOS.
@MainActor
final class JarvisApplicationDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: StatusItemController?
    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = StatusItemController()
    }
}
