import SwiftUI
import JarvisDomain

struct ApprovalView: View {
    @ObservedObject var client: ServiceClient
    let task: Task
    @State private var digest = ""
    @State private var submitting = false

    private var request: ApprovalRequest? { client.approvalRequests.values.first(where: { $0.taskID == task.id }) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Approval required", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("The requested action is paused until you explicitly approve or reject it.")
                .font(.callout)
            GroupBox("Digest-bound preview") {
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("Reason", value: request?.reason ?? "Approval requested by policy")
                    LabeledContent("Target", value: request?.target ?? "Unavailable")
                    LabeledContent("Action digest", value: digest.isEmpty ? "Unavailable" : digest)
                    if let payload = request?.payload { Text(payload).font(.system(.caption, design: .monospaced)).textSelection(.enabled).lineLimit(5) }
                    Text("Approval is bound to this exact digest; changing the payload or target invalidates it.")
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("Reject", role: .destructive) {
                    guard let request else { return }; submitting = true
                    Swift.Task { defer { submitting = false }; try? await client.reject(request) }
                }
                    .disabled(submitting)
                Spacer()
                Button("Approve") {
                    guard let request, !request.digest.isEmpty else { return }; submitting = true
                    Swift.Task { defer { submitting = false }; try? await client.approve(request) }
                }
                    .disabled(submitting || request == nil || digest.isEmpty)
            }
        }
        .onAppear { updateDigest() }
        .onChange(of: client.approvalRequests) { _, _ in updateDigest() }
    }

    private func updateDigest() {
        digest = client.approvalRequests.values.first(where: { $0.taskID == task.id })?.digest ?? ""
    }
}
