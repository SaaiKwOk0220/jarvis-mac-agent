import Foundation
import XCTest
@testable import JarvisLLM

/// Builds the canned `HTTPURLResponse` the mock hands back to URLSession.
private func anthropicJSONResponse(_ request: URLRequest, status: Int = 200) -> HTTPURLResponse {
    HTTPURLResponse(
        url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/json"])!
}

/// URLSession rewrites a POST `httpBody` into `httpBodyStream` before it
/// reaches a custom `URLProtocol`, so reading `request.httpBody` alone yields
/// nil inside the mock handler. This drains whichever representation is set.
private func anthropicBodyData(of request: URLRequest) -> Data? {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }
    var data = Data()
    let bufferSize = 4096
    var buffer = [UInt8](repeating: 0, count: bufferSize)
    while stream.hasBytesAvailable {
        let read = stream.read(&buffer, maxLength: bufferSize)
        if read <= 0 { break }
        data.append(buffer, count: read)
    }
    return data
}

/// Thread-safe single-slot box for capturing values out of the `@Sendable`
/// URLProtocol handler back into the test method.
private final class AnthropicLockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(initial: T) { self.value = initial }
    func set(_ new: T) { lock.withLock { value = new } }
    func get() -> T { lock.withLock { value } }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T { lock(); defer { unlock() }; return try body() }
}

final class AnthropicProviderTests: XCTestCase {

    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    private func makeProvider(apiKey: String = "test-key") -> AnthropicProvider {
        AnthropicProvider(apiKey: apiKey, session: MockURLSessionFactory.make())
    }

    private var shellTool: LLMTool {
        LLMTool(
            name: "shell",
            description: "Run a shell command on the local machine.",
            parameters: ["command": LLMToolParameter(type: "string", description: "The command to run.")]
        )
    }

    /// A text-only turn is surfaced as `content`, with Anthropic's
    /// `input_tokens` / `output_tokens` mapped onto `LLMUsage`.
    func testCompleteParsesTextResponse() async throws {
        let payload = """
        {"id": "msg_1", "content": [{"type": "text", "text": "Hello"}],
         "stop_reason": "end_turn", "usage": {"input_tokens": 10, "output_tokens": 5}}
        """
        MockURLProtocol.handler = { request in
            (anthropicJSONResponse(request), Data(payload.utf8))
        }

        let response = try await makeProvider().complete(
            messages: [LLMMessage(role: .user, content: "hi")],
            tools: []
        )

        XCTAssertEqual(response.content, "Hello")
        XCTAssertEqual(response.usage?.promptTokens, 10)
        XCTAssertEqual(response.usage?.completionTokens, 5)
        XCTAssertTrue(response.toolCalls.isEmpty)
    }

    /// A `tool_use` content block is surfaced as an `LLMToolCall`: the
    /// server-assigned `toolu_` id is carried through (unlike Ollama, which
    /// needs one synthesised) and the free-form `input` object is flattened.
    func testCompleteParsesToolUseResponse() async throws {
        let payload = """
        {"id": "msg_2", "content": [
            {"type": "tool_use", "id": "toolu_abc", "name": "shell", "input": {"command": "ls"}}
         ], "stop_reason": "tool_use"}
        """
        MockURLProtocol.handler = { request in
            (anthropicJSONResponse(request), Data(payload.utf8))
        }

        let response = try await makeProvider().complete(
            messages: [LLMMessage(role: .user, content: "list the files")],
            tools: [shellTool]
        )

        XCTAssertNil(response.content)
        XCTAssertEqual(response.toolCalls.count, 1)
        let call = try XCTUnwrap(response.toolCalls.first)
        XCTAssertEqual(call.id, "toolu_abc")
        XCTAssertEqual(call.name, "shell")
        XCTAssertEqual(call.arguments["command"], "ls")
    }

