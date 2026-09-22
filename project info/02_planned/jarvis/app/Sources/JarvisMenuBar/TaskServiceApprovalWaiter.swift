import Foundation
import JarvisDomain
import JarvisLLM

/// Polls a `TaskServiceAPI` until a previously-submitted approval request
/// reaches a terminal state, then maps the audit summary back to the
/// `ToolResolution` the agent loop understands.
///
/// The audit timeline is the only signal available — there is no push channel
/// from the approval UI. Matching by `actionDigest` (which `ToolRequest`
/// stores verbatim) ensures we look at the right request even when the task
/// has other activity in flight.
public final class TaskServiceApprovalWaiter: ApprovalWaiter, @unchecked Sendable {
    /// Summary string written on the audit event when a tool runs.
    static let toolResultSummary = "tool result"
    /// Summary string written on the audit event when an approved tool fails.
    static let toolFailureSummary = "tool failure"
    /// Summary string written on the audit event when the user rejects the
    /// request.
    static let approvalRejectedSummary = "approval rejected"
    /// Summary string written on the audit event when the whole task is
    /// cancelled while a request is pending.
    static let taskCancelledSummary = "task cancelled"

    private let service: any TaskServiceAPI
    private let pollInterval: TimeInterval
    private let timeout: TimeInterval

    public init(
        service: any TaskServiceAPI,
        pollInterval: TimeInterval = 0.5,
        timeout: TimeInterval = 300
    ) {
        self.service = service
        self.pollInterval = pollInterval
        self.timeout = timeout
    }

    public func waitForResolution(
        requestID: UUID,
        payloadDigest: String,
        taskID: UUID
    ) async throws -> ToolResolution {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let events = try await service.listTimelineEvents(taskID: taskID)

            // Reverse so the most recent matching event wins, in case the
            // timeline ever carries more than one terminal entry per digest.
            for event in events.reversed() {
                guard event.actionDigest == payloadDigest else { continue }
                switch event.summary {
                case Self.toolResultSummary:
                    return .approved(observation: event.result)
                case Self.toolFailureSummary:
                    return .failed(reason: event.result)
                case Self.approvalRejectedSummary:
                    return .rejected(reason: event.result)
                default:
                    continue
                }
            }

            if events.contains(where: { $0.summary == Self.taskCancelledSummary }) {
                return .cancelled
            }

            try await Task.sleep(for: .milliseconds(Int(pollInterval * 1000)))
        }
        return .timedOut
    }
}
