import SwiftUI

@main
struct JarvisMenuBarApp: App {
    @StateObject private var client = ServiceClient()
    @State private var showingDetail = false

    var body: some Scene {
        MenuBarExtra("Jarvis", systemImage: "bolt.horizontal.circle") {
            TaskListView(client: client, showingDetail: $showingDetail)
        }
        Window("Jarvis Task", id: "task-detail") {
            TaskDetailView(client: client)
                .frame(minWidth: 420, minHeight: 360)
        }
        .defaultSize(width: 520, height: 460)
    }
}
