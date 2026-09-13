import SwiftUI
import Foundation
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
    }

    var body: some Scene {
        MenuBarExtra("Jarvis", systemImage: "bolt.horizontal.circle") {
            TaskListView(client: client)
        }
        Window("New Jarvis Task", id: "new-task") {
            NewTaskView(client: client)
                .frame(minWidth: 420, minHeight: 190)
        }
        .defaultSize(width: 460, height: 230)
        Window("Jarvis Task", id: "task-detail") {
            TaskDetailView(client: client)
                .frame(minWidth: 420, minHeight: 360)
        }
        .defaultSize(width: 520, height: 460)
    }
}

/// Owns the local service for the lifetime of the menu-bar process.
private final class Runtime {
    private var server: LoopbackServer?

    init(client: ServiceClient) {
        do {
            let appSupport = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true).appendingPathComponent("Jarvis", isDirectory: true)
            try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
            let database = try Database(path: appSupport.appendingPathComponent("jarvis.sqlite").path)
            try database.migrate()
            let service = try TaskService(taskRepository: SQLiteTaskRepository(database: database),
                auditRepository: SQLiteAuditRepository(database: database), policy: Policy(),
                policyConfig: PolicyConfig(approvedDirectories: [appSupport.path]), executor: NoOpToolExecutor())
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
