import SwiftUI
import JarvisDomain

struct ApprovalView: View {
    @ObservedObject var client: ServiceClient
    let task: JarvisTask
    @State private var submittingRequestID: UUID?

    /// All pending approvals for this task, ordered by submission time so the
    /// UI is stable across re-renders. PR #10 lets a single task hold several
    /// pendings at once; the previous view resolved to a single object via
    /// `client.approvalRequests[task.id]` and silently dropped every request
    /// except the last one.
    private var pendingRequests: [ApprovalRequest] {
        client.approvalRequests.values
            .filter { $0.taskID == task.id }
            .sorted { $0.id.uuidString < $1.id.uuidString }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let actionError = client.actionError {
                Text(actionError).font(.caption).foregroundStyle(.red)
            }
            Label("Approval required", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("The requested action is paused until you explicitly approve or reject it.")
                .font(.callout)
            ForEach(pendingRequests) { request in
                VStack(alignment: .leading, spacing: 6) {
                    GroupBox("Digest-bound preview") {
                        VStack(alignment: .leading, spacing: 6) {
                            if isSafariRead(request) {
                                Text(request.reason).font(.caption).fixedSize(horizontal: false, vertical: true)
                                Text("Full captured URL (scroll to inspect; may contain sensitive values)")
                                    .font(.caption).foregroundStyle(.secondary)
                                ScrollView([.horizontal, .vertical]) {
                                    Text(request.target)
                                        .font(.system(.caption, design: .monospaced))
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }.frame(maxHeight: 100)
                            } else if request.payload.hasPrefix("ticket:") {
                                Text("完整目标网址（可能包含敏感信息，请滚动核对）").font(.caption)
                                ScrollView { Text(request.target).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                                    .frame(minHeight: 44, maxHeight: 120)
                                Text("批准仅覆盖初始网址。浏览器可能重定向、运行脚本并发送网络请求；原始任务文字可能保存在本机。")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else {
                                LabeledContent("Target", value: request.target)
                            }
                            LabeledContent("Action digest", value: request.digest)
                            Text(request.payload)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(5)
                            Text(isSafariRead(request)
                                 ? "The request digest binds a one-time in-memory ticket to this captured URL and window. The full URL expires from the ticket after one minute."
                                 : "Approval is bound to this exact digest; changing the payload or target invalidates it.")
                                .font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    HStack {
                        Button("Reject", role: .destructive) {
                            submit(.reject, request: request)
                        }
                            .disabled(submittingRequestID != nil)
                        Spacer()
                        Button("Approve") {
                            submit(.approve, request: request)
                        }
                            .disabled(submittingRequestID != nil || request.digest.isEmpty || (isSafariRead(request) && !request.target.hasPrefix("https://")))
                    }
                }
            }
        }
        .onAppear { /* digest is read directly per-request now */ }
        .onChange(of: client.approvalRequests) { _, _ in /* nothing to refresh */ }
    }

    private func isSafariRead(_ request: ApprovalRequest) -> Bool {
        request.payload == "Read accessibility text from this captured Safari window"
    }

    private enum Decision { case approve, reject }

    private func submit(_ decision: Decision, request: ApprovalRequest) {
        submittingRequestID = request.id
        client.clearActionError()
        Task {
            defer { submittingRequestID = nil }
            do {
                switch decision {
                case .approve: try await client.approve(request)
                case .reject:  try await client.reject(request)
                }
                _ = try? await client.loadTimeline(taskID: task.id)
            } catch {
                // client.actionError already published by ServiceClient
            }
        }
    }
}