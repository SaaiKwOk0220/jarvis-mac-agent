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

        let projected = Self.project(messages)

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
            (data, response) = try await session.data(for: request)
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
        guard let decoded = try? JSONDecoder().decode(MessagesResponse.self, from: data) else {
            throw LLMError.invalidResponse(String(data: data, encoding: .utf8) ?? "<non-utf8 body>")
        }

        let blocks = decoded.content ?? []

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
                    arguments: (block.input?.pairs ?? [:]).mapValues(\.flattened)
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
    /// The second mapping has a wrinkle: a `tool_result` block must cite the
    /// `tool_use_id` of the assistant block it answers, but `LLMMessage` has no
    /// field carrying that id — `AgentLoop` replays the assistant's turn as its
    /// text alone and appends tool observations as bare `.tool` messages. We
    /// recover the pairing positionally: a run of observations is one parallel
    /// tool batch, and each one is assigned the next locally-synthesised id in
    /// order. Because a turn is re-projected from the same message array on
    /// every call, the ids are stable within a request.
    ///
    /// This is enough for the single-turn and text-only paths, and it keeps
    /// `LLMMessage` free of a provider-specific field. It is not yet faithful
    /// enough for the server to accept a replayed tool turn: the assistant turn
    /// is sent as text only, so there is no `tool_use` block for the server to
    /// match the `tool_result` against. Fully faithful multi-turn tool replay
    /// needs a `toolCallID` on `LLMMessage`; that is a follow-up, since adding
    /// it means touching the contract introduced with `OllamaProvider`.
    private static func project(_ messages: [LLMMessage]) -> Projection {
        let systemParts = messages.filter { $0.role == .system }.map(\.content)
        let system = systemParts.isEmpty ? nil : systemParts.joined(separator: "\n\n")

        var wire: [WireMessage] = []
        var synthesised = 0

        var index = 0
        while index < messages.count {
            let message = messages[index]

            switch message.role {
            case .system:
                // Already hoisted into the top-level `system` field.
                break
            case .user, .assistant:
                wire.append(WireMessage(role: message.role.rawValue, content: .text(message.content)))
            case .tool:
                // A run of consecutive observations is one user turn holding
                // several `tool_result` blocks, which is how Anthropic models
                // a parallel tool batch.
                var results: [WireMessage.Block] = []
                while index < messages.count, messages[index].role == .tool {
                    // Deliberately not shaped like a real `toolu_` id so an
                    // accidental leak onto the wire is obvious rather than
                    // plausible.
                    results.append(.init(
                        type: "tool_result",
                        toolUseID: "toolu_local_\(synthesised)",
                        content: messages[index].content
                    ))
                    synthesised += 1
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
            let toolUseID: String?
            let content: String?

            enum CodingKeys: String, CodingKey {
                case type
                case toolUseID = "tool_use_id"
                case content
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
            } else if let json = try? container.decode(String.self),
                      let data = json.data(using: .utf8),
                      let object = try? JSONDecoder().decode([String: AnthropicJSONValue].self, from: data) {
                pairs = object
            } else {
                pairs = [:]
            }
        }
    }
}

/// A JSON value of unknown shape, used only to decode and flatten Anthropic's
/// tool-call input onto `[String: String]`.
private enum AnthropicJSONValue: Codable {
    case string(String)
    case number(Double)
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
        } else if let value = try? container.decode(Double.self) {
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
