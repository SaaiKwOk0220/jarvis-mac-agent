import Foundation

/// One turn in a conversation handed to an `LLMProvider`. Roles mirror the
/// OpenAI/Ollama wire vocabulary so a provider can map them straight through.
public struct LLMMessage: Codable, Equatable, Sendable {
    public enum Role: String, Codable, Equatable, Sendable {
        case system, user, assistant, tool
    }

    public let role: Role
    public let content: String

    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }
}

/// A single named parameter of an `LLMTool`, described with the small subset
/// of JSON Schema the local tool catalog actually needs.
public struct LLMToolParameter: Codable, Equatable, Sendable {
    /// JSON Schema primitive: `"string"`, `"number"` or `"boolean"`.
    public let type: String
    public let description: String
    public let required: Bool

    public init(type: String, description: String, required: Bool = true) {
        self.type = type
        self.description = description
        self.required = required
    }
}

/// A tool the model may call, declared in provider-neutral terms. Each
/// provider is responsible for projecting this onto its own function-calling
/// schema.
public struct LLMTool: Codable, Equatable, Sendable {
    public let name: String
    public let description: String
    public let parameters: [String: LLMToolParameter]

    public init(name: String, description: String, parameters: [String: LLMToolParameter]) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

/// A function invocation requested by the model. Arguments are flattened to
/// strings so the same type can carry values from providers that only emit
/// JSON strings; the executor is expected to coerce back as needed.
public struct LLMToolCall: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let arguments: [String: String]

    public init(id: String, name: String, arguments: [String: String]) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

/// Token accounting reported by a provider. Providers that omit usage leave
/// it nil on the enclosing `LLMResponse`.
public struct LLMUsage: Codable, Equatable, Sendable {
    public let promptTokens: Int
    public let completionTokens: Int

    public init(promptTokens: Int, completionTokens: Int) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
    }
}

/// A single assistant turn: either free text, one or more tool calls, or both.
public struct LLMResponse: Codable, Equatable, Sendable {
    public let content: String?
    public let toolCalls: [LLMToolCall]
    public let usage: LLMUsage?

    public init(content: String?, toolCalls: [LLMToolCall], usage: LLMUsage?) {
        self.content = content
        self.toolCalls = toolCalls
        self.usage = usage
    }
}

/// Provider-neutral failures. Callers can branch on these without importing a
/// provider-specific error type.
public enum LLMError: Error, Equatable, Sendable {
    /// Network-level failure: connection refused, DNS, timeout, offline.
    case unavailable(String)
    /// The provider is reachable but does not serve the requested model.
    case modelNotFound(String)
    /// A 2xx response whose body could not be understood.
    case invalidResponse(String)
    /// A non-2xx HTTP status, carrying the code and the raw response body.
    case httpStatus(Int, String)
}