    /// The system prompt must ride in the top-level `system` field, *not* as a
    /// message: Anthropic rejects a `system` role inside `messages`. The
    /// request also has to carry Anthropic's auth and version headers, which
    /// differ from a bearer-token API.
    func testCompleteSendsSystemPromptAsTopLevelField() async throws {
        let capturedRequest = AnthropicLockedBox<URLRequest?>(initial: nil)
        let capturedBody = AnthropicLockedBox<Data?>(initial: nil)
        MockURLProtocol.handler = { request in
            capturedRequest.set(request)
            capturedBody.set(anthropicBodyData(of: request))
            return (anthropicJSONResponse(request), Data(#"{"content": [{"type": "text", "text": "ok"}]}"#.utf8))
        }

        _ = try await makeProvider().complete(
            messages: [
                LLMMessage(role: .system, content: "You are Jarvis."),
                LLMMessage(role: .user, content: "hi"),
            ],
            tools: []
        )

        let request = try XCTUnwrap(capturedRequest.get())
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "test-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), AnthropicProvider.apiVersion)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))

        let body = try XCTUnwrap(capturedBody.get())
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(root["model"] as? String, "claude-sonnet-4-5")
        XCTAssertEqual(root["max_tokens"] as? Int, 4096)
        XCTAssertEqual(root["system"] as? String, "You are Jarvis.")

        // The system prompt must not also appear as a message, or Anthropic
        // rejects the request for an unexpected `system` role.
        let messages = try XCTUnwrap(root["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0]["role"] as? String, "user")
        XCTAssertEqual(messages[0]["content"] as? String, "hi")
    }

    /// Tool declarations use Anthropic's shape: the schema sits directly on the
    /// tool under `input_schema`, with no OpenAI-style `function` wrapper.
    func testCompleteSendsToolsWithInputSchema() async throws {
        let capturedBody = AnthropicLockedBox<Data?>(initial: nil)
        MockURLProtocol.handler = { request in
            capturedBody.set(anthropicBodyData(of: request))
            return (anthropicJSONResponse(request), Data(#"{"content": [{"type": "text", "text": "ok"}]}"#.utf8))
        }

        _ = try await makeProvider().complete(
            messages: [LLMMessage(role: .user, content: "list the files")],
            tools: [shellTool]
        )

        let body = try XCTUnwrap(capturedBody.get())
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let tools = try XCTUnwrap(root["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools[0]["name"] as? String, "shell")
        XCTAssertEqual(tools[0]["description"] as? String, "Run a shell command on the local machine.")
        XCTAssertNil(tools[0]["function"])

        let schema = try XCTUnwrap(tools[0]["input_schema"] as? [String: Any])
        XCTAssertEqual(schema["type"] as? String, "object")
        XCTAssertEqual(schema["required"] as? [String], ["command"])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let command = try XCTUnwrap(properties["command"] as? [String: Any])
        XCTAssertEqual(command["type"] as? String, "string")
        XCTAssertEqual(command["description"] as? String, "The command to run.")
    }

    /// A rejected credential is a configuration problem the caller can fix, so
    /// it surfaces as `.unavailable` with a reason rather than a bare 401.
    func testCompleteMaps401ToUnavailable() async throws {
        MockURLProtocol.handler = { request in
            (anthropicJSONResponse(request, status: 401), Data(#"{"error": {"type": "authentication_error"}}"#.utf8))
        }

        do {
            _ = try await makeProvider().complete(
                messages: [LLMMessage(role: .user, content: "hi")],
                tools: []
            )
            XCTFail("Expected a 401 to throw")
        } catch let error as LLMError {
            guard case .unavailable = error else {
                return XCTFail("expected .unavailable, got \(error)")
            }
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    /// An unconfigured key fails fast and locally: the provider must not put a
    /// credentialless request on the wire and burn a round-trip to the API.
    func testCompleteReturnsUnavailableWhenAPIKeyEmpty() async throws {
        let requestCount = AnthropicLockedBox<Int>(initial: 0)
        MockURLProtocol.handler = { request in
            requestCount.set(requestCount.get() + 1)
            return (anthropicJSONResponse(request), Data(#"{"content": []}"#.utf8))
        }

        do {
            _ = try await makeProvider(apiKey: "").complete(
                messages: [LLMMessage(role: .user, content: "hi")],
                tools: []
            )
            XCTFail("Expected an empty API key to throw")
        } catch let error as LLMError {
            guard case .unavailable = error else {
                return XCTFail("expected .unavailable, got \(error)")
            }
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertEqual(requestCount.get(), 0, "an empty key must not reach the network")
    }
}
