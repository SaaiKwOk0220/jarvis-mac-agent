import Foundation

/// `LLMProvider` backed by a locally running Ollama daemon.
///
/// The default endpoint is `http://127.0.0.1:11434`, the address Ollama binds
/// to out of the box: the model runs on this machine and no prompt leaves it.
/// The provider speaks Ollama's `/api/chat` JSON protocol directly over
/// `URLSession` — no third-party SDK — and always sends `stream: false` so a
/// turn arrives as a single JSON object.
public struct OllamaProvider: LLMProvider {
    public let identifier = "ollama"
    public let baseURL: URL
    public let model: String
    public let session: URLSession
    public let timeout: TimeInterval

    public init(
        baseURL: URL = URL(string: "http://127.0.0.1:11434")!,
        model: String = "llama3.2",
        session: URLSession = .shared,
        timeout: TimeInterval = 120
    ) {
        self.baseURL = baseURL
        self.model = model
        self.session = session
        self.timeout = timeout
    }

    public func complete(messages: [LLMMessage], tools: [LLMTool]) async throws -> LLMResponse {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout
        request.httpBody = try JSONEncoder().encode(
            ChatRequest(model: model, messages: messages, tools: tools)
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw LLMError.unavailable(String(describing: error))
        }

        guard let http = response as? HTTPURLResponse else {
            throw LLMError.invalidResponse("non-HTTP response")
        }
        let body = String(data: data, encoding: .utf8) ?? ""
        guard (200..<300).contains(http.statusCode) else {
            // Ollama answers an unknown model with 404 + {"error": "model ... not found"}.
            if http.statusCode == 404 { throw LLMError.modelNotFound(body) }
            throw LLMError.httpStatus(http.statusCode, body)
        }

        return try Self.map(data: data)
    }

    /// Projects a decoded chat response onto the provider-neutral contract.
    private static func map(data: Data) throws -> LLMResponse {
        guard let decoded = try? JSONDecoder().decode(ChatResponse.self, from: data),
              let message = decoded.message
        else {
            throw LLMError.invalidResponse(String(data: data, encoding: .utf8) ?? "<non-utf8 body>")
        }

        let toolCalls = (message.toolCalls ?? []).enumerated().map { index, call in
            LLMToolCall(
                // Ollama does not assign tool-call ids, so synthesise a stable
                // one for the agent loop to key results off.
                id: call.id ?? "call_\(index)",
                name: call.function.name,
                arguments: call.function.arguments?.flattened ?? [:]
            )
        }

        let usage: LLMUsage? = (decoded.promptEvalCount != nil || decoded.evalCount != nil)
            ? LLMUsage(
                promptTokens: decoded.promptEvalCount ?? 0,
                completionTokens: decoded.evalCount ?? 0
            )
            : nil

        return LLMResponse(
            content: normalisedContent(message.content),
            toolCalls: toolCalls,
            usage: usage
        )
    }

    /// Ollama sends `content: ""` alongside tool calls; treat blank text as
    /// "no text turn" so callers do not have to distinguish "" from nil.
    private static func normalisedContent(_ raw: String?) -> String? {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return raw
    }

    // MARK: - Wire format

    /// Request body in Ollama's tool-calling shape.
    private struct ChatRequest: Encodable {
        let model: String
        let messages: [Message]
        let tools: [Tool]
        let stream = false

        struct Message: Encodable {
            let role: String
            let content: String
        }

        struct Tool: Encodable {
            let type = "function"
            let function: Function

            struct Function: Encodable {
                let name: String
                let description: String
                let parameters: Parameters

                struct Parameters: Encodable {
                    let type = "object"
                    let properties: [String: Property]
                    let required: [String]

                    struct Property: Encodable {
                        let type: String
                        let description: String
                    }
                }
            }
        }

        init(model: String, messages: [LLMMessage], tools: [LLMTool]) {
            self.model = model
            self.messages = messages.map { Message(role: $0.role.rawValue, content: $0.content) }
            self.tools = tools.map { tool in
                Tool(function: .init(
                    name: tool.name,
                    description: tool.description,
                    parameters: .init(
                        properties: tool.parameters.mapValues {
                            .init(type: $0.type, description: $0.description)
                        },
                        // Sorted so the body is byte-stable across runs.
                        required: tool.parameters.filter { $0.value.required }.keys.sorted()
                    )
                ))
            }
        }
    }

    /// Response body: only the fields we consume, everything optional so a
    /// partial or error payload fails as `invalidResponse` rather than crashing.
    private struct ChatResponse: Decodable {
        let message: Message?
        let promptEvalCount: Int?
        let evalCount: Int?

        enum CodingKeys: String, CodingKey {
            case message
            case promptEvalCount = "prompt_eval_count"
            case evalCount = "eval_count"
        }

        struct Message: Decodable {
            let content: String?
            let toolCalls: [ToolCall]?

            enum CodingKeys: String, CodingKey {
                case content
                case toolCalls = "tool_calls"
            }

            struct ToolCall: Decodable {
                let id: String?
                let function: Function

                struct Function: Decodable {
                    let name: String
                    let arguments: Arguments?
                }
            }
        }
    }

    /// Ollama's `arguments` is a free-form JSON object. Some paths also hand it
    /// back as a JSON-encoded string, so accept both shapes.
    private struct Arguments: Decodable {
        let pairs: [String: JSONValue]

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let object = try? container.decode([String: JSONValue].self) {
                pairs = object
            } else if let json = try? container.decode(String.self),
                      let data = json.data(using: .utf8),
                      let object = try? JSONDecoder().decode([String: JSONValue].self, from: data) {
                pairs = object
            } else {
                pairs = [:]
            }
        }

        var flattened: [String: String] { pairs.mapValues(\.flattened) }
    }
}

/// A JSON value of unknown shape, used only to decode and flatten Ollama's
/// tool-call arguments onto `[String: String]`.
private enum JSONValue: Codable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case object([String: JSONValue])
    case array([JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Unsupported JSON value in tool arguments"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        }
    }

    /// Lossless-enough flattening onto a string: scalars keep their literal
    /// form (whole numbers lose the `.0`, booleans become `true`/`false`, JSON
    /// null becomes empty), aggregates are re-encoded as compact JSON so nested
    /// arguments are not silently dropped.
    var flattened: String {
        switch self {
        case .string(let value): return value
        case .number(let value): return Self.format(value)
        case .bool(let value): return value ? "true" : "false"
        case .null: return ""
        case .object, .array:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            guard let data = try? encoder.encode(self) else { return "" }
            return String(data: data, encoding: .utf8) ?? ""
        }
    }

    private static func format(_ value: Double) -> String {
        if value.rounded() == value, abs(value) < 1e15 { return String(Int(value)) }
        return String(value)
    }
}
