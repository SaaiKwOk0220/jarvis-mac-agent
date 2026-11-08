import Foundation

/// `LLMProvider` backed by Anthropic's hosted Claude models.
///
/// The default endpoint is `https://api.anthropic.com/v1/messages`. The
/// provider speaks Anthropic's Messages protocol directly over `URLSession`
/// — no third-party SDK — and issues one non-streaming request per turn, so a
/// turn arrives as a single JSON object.
///
/// This is the cloud counterpart to `OllamaProvider`: same `LLMProvider`
/// contract, so a caller can point the agent loop at either (or configure both
/// and let the user pick). Nothing here chooses between them — provider
/// selection is a UI concern.
///
/// ## Credential handling
///
/// The API key is injected by the caller and never persisted here; there is no
/// Keychain or on-disk storage in this type. An empty key fails fast with
/// `.unavailable` *before* any request is built, so a misconfigured instance
/// never puts a credentialless call on the wire.
public struct AnthropicProvider: LLMProvider {
    public let identifier = "anthropic"
    public let baseURL: URL
    public let apiKey: String
    public let model: String
    public let session: URLSession
    public let maxTokens: Int
    public let timeout: TimeInterval

    /// Value sent in the `anthropic-version` header. Pinned so the wire format
    /// cannot drift under us the way an unversioned endpoint can.
    public static let apiVersion = "2023-06-01"

    public init(
        apiKey: String,
        model: String = "claude-sonnet-4-5",
        baseURL: URL = URL(string: "https://api.anthropic.com")!,
        session: URLSession = .shared,
        maxTokens: Int = 4096,
        timeout: TimeInterval = 120
    ) {
        self.apiKey = apiKey
        self.model = model
        self.baseURL = baseURL
        self.session = session
        self.maxTokens = maxTokens
        self.timeout = timeout
    }

    public func complete(messages: [LLMMessage], tools: [LLMTool]) async throws -> LLMResponse {
        // Fail before building a request: an unauthenticated call is guaranteed
        // to come back 401 and leaks a round-trip to the API for no reason.
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LLMError.unavailable("Anthropic API key not configured")
        }

        guard baseURL.scheme?.lowercased() == "https" else {
            throw LLMError.unavailable("Anthropic endpoint must use HTTPS")
        }
        let projected = try Self.project(messages)

