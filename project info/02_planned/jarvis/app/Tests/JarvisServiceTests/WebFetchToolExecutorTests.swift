import Foundation
import XCTest
import JarvisDomain
@testable import JarvisService

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

final class WebFetchToolExecutorTests: XCTestCase {

    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    /// Confirms the happy path: a 200 response is surfaced with the HTTP status
    /// in the summary and the body bytes included verbatim (within the limit).
    /// The body is short enough to fit inside the default 10KB cap so the test
    /// isolates the format without entangling truncation.
    func testFetchReturnsStatusCodeAndTruncatedBody() async throws {
        let body = "hello from the network"
        let session = MockURLSessionFactory.make()
        let captured = LockedBox<URLRequest?>(initial: nil)
        MockURLProtocol.handler = { request in
            captured.set(request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/plain"])!
            return (response, Data(body.utf8))
        }

        let executor = WebFetchToolExecutor(session: session)
        let request = ToolRequest(
            taskID: UUID(),
            name: "fetch",
            sideEffect: .read,
            target: "https://example.com/hello",
            payload: "https://example.com/hello"
        )

        let result = try await executor.execute(request)

        let seenRequest = captured.get()
        XCTAssertNotNil(seenRequest, "MockURLProtocol handler should have been invoked")
        XCTAssertEqual(seenRequest?.url?.absoluteString, "https://example.com/hello")
        XCTAssertTrue(result.summary.contains("HTTP 200"),
                      "summary must carry the HTTP status; got: \(result.summary)")
        XCTAssertTrue(result.summary.contains(body),
                      "summary must include the response body; got: \(result.summary)")
    }

    /// Confirms the executor refuses URLs whose scheme is not https. We throw
    /// before opening any socket so the test never reaches the URLProtocol
    /// handler; absence of a handler and an explicit throw is the proof.
    func testFetchRejectsNonHTTPScheme() async throws {
        // Note: handler intentionally left as nil. If the executor opens a
        // connection for a non-https URL, MockURLProtocol will fail the
        // request instead of throwing the executor's own error type, which is
        // the failure signal we are testing for.
        let session = MockURLSessionFactory.make()
        let executor = WebFetchToolExecutor(session: session)
        let request = ToolRequest(
            taskID: UUID(),
            name: "fetch",
            sideEffect: .read,
            target: "http://example.com/insecure",
            payload: "http://example.com/insecure"
        )

        do {
            _ = try await executor.execute(request)
            XCTFail("Expected non-https URL to throw")
        } catch let WebFetchToolExecutorError.nonHTTPSScheme(scheme) {
            XCTAssertEqual(scheme, "http")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    /// Confirms the executor turns HTTP non-2xx statuses into a typed error
    /// rather than a silent success. 404 is the canonical example: the
    /// resource was reached, but the server explicitly said "not found".
    func testFetchReportsNon200Status() async throws {
        let session = MockURLSessionFactory.make()
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 404, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/plain"])!
            return (response, Data("not here".utf8))
        }

        let executor = WebFetchToolExecutor(session: session)
        let request = ToolRequest(
            taskID: UUID(),
            name: "fetch",
            sideEffect: .read,
            target: "https://example.com/missing",
            payload: "https://example.com/missing"
        )

        do {
            _ = try await executor.execute(request)
            XCTFail("Expected 404 to throw")
        } catch let WebFetchToolExecutorError.httpStatus(status) {
            XCTAssertEqual(status, 404)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    /// Confirms the executor truncates body bytes to honor the configured
    /// `maxResponseBytes`. We send a 100KB body with a 1024-byte cap and
    /// assert that the resulting summary's payload slice is bounded. We do
    /// not compare against an exact byte count because the executor reserves
    /// a small safety buffer for UTF-8 boundaries; the contract is "no more
    /// than the cap", not "exactly the cap".
    func testFetchRespectsMaxResponseBytesLimit() async throws {
        let cap = 1_024
        let bigBody = String(repeating: "A", count: 100_000)
        let session = MockURLSessionFactory.make()
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/plain"])!
            return (response, Data(bigBody.utf8))
        }

        let executor = WebFetchToolExecutor(session: session, maxResponseBytes: cap)
        let request = ToolRequest(
            taskID: UUID(),
            name: "fetch",
            sideEffect: .read,
            target: "https://example.com/big",
            payload: "https://example.com/big"
        )

        let result = try await executor.execute(request)

        // Pull the body slice out of the summary by dropping the "HTTP 200\n"
        // header line. The exact prefix format is part of the contract.
        let lines = result.summary.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let bodySlice = lines.count == 2 ? String(lines[1]) : result.summary

        XCTAssertLessThanOrEqual(bodySlice.utf8.count, cap,
            "truncated body must not exceed maxResponseBytes; got \(bodySlice.utf8.count)")
        XCTAssertGreaterThan(bodySlice.utf8.count, 0,
            "truncated body must not be empty when source body is large")
    }
}