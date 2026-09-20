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
        XCTAssertEqual(root["model"] as? String, "llama3.2")
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
            guard case .unavailable = error else {
                return XCTFail("expected .unavailable, got \(error)")
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
