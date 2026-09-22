import Foundation

/// An approval-aware orchestrator around `AgentLoop`.
///
/// `AgentLoop` is the pure coordination layer that turns tool calls into a
/// `.tool` message and feeds observations back to the model. When a tool
/// needs human sign-off the loop has to stop, because the policy gate and the
/// approval UI live outside the LLM. `AgentSession` wraps the same loop body
/// and, on `.awaitingApproval`, transparently blocks on an `ApprovalWaiter`
/// before resuming the run.
///
/// The loop's contract is unchanged: a session takes the same inputs (a goal,
/// a provider, a runner), emits the same `AgentLoopEvent` stream, and
/// terminates with the same `AgentLoopResult` outcomes a caller already knows
/// how to handle. The only behaviour added is that an approval-gated tool no
/// longer ends the run.
public struct AgentSession: Sendable {
    public let provider: any LLMProvider
    public let runner: any AgentToolRunner
    public let approvalWaiter: any ApprovalWaiter
    public let taskID: UUID
    public let maxIterations: Int
    public let systemPrompt: String

    public init(
        provider: any LLMProvider,
        runner: any AgentToolRunner,
        approvalWaiter: any ApprovalWaiter,
        taskID: UUID,
        maxIterations: Int = 8,
        systemPrompt: String = AgentLoop.defaultSystemPrompt
    ) {
        self.provider = provider
        self.runner = runner
        self.approvalWaiter = approvalWaiter
        self.taskID = taskID
        self.maxIterations = maxIterations
        self.systemPrompt = systemPrompt
    }

    /// Drives the loop for one goal, transparently waiting for any tool
    /// approvals. See `AgentLoop.run(goal:onEvent:)` for the semantics of
    /// `onEvent`; this session emits the same events plus nothing new.
    public func run(
        goal: String,
        onEvent: (@Sendable (AgentLoopEvent) -> Void)? = nil
    ) async throws -> AgentLoopResult {
        var messages: [LLMMessage] = [
            LLMMessage(role: .system, content: systemPrompt),
            LLMMessage(role: .user, content: goal),
        ]

        for _ in 0..<maxIterations {
            let response = try await provider.complete(messages: messages, tools: runner.tools())

            if let text = response.content, !text.isEmpty {
                onEvent?(.assistantText(text))
            }

            if response.toolCalls.isEmpty {
                return .completed(finalText: response.content ?? "")
            }

            messages.append(LLMMessage(role: .assistant, content: response.content ?? ""))

            for call in response.toolCalls {
                onEvent?(.toolCallRequested(call))
                switch try await runner.perform(call) {
                case .executed(let observation):
                    onEvent?(.toolCallSucceeded(name: call.name, observation: observation))
                    messages.append(LLMMessage(role: .tool, content: observation))

                case .awaitingApproval(let requestID, let payloadDigest, let description):
                    onEvent?(.awaitingApproval(requestID: requestID, description: description))
                    let resolution = try await approvalWaiter.waitForResolution(
                        requestID: requestID,
                        payloadDigest: payloadDigest,
                        taskID: taskID
                    )
                    switch resolution {
                    case .approved(let observation):
                        onEvent?(.toolCallSucceeded(name: call.name, observation: observation))
                        messages.append(LLMMessage(role: .tool, content: observation))
                    case .rejected(let reason):
                        onEvent?(.toolCallDenied(name: call.name, reason: reason))
                        messages.append(LLMMessage(role: .tool, content: "denied: \(reason)"))
                    case .failed(let reason):
                        return .exceededIterations(lastText: reason)
                    case .cancelled:
                        return .exceededIterations(lastText: "cancelled by user")
                    case .timedOut:
                        return .exceededIterations(lastText: "approval timed out")
                    }

                case .denied(let reason):
                    onEvent?(.toolCallDenied(name: call.name, reason: reason))
                    messages.append(LLMMessage(role: .tool, content: "denied: \(reason)"))
                }
            }
        }

        return .exceededIterations(
            lastText: messages.last(where: { $0.role == .assistant })?.content
        )
    }
}
