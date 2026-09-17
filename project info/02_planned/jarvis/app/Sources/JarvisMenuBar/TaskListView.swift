import SwiftUI
import JarvisDomain

struct TaskListView: View {
    @ObservedObject var client: ServiceClient
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Jarvis", systemImage: "bolt.horizontal.circle")
                Spacer()
                Button { Task { try? await client.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
            }
            Divider()
            Button { openWindow(id: "new-task") } label: {
                Label("New task…", systemImage: "plus.circle")
            }
            Button { openWindow(id: "shell-task") } label: {
                Label("Run shell command…", systemImage: "terminal")
            }
            Button { openWindow(id: "fetch-url") } label: {
                Label("Fetch URL…", systemImage: "globe")
            }
            Button { openWindow(id: "screenshot") } label: {
                Label("Capture screenshot…", systemImage: "camera")
            }
            if client.tasks.isEmpty {
                Text(client.serviceError?.localizedDescription ?? "No tasks yet")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            } else {
                ForEach(client.tasks) { task in
                    Button {
                        client.select(task)
                        openWindow(id: "task-detail")
                    } label: {
                        HStack {
                            Circle().fill(color(for: task.status)).frame(width: 8, height: 8)
                            VStack(alignment: .leading) {
                                Text(task.title).lineLimit(1)
                                Text(task.status.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                        }
                    }.buttonStyle(.plain)
                }
            }
            Divider()
            Button("Quit Jarvis") { NSApplication.shared.terminate(nil) }
        }
        .padding(12)
        .frame(width: 300)
        .task { _ = try? await client.refresh() }
    }

    private func color(for status: TaskStatus) -> Color {
        switch status { case .completed: return .green; case .failed, .blocked: return .red; case .awaitingApproval: return .orange; case .cancelled: return .gray; default: return .blue }
    }

}
