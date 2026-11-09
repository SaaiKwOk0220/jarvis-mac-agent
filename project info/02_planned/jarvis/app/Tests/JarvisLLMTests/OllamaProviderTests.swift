import Foundation
import XCTest
@testable import JarvisLLM

/// URLProtocol subclass that intercepts URLSession requests and returns a
/// canned HTTPURLResponse + Data without touching the network. Each test sets
/// `MockURLProtocol.handler` to a closure that inspects the URLRequest and
/// returns the desired response, and resets the handler to nil in the tearDown
/// so a follow-up test that forgets to set its own handler does not silently
/// hit the network.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data?))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: NSError(
                domain: "MockURLProtocol", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "MockURLProtocol.handler not set"]))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if let data { client?.urlProtocol(self, didLoad: data) }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

enum MockURLSessionFactory {
    static func make() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }
}

/// Builds the canned `HTTPURLResponse` the mock hands back to URLSession.
private func jsonResponse(_ request: URLRequest, status: Int = 200) -> HTTPURLResponse {
    HTTPURLResponse(
        url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/json"])!
}

/// URLSession rewrites a POST `httpBody` into `httpBodyStream` before it
/// reaches a custom `URLProtocol`, so reading `request.httpBody` alone yields
/// nil inside the mock handler. This drains whichever representation is set.
private func bodyData(of request: URLRequest) -> Data? {
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

/// Thread-safe single-slot box for capturing values from a `@Sendable`
/// closure back into the test method. URLSession invokes the URLProtocol
/// handler on its internal queue, so the closure must not capture a `var`
/// directly.
private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(initial: T) { self.value = initial }
    func set(_ new: T) { lock.withLock { value = new } }
    func get() -> T { lock.withLock { value } }
}

private extension NSLock { func withLock<T>(_ body: () throws -> T) rethrows -> T { lock(); defer { unlock() }; return try body() } }

final class OllamaProviderTests: XCTestCase {
    /// Opt in with JARVIS_OLLAMA_INTEGRATION=1; requires a running local Ollama
    /// with qwen3:4b-instruct downloaded. Model output is nondeterministic,
    /// so this diagnostic is deliberately not a required CI check.
    func testLiveQwenConversationAndSimulatedToolRoundTrip() async throws {
        guard ProcessInfo.processInfo.environment["JARVIS_OLLAMA_INTEGRATION"] == "1" else {
            throw XCTSkip("Set JARVIS_OLLAMA_INTEGRATION=1 to run the local model integration test")
        }
        let provider = OllamaProvider(model: "qwen3:4b-instruct", timeout: 120)
        let chat = try await provider.complete(messages: [.init(role: .user, content: "Reply with exactly: OK")], tools: [])
        XCTAssertFalse((chat.content ?? "").isEmpty, "Qwen returned no conversational answer")

        let tool = LLMTool(name: "get_weather", description: "Get weather for a city", parameters: [
            "city": LLMToolParameter(type: "string", description: "City name")
        ])
        let marker = "73149"
        let runner = SessionScriptedRunner(tools: [tool], outcomes: ["get_weather": .executed("The weather code is \(marker).")])
        let waiter = ScriptedApprovalWaiter(resolutions: [])
        let session = AgentSession(provider: provider, runner: runner, approvalWaiter: waiter, taskID: UUID(), maxIterations: 3)
        let final = try await session.run(goal: "Use get_weather for Paris, then report the exact weather code returned by the tool. Never guess the code.")
        XCTAssertFalse(runner.performedCalls.isEmpty, "Qwen did not request the simulated tool")
        XCTAssertTrue(runner.performedCalls.allSatisfy { $0.name == "get_weather" && $0.arguments["city"]?.lowercased() == "paris" }, "Unexpected tool or city")
        guard case .completed(let text) = final else { return XCTFail("Session did not complete: \(final)") }
        XCTAssertTrue(text.contains(marker), "Final answer did not consume the simulated tool result: \(text)")
    }
    func testOrdinaryContentWithThinkMarkerIsPreserved() async throws {
        MockURLProtocol.handler = { request in
            (jsonResponse(request), Data(#"{"message":{"content":"Let me think. </think> 2+3=5"}}"#.utf8))
        }
        let response = try await OllamaProvider(model: "qwen3:4b", session: MockURLSessionFactory.make()).complete(messages: [], tools: [])
        XCTAssertEqual(response.content, "Let me think. </think> 2+3=5")
    }
    func testRejectsInvalidRawInputBeforeSending() async throws {
        let call = LLMToolCall(id: "1", name: "shell", arguments: [:], rawInputJSON: "{bad}")
        do { _ = try await makeProvider().complete(messages: [.init(role: .assistant, content: "", toolCalls: [call])], tools: []); XCTFail("expected invalid input") }
        catch let error as LLMError { guard case .invalidResponse = error else { return XCTFail("wrong error") } }
    }

    func testRejectsEmptyResponseAndRedactsErrors() async throws {
        MockURLProtocol.handler = { request in (jsonResponse(request), Data(#"{"message":{}}"#.utf8)) }
        do { _ = try await makeProvider().complete(messages: [], tools: []); XCTFail("expected invalid response") }
        catch let error as LLMError { guard case .invalidResponse = error else { return XCTFail("wrong error") } }
        XCTAssertFalse(LLMError.invalidResponse("secret").localizedDescription.contains("secret"))
        XCTAssertFalse(LLMError.httpStatus(500, "secret").localizedDescription.contains("secret"))
    }

    func testDecodedNumberSurvivesSecondRequest() async throws {
        let captured = LockedBox<Data?>(initial: nil)
        MockURLProtocol.handler = { request in
            (jsonResponse(request), Data(#"{"message":{"content":"","tool_calls":[{"function":{"name":"shell","arguments":{"value":9007199254740993}}}]}}"#.utf8))
        }
        let provider = makeProvider()
        let first = try await provider.complete(messages: [], tools: [])
        MockURLProtocol.handler = { request in
            captured.set(bodyData(of: request))
            return (jsonResponse(request), Data(#"{"message":{"content":"done"}}"#.utf8))
        }
        _ = try await provider.complete(messages: [.init(role: .assistant, content: "", toolCalls: first.toolCalls)], tools: [])
        XCTAssertTrue(String(data: try XCTUnwrap(captured.get()), encoding: .utf8)?.contains("9007199254740993") == true)
    }

    func testMissingModelMaps404() async throws {
        MockURLProtocol.handler = { request in (jsonResponse(request, status: 404), Data("secret".utf8)) }
        do { _ = try await makeProvider().complete(messages: [], tools: []); XCTFail("expected missing model") }
        catch let error as LLMError {
            guard case .modelNotFound = error else { return XCTFail("wrong error") }
            XCTAssertFalse(error.localizedDescription.contains("secret"))
        }
    }

    func testDefaultModelIsQwen() {
        XCTAssertEqual(OllamaProvider().model, "qwen3:4b-instruct")
    }

    func testUnavailableAndMissingModelHaveActionableMessages() {
        XCTAssertFalse(LLMError.unavailable("private diagnostic").localizedDescription.contains("private diagnostic"))
        XCTAssertTrue(LLMError.ollamaUnavailable("private diagnostic").localizedDescription.contains("Ollama"))
        XCTAssertFalse(LLMError.ollamaUnavailable("private diagnostic").localizedDescription.contains("private diagnostic"))
        XCTAssertTrue(LLMError.modelNotFound("missing").localizedDescription.contains("ollama pull"))
    }

    func testLargeToolNumberIsReplayedExactly() async throws {
        MockURLProtocol.handler = { request in
            (jsonResponse(request), Data(#"{"message":{"role":"assistant","content":"","tool_calls":[{"function":{"name":"shell","arguments":{"value":9007199254740993}}}]}}"#.utf8))
        }
        let response = try await makeProvider().complete(messages: [], tools: [])
        XCTAssertEqual(response.toolCalls.first?.arguments["value"], "9007199254740993")
        XCTAssertTrue(response.toolCalls.first?.rawInputJSON?.contains("9007199254740993") == true)
    }

    func testUnsupportedToolNumberIsRejected() async throws {
        MockURLProtocol.handler = { request in
            (jsonResponse(request), Data(#"{"message":{"role":"assistant","content":"","tool_calls":[{"function":{"name":"shell","arguments":{"value":123456789012345678901234567890123456789}}}]}}"#.utf8))
        }
        do {
            _ = try await makeProvider().complete(messages: [], tools: [])
            XCTFail("Expected unsupported precision to be rejected")
        } catch let error as LLMError {
            guard case .invalidResponse = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testToolHistoryAndQwenSelectionAreSent() async throws {
        let captured = LockedBox<Data?>(initial: nil)
        MockURLProtocol.handler = { request in
            captured.set(bodyData(of: request))
            return (jsonResponse(request), Data(#"{"message":{"role":"assistant","content":"done"}}"#.utf8))
        }
        let call = LLMToolCall(id: "abc", name: "shell", arguments: ["command": "pwd"])
        let provider = OllamaProvider(model: "qwen3:4b", session: MockURLSessionFactory.make())
        _ = try await provider.complete(messages: [
            LLMMessage(role: .assistant, content: "", toolCalls: [call]),
            LLMMessage(role: .tool, content: "ok", toolCallID: "abc")
        ], tools: [])
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(captured.get())) as? [String: Any])
        XCTAssertEqual(root["model"] as? String, "qwen3:4b")
        let messages = try XCTUnwrap(root["messages"] as? [[String: Any]])
        let calls = try XCTUnwrap(messages[0]["tool_calls"] as? [[String: Any]])
        let function = try XCTUnwrap(calls[0]["function"] as? [String: Any])
        XCTAssertEqual(function["name"] as? String, "shell")
        XCTAssertEqual((function["arguments"] as? [String: String])?["command"], "pwd")
        XCTAssertEqual(messages[1]["tool_name"] as? String, "shell")
    }

    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    private func makeProvider() -> OllamaProvider {
        OllamaProvider(session: MockURLSessionFactory.make())
    }

    private var shellTool: LLMTool {
        LLMTool(
            name: "shell",
            description: "Run a shell command on the local machine.",
            parameters: ["command": LLMToolParameter(type: "string", description: "The command to run.")]
        )
    }

    /// A plain text assistant turn is surfaced as `content`, with Ollama's
    /// `prompt_eval_count` / `eval_count` mapped onto `LLMUsage`.
    func testCompleteParsesTextResponse() async throws {
        let payload = """
        {"message": {"role": "assistant", "content": "Hello"}, "prompt_eval_count": 5, "eval_count": 3}
        """
        MockURLProtocol.handler = { request in
            (jsonResponse(request), Data(payload.utf8))
        }

        let response = try await makeProvider().complete(
            messages: [LLMMessage(role: .user, content: "hi")],
            tools: []
        )

        XCTAssertEqual(response.content, "Hello")
        XCTAssertEqual(response.usage?.promptTokens, 5)
        XCTAssertEqual(response.usage?.completionTokens, 3)
        XCTAssertTrue(response.toolCalls.isEmpty)
    }

    /// A function-calling turn is surfaced as `LLMToolCall`s. Ollama sends an
    /// empty `content` alongside tool calls; we normalise that to nil so the
    /// caller can tell "text" from "tool call" without string sniffing.
    func testCompleteParsesToolCallResponse() async throws {
        let payload = """
        {"message": {"role": "assistant", "content": "", "tool_calls": [
            {"function": {"name": "shell", "arguments": {"command": "ls"}}}
        ]}, "prompt_eval_count": 12, "eval_count": 4}
        """
        MockURLProtocol.handler = { request in
            (jsonResponse(request), Data(payload.utf8))
        }

        let response = try await makeProvider().complete(
            messages: [LLMMessage(role: .user, content: "list the files")],
            tools: [shellTool]
        )

        XCTAssertNil(response.content)
        XCTAssertEqual(response.toolCalls.count, 1)
        XCTAssertEqual(response.toolCalls.first?.name, "shell")
        XCTAssertEqual(response.toolCalls.first?.arguments["command"], "ls")
    }

    /// The outbound body must use Ollama's function-calling shape: a `POST` to
    /// `/api/chat` whose `tools[0]` is `{"type": "function", "function": ...}`
    /// with a JSON-schema `parameters` object.
    func testCompleteSendsToolSchemaInOllamaFormat() async throws {
        let capturedRequest = LockedBox<URLRequest?>(initial: nil)
        let capturedBody = LockedBox<Data?>(initial: nil)
        MockURLProtocol.handler = { request in
            capturedRequest.set(request)
            capturedBody.set(bodyData(of: request))
            return (jsonResponse(request), Data(#"{"message": {"role": "assistant", "content": "ok"}}"#.utf8))
        }

        _ = try await makeProvider().complete(
            messages: [LLMMessage(role: .user, content: "list the files")],
            tools: [shellTool]
        )

        let request = try XCTUnwrap(capturedRequest.get())
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:11434/api/chat")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let body = try XCTUnwrap(capturedBody.get())
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(root["model"] as? String, "qwen3:4b-instruct")
        XCTAssertEqual(root["stream"] as? Bool, false)

        let tools = try XCTUnwrap(root["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools[0]["type"] as? String, "function")

        let function = try XCTUnwrap(tools[0]["function"] as? [String: Any])
        XCTAssertEqual(function["name"] as? String, "shell")
        XCTAssertEqual(function["description"] as? String, "Run a shell command on the local machine.")

        let parameters = try XCTUnwrap(function["parameters"] as? [String: Any])
        XCTAssertEqual(parameters["type"] as? String, "object")
        XCTAssertEqual(parameters["required"] as? [String], ["command"])
        let properties = try XCTUnwrap(parameters["properties"] as? [String: Any])
        let command = try XCTUnwrap(properties["command"] as? [String: Any])
        XCTAssertEqual(command["type"] as? String, "string")
        XCTAssertEqual(command["description"] as? String, "The command to run.")
    }

    /// Ollama not running / port closed surfaces as a typed `.unavailable`
    /// rather than a raw `URLError` escaping the provider boundary.
    func testCompleteMapsConnectionFailureToUnavailable() async throws {
        MockURLProtocol.handler = { _ in
            throw URLError(.cannotConnectToHost)
        }

        do {
            _ = try await makeProvider().complete(
                messages: [LLMMessage(role: .user, content: "hi")],
                tools: []
            )
            XCTFail("Expected a connection failure to throw")
        } catch let error as LLMError {
            guard case .ollamaUnavailable = error else {
                return XCTFail("expected .ollamaUnavailable, got \(error)")
            }
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    /// A non-2xx HTTP status (other than the 404 model-missing case) is
    /// reported with both the code and the server body.
    func testCompleteMapsHTTPErrorStatus() async throws {
        MockURLProtocol.handler = { request in
            (jsonResponse(request, status: 500), Data("boom".utf8))
        }

        do {
            _ = try await makeProvider().complete(
                messages: [LLMMessage(role: .user, content: "hi")],
                tools: []
            )
            XCTFail("Expected a 500 to throw")
        } catch let error as LLMError {
            guard case .httpStatus(let code, let body) = error else {
                return XCTFail("expected .httpStatus, got \(error)")
            }
            XCTAssertEqual(code, 500)
            XCTAssertEqual(body, "boom")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    /// A 200 response whose body is not valid chat JSON must not be silently
    /// coerced into an empty assistant turn.
    func testCompleteMapsMalformedJSONToInvalidResponse() async throws {
        MockURLProtocol.handler = { request in
            (jsonResponse(request), Data("not json {{{".utf8))
        }

        do {
            _ = try await makeProvider().complete(
                messages: [LLMMessage(role: .user, content: "hi")],
                tools: []
            )
            XCTFail("Expected malformed JSON to throw")
        } catch let error as LLMError {
            guard case .invalidResponse = error else {
                return XCTFail("expected .invalidResponse, got \(error)")
            }
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    /// Ollama sends tool-call arguments as free-form JSON, but our contract is
    /// `[String: String]`. Scalars are flattened losslessly: integers lose the
    /// trailing `.0`, booleans become "true"/"false", strings pass through.
    func testToolCallArgumentsFlattenNumbersAndBooleans() async throws {
        let payload = """
        {"message": {"role": "assistant", "content": "", "tool_calls": [
            {"function": {"name": "shell", "arguments": {"count": 5, "flag": true, "name": "x"}}}
        ]}}
        """
        MockURLProtocol.handler = { request in
            (jsonResponse(request), Data(payload.utf8))
        }

        let response = try await makeProvider().complete(
            messages: [LLMMessage(role: .user, content: "go")],
            tools: [shellTool]
        )

        let call = try XCTUnwrap(response.toolCalls.first)
        XCTAssertEqual(call.arguments, ["count": "5", "flag": "true", "name": "x"])
    }
}
