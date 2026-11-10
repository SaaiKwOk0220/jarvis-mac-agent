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
extension WebFetchToolExecutorTests {
    func testRedirectMustRemainOnExactHTTPSHost() {
        XCTAssertTrue(FetchRedirectPolicy.permits(original: URL(string: "https://example.com/a")!, destination: URL(string: "https://EXAMPLE.com/b")!))
        XCTAssertFalse(FetchRedirectPolicy.permits(original: URL(string: "https://example.com/a")!, destination: URL(string: "https://evil.example.com/b")!))
        XCTAssertFalse(FetchRedirectPolicy.permits(original: URL(string: "https://example.com/a")!, destination: URL(string: "http://example.com/b")!))
        XCTAssertFalse(FetchRedirectPolicy.permits(original: URL(string: "https://example.com/a")!, destination: URL(string: "https://user@example.com/b")!))
    }

    func testStreamBufferStopsAtExactLimit() {
        var buffer = FetchBoundedBuffer(limit: 5)
        XCTAssertFalse(buffer.append(Data("abc".utf8)))
        XCTAssertTrue(buffer.append(Data("defgh".utf8)))
        XCTAssertEqual(String(decoding: buffer.data, as: UTF8.self), "abcde")
        XCTAssertTrue(buffer.append(Data("more".utf8)))
        XCTAssertEqual(buffer.data.count, 5)
    }
}

private final class ChunkedFetchProtocol: URLProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    nonisolated(unsafe) static var onChunk: (@Sendable () -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        sendChunk(remaining: 100)
    }
    private func sendChunk(remaining: Int) {
        lock.lock(); let stopped = self.stopped; lock.unlock()
        guard !stopped else { return }
        guard remaining > 0 else { client?.urlProtocolDidFinishLoading(self); return }
        Self.onChunk?()
        client?.urlProtocol(self, didLoad: Data(repeating: 65, count: 256))
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.01) { [self] in sendChunk(remaining: remaining - 1) }
    }
    override func stopLoading() { lock.lock(); stopped = true; lock.unlock() }
}

extension WebFetchToolExecutorTests {
    func testTransferStopsReadingOnceLimitReached() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChunkedFetchProtocol.self]
        let chunks = LockedBox(initial: 0)
        ChunkedFetchProtocol.onChunk = { chunks.set(chunks.get() + 1) }
        defer { ChunkedFetchProtocol.onChunk = nil }
        let executor = WebFetchToolExecutor(session: URLSession(configuration: configuration), maxResponseBytes: 512)
        let request = ToolRequest(taskID: UUID(), name: "fetch", sideEffect: .read, target: "https://example.com", payload: "")
        let result = try await executor.execute(request)
        XCTAssertEqual(result.summary.utf8.count, "HTTP 200\n".utf8.count + 512)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertLessThan(chunks.get(), 10, "transfer should stop before the full response")
    }
}


extension WebFetchToolExecutorTests {
    func testRedirectDelegateRejectsCrossOriginAndAllowsSameOrigin() {
        let original = URL(string: "https://example.com/start")!
        let transfer = FetchTransfer(original: original, limit: 100)
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: original)
        let response = HTTPURLResponse(url: original, statusCode: 302, httpVersion: nil, headerFields: nil)!
        let result = LockedBox<URLRequest?>(initial: nil)
        let same = URLRequest(url: URL(string: "https://example.com/next")!)
        transfer.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: same) { result.set($0) }
        XCTAssertEqual(result.get()?.url, same.url)
        let other = URLRequest(url: URL(string: "https://evil.example.net")!)
        transfer.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: other) { result.set($0) }
        XCTAssertNil(result.get())
        session.invalidateAndCancel()
    }
}

extension WebFetchToolExecutorTests {
    func testFetchSessionDisablesCookiesCredentialsAndCache() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = true
        configuration.httpCookieStorage = HTTPCookieStorage.shared
        configuration.urlCredentialStorage = URLCredentialStorage.shared
        configuration.urlCache = URLCache.shared
        let isolated = FetchTransfer.isolatedConfiguration(from: configuration)
        XCTAssertFalse(isolated.httpShouldSetCookies)
        XCTAssertNil(isolated.httpCookieStorage)
        XCTAssertNil(isolated.urlCredentialStorage)
        XCTAssertNil(isolated.urlCache)
        XCTAssertEqual(isolated.requestCachePolicy, .reloadIgnoringLocalCacheData)
    }
}

extension WebFetchToolExecutorTests {
    func testFetchDoesNotSendSessionAdditionalHeaders() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        configuration.httpAdditionalHeaders = ["Authorization": "Bearer private", "Cookie": "session=private", "X-Secret": "private"]
        let seen = LockedBox<URLRequest?>(initial: nil)
        MockURLProtocol.handler = { request in
            seen.set(request)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("ok".utf8))
        }
        let executor = WebFetchToolExecutor(session: URLSession(configuration: configuration))
        let request = ToolRequest(taskID: UUID(), name: "fetch", sideEffect: .read, target: "https://example.com", payload: "")
        _ = try await executor.execute(request)
        XCTAssertNil(seen.get()?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(seen.get()?.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(seen.get()?.value(forHTTPHeaderField: "X-Secret"))
    }
}
