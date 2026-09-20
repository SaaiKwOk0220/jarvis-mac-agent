import Foundation

/// A local or remote large-language-model backend.
///
/// Implementations are responsible for translating the provider-neutral
/// `LLMMessage` / `LLMTool` types onto their own wire format and for
/// normalising failures into `LLMError`. They must be safe to share across
/// tasks — the agent loop issues calls concurrently.
public protocol LLMProvider: Sendable {
    /// Human-readable provider identifier, e.g. `"ollama"` or `"anthropic"`.
    var identifier: String { get }

    /// Sends a conversation plus the available tool catalog and returns either
    /// assistant text, one or more tool calls, or both.
    func complete(messages: [LLMMessage], tools: [LLMTool]) async throws -> LLMResponse
}
