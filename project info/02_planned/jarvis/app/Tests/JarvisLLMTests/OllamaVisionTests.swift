import Foundation
import XCTest
@testable import JarvisLLM

final class OllamaVisionTests: XCTestCase {
    override func tearDown() { MockURLProtocol.handler = nil; super.tearDown() }
    private func service(_ url: String = "http://127.0.0.1:11434") throws -> OllamaVisionService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return try OllamaVisionService(baseURL: XCTUnwrap(URL(string: url)), model: "test-vision", configuration: config)
    }
    func testSuccessSendsOnlyExplicitImageAndPrompt() async throws {
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/chat")
            XCTAssertEqual(request.httpMethod, "POST")
            let stream = request.httpBodyStream
            var body = request.httpBody ?? Data()
            if let stream { stream.open(); defer { stream.close() }; var bytes = [UInt8](repeating: 0, count: 4096); while stream.hasBytesAvailable { let count = stream.read(&bytes, maxLength: bytes.count); if count <= 0 { break }; body.append(contentsOf: bytes.prefix(count)) } }
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
            XCTAssertEqual(messages.first?["content"] as? String, "describe")
            XCTAssertEqual(messages.first?["images"] as? [String], [Data([1, 2, 3]).base64EncodedString()])
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(#"{"message":{"content":"a picture"},"done":true}"#.utf8))
        }
        let response = try await service().describe(VisionRequest(prompt: "describe", image: Data([1, 2, 3])))
        XCTAssertEqual(response, "a picture")
    }
    func testRejectsRemoteAndInvalidRequestsBeforeNetwork() throws {
        XCTAssertThrowsError(try service("https://example.com"))
        XCTAssertThrowsError(try service("http://localhost:11434"))
        XCTAssertThrowsError(try service("http://127.0.0.1:11434/path"))
        XCTAssertThrowsError(try VisionRequest(prompt: "x", image: Data()))
        XCTAssertThrowsError(try VisionRequest(prompt: "x", image: Data(repeating: 1, count: VisionRequest.maximumImageBytes + 1)))
        XCTAssertThrowsError(try VisionRequest(prompt: "", image: Data([1])))
    }
    func testConcurrentRequestsAcrossServiceInstancesAreRejected() async throws {
        let entered = expectation(description: "first request entered")
        let release = DispatchSemaphore(value: 0)
        MockURLProtocol.handler = { request in
            entered.fulfill()
            _ = release.wait(timeout: .now() + 3)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(#"{"message":{"content":"ok"},"done":true}"#.utf8))
        }
        let first = try service(), second = try service()
        let input = try VisionRequest(prompt: "x", image: Data([1]))
        let active = Task { try await first.describe(input) }
        await fulfillment(of: [entered], timeout: 2)
        do { _ = try await second.describe(input); XCTFail("expected busy") }
        catch VisionError.busy { }
        release.signal()
        let result = try await active.value
        XCTAssertEqual(result, "ok")
    }
    func testMissingOrFalseDoneIsRejected() async throws {
        for payload in [#"{"message":{"content":"partial"}}"#, #"{"message":{"content":"partial"},"done":false}"#] {
            MockURLProtocol.handler = { request in
                (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(payload.utf8))
            }
            do { _ = try await service().describe(VisionRequest(prompt: "x", image: Data([1]))); XCTFail("expected incomplete result") }
            catch VisionError.invalidResponse { }
        }
    }
    func testUnboundedResponseWithoutLengthIsRejected() async throws {
        MockURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             Data(repeating: 65, count: OllamaVisionService.maximumResponseBytes + 1))
        }
        do { _ = try await service().describe(VisionRequest(prompt: "x", image: Data([1]))); XCTFail("expected size rejection") }
        catch VisionError.invalidResponse { }
    }
    func testRedirectResponseIsRejected() async throws {
        MockURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: nil,
                             headerFields: ["Location": "https://example.com/collect"])!, nil)
        }
        do { _ = try await service().describe(VisionRequest(prompt: "private", image: Data([1]))); XCTFail("expected error") }
        catch VisionError.unavailable { }
    }
    func testMalformedResponseAndTransportFailureAreSanitized() async throws {
        MockURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("private response".utf8))
        }
        do { _ = try await service().describe(VisionRequest(prompt: "private", image: Data([1]))); XCTFail("expected error") }
        catch VisionError.invalidResponse { }
        MockURLProtocol.handler = { _ in throw NSError(domain: "private prompt", code: 1) }
        do { _ = try await service().describe(VisionRequest(prompt: "private", image: Data([1]))); XCTFail("expected error") }
        catch VisionError.unavailable { }
    }
    func testHTTPFailureDoesNotExposeResponseBody() async throws {
        MockURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data("secret prompt and image".utf8))
        }
        do { _ = try await service().describe(VisionRequest(prompt: "private prompt", image: Data([1]))); XCTFail("expected error") }
        catch { XCTAssertFalse(String(describing: error).contains("secret")); XCTAssertFalse(error.localizedDescription.contains("private prompt")) }
    }
}
