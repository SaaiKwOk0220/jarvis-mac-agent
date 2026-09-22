import Foundation

/// Bridge between the LLM's tool calls and Jarvis's tool execution layer.
/// The loop itself knows nothing about `TaskService` or approvals; it only
/// sees this protocol. Routing the real catalog through Jarvis's policy and
/// approval gate is the runner's job, which is why a call can come back as
/// `.awaitingApproval` rather than a plain answer.
public protocol AgentToolRunner: Sendable {
    /// The tool catalog to advertise to the LLM for this run.
    func tools() -> [LLMTool]

    /// Execute (or fail to execute) one tool call. Implementations are
    /// expected to route through Jarvis's policy + approval gate, which is
    /// why the outcome can be `.awaitingApproval` rather than a string.
    func perform(_ call: LLMToolCall) async throws -> AgentToolOutcome
}

/// What happened when the loop asked the runner to perform a tool call.
public enum AgentToolOutcome: Sendable, Equatable {
    /// Tool ran; the string is the observation fed back to the LLM.
    case executed(String)
    /// Policy requires a human decision before the tool can run. The caller
    /// uses `payloadDigest` to locate the corresponding audit event so a
    /// `ApprovalWaiter` can block until the request resolves.
    case awaitingApproval(requestID: UUID, payloadDigest: String, description: String)
    /// Policy denied the tool outright. The reason is fed back to the LLM
    /// so it can pick a different plan.
    case denied(String)
}
