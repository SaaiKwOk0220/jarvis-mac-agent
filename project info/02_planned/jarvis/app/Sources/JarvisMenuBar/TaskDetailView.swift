import SwiftUI
import JarvisDomain

struct TaskDetailView: View {
    @ObservedObject var client: ServiceClient
    @State private var isCancelling = false

    var body: some View {
        Group {
            if let task = client.selectedTask {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack { Text(task.title).font(.title2).bold(); Spacer(); statusBadge(task.status) }
                        LabeledContent("Current step", value: task.status.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
                        Divider()
                        Text("Approval timeline").font(.headline)
                        Text("Every transition and approval is recorded by the local service.").font(.caption).foregroundStyle(.secondary)
                        if task.status == .awaitingApproval { ApprovalView(client: client, task: task) }
                        if [.draft, .planning, .running, .awaitingApproval].contains(task.status) {
                            Button(role: .destructive) {
                                isCancelling = true
                                Swift.Task { defer { isCancelling = false }; try? await client.cancel(taskID: task.id) }
                            } label: { Label(isCancelling ? "Cancelling…" : "Cancel task", systemImage: "xmark.circle") }
                            .disabled(isCancelling)
                        }
                    }.padding(20)
                }
                .task { if task.status == .awaitingApproval { _ = try? await client.loadApprovalRequests(taskID: task.id) } }
            } else { ContentUnavailableView("Select a task", systemImage: "checklist") }
        }
    }

    private func statusBadge(_ status: TaskStatus) -> some View {
        Text(status.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
            .font(.caption).padding(.horizontal, 8).padding(.vertical, 4)
            .background(.quaternary, in: Capsule())
    }
}
