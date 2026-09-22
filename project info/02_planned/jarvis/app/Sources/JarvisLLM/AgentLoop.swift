import Foundation

/// How a run of `AgentLoop` ended.
public enum AgentLoopResult: Sendable, Equatable {
    /// The LLM produced a final answer with no further tool calls.
    case completed(finalText: String)
    /// The loop stopped because a tool call needs explicit approval. The
    /// caller resumes once the approval resolves.
    case awaitingApproval(requestID: UUID, description: String)
    /// The LLM kept calling tools past `maxIterations`. The last assistant
    /// text, if any, is carried out so the caller can show partial progress.
    case exceededIterations(lastText: String?)
}

/// A single observable step of a run. The loop emits these as they happen so
/// a caller can stream progress (assistant text, each tool call, each result)
/// into a UI without the loop needing to know about that UI.
///
/// The events mirror `AgentLoop`'s internal transitions one-for-one; a caller
/// that ignores them sees exactly the same run as one that observes everything.
public enum AgentLoopEvent: Sendable, Equatable {
    /// The model produced text on a turn (with or without tool calls).
    case assistantText(String)
    /// The model asked for a tool call, before the runner has acted on it.
    case toolCallRequested(LLMToolCall)
    /// The runner executed the call; `observation` is what was fed back.
    case toolCallSucceeded(name: String, observation: String)
    /// Policy refused the call; `reason` is what was fed back for re-planning.
    case toolCallDenied(name: String, reason: String)
    /// The run is stopping because the call needs a human decision.
    case awaitingApproval(requestID: UUID, description: String)
}

/// A ReAct-style agent loop: seed the model with the goal, let it choose tool
/// calls, execute each one through an `AgentToolRunner`, feed the observation
/// back as a `.tool` message, and repeat until the model answers with text or
/// the iteration budget runs out.
///
/// The loop is deliberately ignorant of whatever sits behind the runner — it
/// never touches `TaskService`, never inspects policy, and never runs a tool
/// itself. That keeps it a pure coordination layer that any tool backend can
/// drive, and means an approval-gated tool cleanly pauses the run instead of
/// being silently skipped.
public struct AgentLoop: Sendable {
    public let provider: any LLMProvider
    public let runner: any AgentToolRunner
    public let maxIterations: Int
    public let systemPrompt: String

    public init(
        provider: any LLMProvider,
        runner: any AgentToolRunner,
        maxIterations: Int = 8,
        systemPrompt: String = AgentLoop.defaultSystemPrompt
    ) {
        self.provider = provider
        self.runner = runner
        self.maxIterations = maxIterations
        self.systemPrompt = systemPrompt
    }

    /// Drives the loop for one goal and reports how it terminated.
    ///
    /// `onEvent` is optional and purely observational: the run's behaviour and
    /// result are identical whether or not it is supplied, so existing callers
    /// can pass nothing and ignore progress reporting entirely. The callback is
    /// invoked on whatever executor the loop happens to run on, so a UI must
    /// marshal to its own actor before touching view state.
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

            // No tool calls means the model is answering, not planning: the
            // run is done and its text is the result.
            if response.toolCalls.isEmpty {
                return .completed(finalText: response.content ?? "")
            }

            // Record the assistant's plan so the model sees its own tool calls
            // on the next turn rather than a conversation that skips a beat.
            messages.append(LLMMessage(role: .assistant, content: response.content ?? ""))

            for call in response.toolCalls {
                onEvent?(.toolCallRequested(call))
                switch try await runner.perform(call) {
                case .executed(let observation):
                    onEvent?(.toolCallSucceeded(name: call.name, observation: observation))
                    messages.append(LLMMessage(role: .tool, content: observation))
                case .awaitingApproval(let requestID, _, let description):
                    // Stop the run here; the caller picks it up once a human
                    // has resolved the approval. `AgentSession` keeps the
                    // digest so a `ApprovalWaiter` can locate the matching
                    // terminal audit event once the request resolves.
                    onEvent?(.awaitingApproval(requestID: requestID, description: description))
                    return .awaitingApproval(requestID: requestID, description: description)
                case .denied(let reason):
                    // Hand the refusal back so the model can re-plan rather
                    // than retrying the same denied call.
                    onEvent?(.toolCallDenied(name: call.name, reason: reason))
                    messages.append(LLMMessage(role: .tool, content: "denied: \(reason)"))
                }
            }
        }

        return .exceededIterations(lastText: messages.last(where: { $0.role == .assistant })?.content)
    }

    /// Instructs the model to work one tool call at a time and to stop when it
    /// can answer, so the loop's iteration budget is spent on real progress.
    public static let defaultSystemPrompt = """
    You are Jarvis, a local-first personal agent. Break the user's goal into \
    tool calls, one step at a time. After each tool result, decide whether to \
    call another tool or answer. Prefer the smallest number of tool calls that \
    accomplishes the goal. If a tool is denied, pick a different approach. When \
    you are done, respond with text and no tool calls.
    """
}
