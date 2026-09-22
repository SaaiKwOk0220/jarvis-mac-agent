import Foundation

/// How a `.awaitingApproval` outcome eventually resolved, observed by the
/// session that was waiting on it.
public enum ToolResolution: Sendable, Equatable {
    /// The user approved the request and the tool ran; `observation` is the
    /// tool output that should be fed back to the model.
    case approved(observation: String)
    /// The user rejected the request; `reason` is the user-supplied reason.
    case rejected(reason: String)
    /// The tool was approved but failed at execution time; `reason` is the
    /// error string.
    case failed(reason: String)
    /// The whole task was cancelled while the request was pending.
    case cancelled
    /// The waiter gave up before the request reached a terminal state.
    case timedOut
}

/// Bridges the LLM's "tool needs approval" pause to whatever records the
/// decision. Implementations poll because there is no native event channel
/// from the approval UI back into the agent loop.
public protocol ApprovalWaiter: Sendable {
    /// Wait for the given request to reach a terminal state.
    ///
    /// - Parameters:
    ///   - requestID: The id of the `ToolRequest` the runner submitted.
    ///   - payloadDigest: The action digest recorded on the audit event for
    ///     this request — used to disambiguate from other work on the task.
    ///   - taskID: The task the request belongs to, so the waiter can read
    ///     its audit timeline.
    func waitForResolution(
        requestID: UUID,
        payloadDigest: String,
        taskID: UUID
    ) async throws -> ToolResolution
}