        var request = URLRequest(url: baseURL.appendingPathComponent("v1/messages"))
        request.httpMethod = "POST"
        // Anthropic authenticates with `x-api-key`, not `Authorization: Bearer`.
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout
        request.httpBody = try JSONEncoder().encode(
            MessagesRequest(
                model: model,
                maxTokens: maxTokens,
                system: projected.system,
                messages: projected.messages,
                tools: tools.isEmpty
                    ? nil
                    : tools.map(WireTool.init(tool:))
            )
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request, delegate: RejectRedirectDelegate())
        } catch {
            throw LLMError.unavailable(String(describing: error))
        }

        guard let http = response as? HTTPURLResponse else {
            throw LLMError.invalidResponse("non-HTTP response")
        }
        let body = String(data: data, encoding: .utf8) ?? ""

        switch http.statusCode {
        case 200..<300:
            break
        // The three failures a caller can actually act on — bad credential,
        // throttling, capacity — are collapsed onto `.unavailable` with a
        // human-readable reason so the agent loop can render something better
        // than a bare status code.
        case 401:
            throw LLMError.unavailable("Anthropic API key invalid")
        case 429:
            throw LLMError.unavailable("Anthropic rate limit")
        case 529:
            throw LLMError.unavailable("Anthropic overloaded")
        default:
            throw LLMError.httpStatus(http.statusCode, body)
        }

        return try Self.map(data: data)
    }

    /// Projects a decoded Messages response onto the provider-neutral contract.
    private static func map(data: Data) throws -> LLMResponse {
        guard Self.hasSupportedNumbers(data), let decoded = try? JSONDecoder().decode(MessagesResponse.self, from: data) else {
            throw LLMError.invalidResponse(String(data: data, encoding: .utf8) ?? "<non-utf8 body>")
        }

        guard let blocks = decoded.content, !blocks.isEmpty, blocks.allSatisfy({ block in
            switch block.type {
            case "text": return block.text != nil
            case "tool_use": return !(block.id ?? "").isEmpty && !(block.name ?? "").isEmpty && block.input != nil
            default: return false
            }
        }) else { throw LLMError.invalidResponse("Malformed content blocks") }

        // Several text blocks in one turn are separate paragraphs of the same
        // answer; join rather than take the first so nothing is dropped.
        let text = blocks
            .filter { $0.type == "text" }
            .compactMap(\.text)
            .joined(separator: "\n")

        let toolCalls = blocks
            .filter { $0.type == "tool_use" }
            .enumerated()
            .map { index, block in
                LLMToolCall(
                    // Anthropic always sends an id; synthesise one only so a
                    // malformed payload still yields a usable turn instead of
                    // crashing the loop on a force-unwrap.
                    id: block.id ?? "toolu_\(index)",
                    name: block.name ?? "",
                    arguments: (block.input?.pairs ?? [:]).mapValues(\.flattened),
                    rawInputJSON: block.input.flatMap { try? JSONEncoder().encode($0.pairs) }.flatMap { String(data: $0, encoding: .utf8) }
                )
            }

        let usage: LLMUsage? = (decoded.usage?.inputTokens != nil || decoded.usage?.outputTokens != nil)
            ? LLMUsage(
                promptTokens: decoded.usage?.inputTokens ?? 0,
                completionTokens: decoded.usage?.outputTokens ?? 0
            )
            : nil

        return LLMResponse(
            content: normalisedContent(text),
            toolCalls: toolCalls,
            usage: usage
        )
    }

    /// Reject numeric literals with over 18 significant digits, explicit or
    /// adjusted exponents outside -100...100. This conservative limit applies
    /// to every number in the response, including fields outside tool input.
    /// Inspect bytes before JSONDecoder can round them. JSON strings are skipped.
    static func hasSupportedNumbers(_ data: Data) -> Bool {
        let bytes = Array(data)
        var i = 0
        var inString = false
        var escaped = false
        while i < bytes.count {
            let byte = bytes[i]
            if inString {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { inString = false }
                i += 1
                continue
            }
            if byte == 34 { inString = true; i += 1; continue }
            if byte == 45 || (48...57).contains(byte) {
                let start = i
                while i < bytes.count && ((48...57).contains(bytes[i]) || [45, 43, 46, 69, 101].contains(bytes[i])) { i += 1 }
                let literal = String(decoding: bytes[start..<i], as: UTF8.self)
                let parts = literal.lowercased().split(separator: "e", omittingEmptySubsequences: false)
                guard parts.count <= 2 else { return false }
                let exponent: Int
                if parts.count == 2 {
                    guard let value = Int(parts[1]), value >= -100, value <= 100 else { return false }
                    exponent = value
                } else { exponent = 0 }
                let mantissa = parts[0].split(separator: ".", omittingEmptySubsequences: false)
                guard mantissa.count <= 2 else { return false }
                let fractionCount = mantissa.count == 2 ? mantissa[1].count : 0
                let digits = parts[0].filter { $0.isNumber }
                let trimmed = digits.drop(while: { $0 == "0" })
                if !trimmed.isEmpty {
                    let significant = trimmed.reversed().drop(while: { $0 == "0" })
                    let trailingZeros = trimmed.count - significant.count
                    let adjustedExponent = exponent - fractionCount + trailingZeros
                    if significant.count > 18 || adjustedExponent < -100 || adjustedExponent > 100 { return false }
                }
                continue
            }
            i += 1
        }
        return true
    }

    /// Anthropic sends an empty text block alongside tool calls; treat blank
    /// text as "no text turn" so callers do not distinguish "" from nil.
    private static func normalisedContent(_ raw: String) -> String? {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : raw
    }

    // MARK: - Message projection

    /// The result of reshaping provider-neutral messages into Anthropic's
    /// split between a top-level system prompt and a role-tagged array.
    private struct Projection {
        let system: String?
        let messages: [WireMessage]
    }

    /// Reshapes `[LLMMessage]` into Anthropic's wire shape.
    ///
    /// Two things change:
    ///
    /// 1. **The system prompt is hoisted.** Anthropic takes `system` as a
    ///    top-level string field, never as a message. Several `.system`
    ///    messages are joined with a blank line so nothing is lost.
    ///
    /// 2. **Tool results become `user` turns carrying `tool_result` blocks.**
    ///    There is no `tool` role in Anthropic's vocabulary.
    ///
    private static func project(_ messages: [LLMMessage]) throws -> Projection {
        let systemParts = messages.filter { $0.role == .system }.map(\.content)
        let system = systemParts.isEmpty ? nil : systemParts.joined(separator: "\n\n")

        var wire: [WireMessage] = []

        var index = 0
        while index < messages.count {
            let message = messages[index]

            switch message.role {
            case .system:
                // Already hoisted into the top-level `system` field.
                break
            case .user, .assistant:
                if message.role == .assistant, let calls = message.toolCalls, !calls.isEmpty {
                    var blocks: [WireMessage.Block] = []
                    if !message.content.isEmpty { blocks.append(.init(type: "text", text: message.content)) }
                    for call in calls {
                        let input: [String: AnthropicJSONValue]
                        if let raw = call.rawInputJSON, let data = raw.data(using: .utf8),
                           let decoded = try? JSONDecoder().decode([String: AnthropicJSONValue].self, from: data) {
                            input = decoded
                        } else {
                            input = call.arguments.mapValues { .string($0) }
                        }
                        blocks.append(.init(type: "tool_use", id: call.id, name: call.name, input: input))
                    }
                    wire.append(WireMessage(role: "assistant", content: .blocks(blocks)))
                } else {
                    wire.append(WireMessage(role: message.role.rawValue, content: .text(message.content)))
                }
            case .tool:
                // A run of consecutive observations is one user turn holding
                // several `tool_result` blocks, which is how Anthropic models
                // a parallel tool batch.
                var results: [WireMessage.Block] = []
                while index < messages.count, messages[index].role == .tool {
                    // Deliberately not shaped like a real `toolu_` id so an
                    // accidental leak onto the wire is obvious rather than
                    // plausible.
                    guard let id = messages[index].toolCallID, !id.isEmpty else {
                        throw LLMError.invalidResponse("Missing tool call ID")
                    }
                    results.append(.init(type: "tool_result", toolUseID: id, content: messages[index].content))
                    index += 1
                }
                wire.append(WireMessage(role: "user", content: .blocks(results)))
                continue
            }

            index += 1
        }

        return Projection(system: system, messages: wire)
    }

    // MARK: - Wire format

    /// Request body for `POST /v1/messages`.
    private struct MessagesRequest: Encodable {
        let model: String
        /// Required by Anthropic; there is no server-side default.
        let maxTokens: Int
        let system: String?
        let messages: [WireMessage]
        /// Omitted entirely when the catalog is empty, rather than sent as `[]`.
        let tools: [WireTool]?

        enum CodingKeys: String, CodingKey {
            case model
            case maxTokens = "max_tokens"
            case system
            case messages
            case tools
        }
    }

    /// One Anthropic message. `content` is either a bare string (ordinary
    /// user/assistant turn) or an array of blocks (a tool-result turn).
    private struct WireMessage: Encodable {
        let role: String
        let content: Content

        enum Content: Encodable {
            case text(String)
            case blocks([Block])

            func encode(to encoder: Encoder) throws {
                var container = encoder.singleValueContainer()
                switch self {
                case .text(let value): try container.encode(value)
                case .blocks(let blocks): try container.encode(blocks)
                }
            }
        }

        struct Block: Encodable {
            let type: String
            var toolUseID: String? = nil
            var content: String? = nil
            var text: String? = nil
            var id: String? = nil
            var name: String? = nil
            var input: [String: AnthropicJSONValue]? = nil

            enum CodingKeys: String, CodingKey {
                case type
                case toolUseID = "tool_use_id"
                case content, text, id, name, input
            }
        }
    }

    /// A tool declaration in Anthropic's shape: the schema sits directly on the
    /// tool under `input_schema`, with no OpenAI-style `function` wrapper.
    private struct WireTool: Encodable {
        let name: String
        let description: String
        let inputSchema: Schema

        enum CodingKeys: String, CodingKey {
            case name
            case description
            case inputSchema = "input_schema"
        }

        struct Schema: Encodable {
            let type = "object"
            let properties: [String: Property]
            let required: [String]

            struct Property: Encodable {
                let type: String
                let description: String
            }
        }

        init(tool: LLMTool) {
            self.name = tool.name
            self.description = tool.description
            self.inputSchema = Schema(
                properties: tool.parameters.mapValues {
                    .init(type: $0.type, description: $0.description)
                },
                // Sorted so the body is byte-stable across runs.
                required: tool.parameters.filter { $0.value.required }.keys.sorted()
            )
        }
    }

    /// Response body: only the fields we consume, everything optional so a
    /// partial or error payload fails as `invalidResponse` rather than crashing.
    private struct MessagesResponse: Decodable {
        let content: [Block]?
        /// Decoded for completeness. `LLMResponse` has no field to carry a stop
        /// reason, so it is intentionally dropped rather than smuggled into
        /// `content`.
        let stopReason: String?
        let usage: Usage?

        enum CodingKeys: String, CodingKey {
            case content
            case stopReason = "stop_reason"
            case usage
        }

        struct Block: Decodable {
            let type: String
            let text: String?
            let id: String?
            let name: String?
            let input: Arguments?
        }

        struct Usage: Decodable {
            let inputTokens: Int?
            let outputTokens: Int?

            enum CodingKeys: String, CodingKey {
                case inputTokens = "input_tokens"
                case outputTokens = "output_tokens"
            }
        }
    }

    /// A tool call's `input` is a free-form JSON object. Some paths hand it back
    /// as a JSON-encoded string, so accept both shapes.
    private struct Arguments: Decodable {
        let pairs: [String: AnthropicJSONValue]

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let object = try? container.decode([String: AnthropicJSONValue].self) {
                pairs = object
            } else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid tool input")
            }
        }
    }
}

/// A JSON value of unknown shape, used only to decode and flatten Anthropic's
/// tool-call input onto `[String: String]`.
private enum AnthropicJSONValue: Codable {
    case string(String)
    case number(Decimal)
    case bool(Bool)
    case null
    case object([String: AnthropicJSONValue])
    case array([AnthropicJSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Decimal.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: AnthropicJSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([AnthropicJSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Unsupported JSON value in tool input"
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
        case .number(let value): return NSDecimalNumber(decimal: value).stringValue
        case .bool(let value): return value ? "true" : "false"
        case .null: return ""
        case .object, .array:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            guard let data = try? encoder.encode(self) else { return "" }
            return String(data: data, encoding: .utf8) ?? ""
        }
    }


}

final class RejectRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
