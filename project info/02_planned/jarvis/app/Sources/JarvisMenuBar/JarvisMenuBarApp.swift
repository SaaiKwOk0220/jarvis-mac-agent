import SwiftUI
import Foundation
import Carbon.HIToolbox
import JarvisDomain
import JarvisPersistence
import JarvisPolicy
import JarvisService

@main
struct JarvisMenuBarApp: App {
    @StateObject private var client: ServiceClient
    private let runtime: Runtime

    init() {
        let client = ServiceClient()
        _client = StateObject(wrappedValue: client)
        runtime = Runtime(client: client)
        registerGlobalHotkey()
    }

    var body: some Scene {
        MenuBarExtra("Jarvis", systemImage: "bolt.horizontal.circle") {
            TaskListView(client: client)
        }
        Window("Welcome to Jarvis", id: "welcome") {
            WelcomeView()
                .frame(minWidth: 540, minHeight: 460)
        }
        .defaultSize(width: 600, height: 520)
        Window("New Jarvis Task", id: "new-task") {
            NewTaskView(client: client)
                .frame(minWidth: 420, minHeight: 190)
        }
        .defaultSize(width: 460, height: 230)
        Window("Run Shell Command", id: "shell-task") {
            NewShellTaskView(client: client)
                .frame(minWidth: 480, minHeight: 320)
        }
        .defaultSize(width: 540, height: 380)
        Window("Fetch URL", id: "fetch-url") {
            NewFetchURLView(client: client)
                .frame(minWidth: 480, minHeight: 220)
        }
        .defaultSize(width: 540, height: 260)
        Window("Capture Screenshot", id: "screenshot") {
            NewScreenshotView(client: client)
                .frame(minWidth: 480, minHeight: 220)
        }
        .defaultSize(width: 540, height: 260)
        Window("Inspect Accessibility", id: "ax-query") {
            NewAccessibilityQueryView(client: client)
                .frame(minWidth: 480, minHeight: 260)
        }
        .defaultSize(width: 540, height: 300)
        Window("Jarvis Task", id: "task-detail") {
            TaskDetailView(client: client)
                .frame(minWidth: 420, minHeight: 360)
        }
        .defaultSize(width: 520, height: 460)
        Window("Ask Jarvis", id: "ask-jarvis") {
            AskJarvisView(client: client, service: runtime.taskService)
                .frame(minWidth: 520, minHeight: 460)
        }
        .defaultSize(width: 620, height: 560)
    }
}

/// Owns the local service for the lifetime of the menu-bar process.
private final class Runtime {
    private var server: LoopbackServer?

    /// The live service backing the menu-bar UI, or `nil` when startup failed
    /// (the UI stays usable and reports an unavailable service). The "Ask
    /// Jarvis" window needs the real instance — not the HTTP client — to hand
    /// to `TaskServiceToolRunner`; both paths end up at this one service, so
    /// the agent loop is bound by the same policy gate as every other task.
    private(set) var taskService: (any TaskServiceAPI)?

    init(client: ServiceClient) {
        do {
            let appSupport = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true).appendingPathComponent("Jarvis", isDirectory: true)
            try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
            let database = try Database(path: appSupport.appendingPathComponent("jarvis.sqlite").path)
            try database.migrate()
            let service = try TaskService(taskRepository: SQLiteTaskRepository(database: database),
                auditRepository: SQLiteAuditRepository(database: database), policy: Policy(),
                policyConfig: PolicyConfig(
                    approvedDirectories: [appSupport.path],
                    commandNames: ["shell", "swift", "xcodebuild"],
                    browserProfiles: ["default"],
                    sites: [],
                    applicationBundleIDs: [
                        "com.apple.finder",
                        "com.apple.Safari",
                        "com.apple.Terminal"
                    ]
                ),
                executor: NoOpToolExecutor(),
                terminal: TerminalToolExecutor(),
                webFetch: WebFetchToolExecutor(),
                screenshot: ScreenshotToolExecutor(),
                accessibility: AccessibilityQueryToolExecutor())
            self.taskService = service
            let server = LoopbackServer(service: service)
            self.server = server
            Task { @MainActor in
                if let port = try? await server.start() {
                    client.configure(baseURL: URL(string: "http://127.0.0.1:\(port)")!)
                    _ = try? await client.refresh()
                }
            }
        } catch {
            // The UI remains available and reports an unavailable service if setup fails.
        }
    }
}

/// Registers Cmd+Shift+J as a process-wide hotkey using Carbon's
/// `RegisterEventHotKey`. Carbon is the only public macOS API that captures
/// the keystroke (so it does not leak to the frontmost app); `NSEvent`
/// monitors are observer-only. Registration failures are non-fatal: the
/// menu-bar UI continues to work, and the user can still reach Jarvis via
/// the menu-bar icon or the "Ask Jarvis" App Intent.
private extension JarvisMenuBarApp {
    func registerGlobalHotkey() {
        do {
            try HotkeyManager.shared.register(
                keyCode: UInt32(kVK_ANSI_J),
                modifiers: UInt32(cmdKey | shiftKey)
            ) {
                HotkeyAction.perform()
            }
        } catch {
            FileHandle.standardError.write(Data(
                "Jarvis: failed to register Cmd+Shift+J hotkey: \(error)\n".utf8
            ))
        }
    }
}
