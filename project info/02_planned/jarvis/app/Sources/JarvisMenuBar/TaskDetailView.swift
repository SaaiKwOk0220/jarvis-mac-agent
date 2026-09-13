import SwiftUI
import JarvisDomain

struct TaskDetailView: View {
    @ObservedObject var client: ServiceClient
    @State private var isCancelling = false
    @State private var isStartingDemo = false

    var body: some View {
        Group {
            if let task = client.selectedTask {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if let actionError = client.actionError {
                            Text(actionError).font(.caption).foregroundStyle(.red)
                        }
                        HStack { Text(task.title).font(.title2).bold(); Spacer(); statusBadge(task.status) }
                        LabeledContent("Current step", value: task.status.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
                        Divider()
                        Text("Approval timeline").font(.headline)
                        timeline(for: task)
                        if task.status == .draft {
                            Button {
                                isStartingDemo = true
                                client.clearActionError()
                                Task {
                                    defer { isStartingDemo = false }
                                    do {
                                        try await client.startDemoApproval(taskID: task.id)
                                    } catch {
                                        // client.actionError already published by ServiceClient
                                    }
                                }
                            } label: {
                                Label(isStartingDemo ? "Starting demo…" : "Start demo approval", systemImage: "play.circle")
                            }
                            .disabled(isStartingDemo)
                            Text("Creates a local draft proposal and pauses for your digest-bound approval. The demo executor does not write files.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if task.status == .awaitingApproval { ApprovalView(client: client, task: task) }
                        if [.draft, .planning, .running, .awaitingApproval].contains(task.status) {
                            Button(role: .destructive) {
                                isCancelling = true
                                client.clearActionError()
                                Task {
                                    defer { isCancelling = false }
                                    do {
                                        try await client.cancel(taskID: task.id)
                                        _ = try? await client.loadTimeline(taskID: task.id)
                                    } catch {
                                        // client.actionError already published by ServiceClient
                                    }
                                }
                            } label: { Label(isCancelling ? "Cancelling…" : "Cancel task", systemImage: "xmark.circle") }
                            .disabled(isCancelling)
                        }
                    }.padding(20)
                }
                .task(id: task.id) {
                    _ = try? await client.loadTimeline(taskID: task.id)
                    if task.status == .awaitingApproval { _ = try? await client.loadApprovalRequests(taskID: task.id) }

                    // Poll for status changes (e.g. demo executor completion after Approve).
                    // The approve endpoint kicks off the executor in the background; without
                    // this poll the UI stays on .running until the user hits refresh.
                    // TODO: cover polling logic via JarvisMenuBarTests when SwiftUI .task testing harness lands.
                    let initialStatus = client.tasks.first(where: { $0.id == task.id })?.status ?? task.status
                    if [.completed, .failed, .cancelled].contains(initialStatus) { return }
                    let deadline = Date().addingTimeInterval(6.0)
                    while Date() < deadline {
                        do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
                        _ = try? await client.refresh()
                        _ = try? await client.loadTimeline(taskID: task.id)
                        if let current = client.tasks.first(where: { $0.id == task.id }),
                           [.completed, .failed, .cancelled].contains(current.status) { return }
                    }
                }
            } else { ContentUnavailableView("Select a task", systemImage: "checklist") }
        }
    }

    private func statusBadge(_ status: TaskStatus) -> some View {
        Text(status.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
            .font(.caption).padding(.horizontal, 8).padding(.vertical, 4)
            .background(.quaternary, in: Capsule())
    }

    @ViewBuilder private func timeline(for selectedTask: JarvisTask) -> some View {
        let events = client.timelineEvents[selectedTask.id] ?? []
        if events.isEmpty {
            Text("No events have been recorded yet.").font(.caption).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(events) { event in
                    HStack(alignment: .top, spacing: 8) {
                        Circle().fill(.secondary).frame(width: 6, height: 6).padding(.top, 5)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.summary).font(.callout)
                            Text(event.result).font(.caption).foregroundStyle(.secondary)
                            if !event.target.isEmpty { Text(event.target).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                        }
                        Spacer()
                        Text(event.timestamp, style: .time).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
