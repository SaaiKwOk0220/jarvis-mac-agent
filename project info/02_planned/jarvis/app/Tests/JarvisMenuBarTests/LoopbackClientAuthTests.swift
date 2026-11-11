import Foundation
import XCTest
@testable import JarvisMenuBar

private final class AuthRequestProbe: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var lastRequest: URLRequest?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastRequest = request
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("[]".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

@MainActor
final class LoopbackClientAuthTests: XCTestCase {
    func testTokenUsesHeaderAndNeverLeavesLoopbackDestination() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AuthRequestProbe.self]
        let session = URLSession(configuration: configuration)
        let token = String(repeating: "a", count: 64)
        AuthRequestProbe.lastRequest = nil
        let client = ServiceClient(baseURL: URL(string: "http://127.0.0.1:12345")!, session: session, authorizationToken: token)
        _ = try await client.refresh()
        let captured = try XCTUnwrap(AuthRequestProbe.lastRequest)
        XCTAssertEqual(captured.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")
        XCTAssertFalse(captured.url!.absoluteString.contains(token))
        AuthRequestProbe.lastRequest = nil
        let external = ServiceClient(baseURL: URL(string: "https://example.com")!, session: session, authorizationToken: token)
        do { _ = try await external.refresh(); XCTFail("token must not be sent externally") } catch { }
        XCTAssertNil(AuthRequestProbe.lastRequest)
    }

    func testConfigureLocalhostNormalizesToLoopback() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AuthRequestProbe.self]
        let session = URLSession(configuration: configuration)
        let client = ServiceClient(session: session)
        client.configure(baseURL: URL(string: "http://localhost:12345")!, authorizationToken: String(repeating: "a", count: 64))
        AuthRequestProbe.lastRequest = nil
        _ = try await client.refresh()
        XCTAssertEqual(AuthRequestProbe.lastRequest?.url?.host, "127.0.0.1")
        XCTAssertEqual(AuthRequestProbe.lastRequest?.url?.port, 12345)
    }

    func testRedirectDelegateRefusesForwarding() async throws {
        let url = URL(string: "http://127.0.0.1:12345/tasks")!
        let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": "https://example.com/"])!
        let redirected = URLRequest(url: URL(string: "https://example.com/")!)
        let task = URLSession.shared.dataTask(with: url)
        let choice: URLRequest? = await withCheckedContinuation { continuation in
            LoopbackNoRedirectDelegate.shared.urlSession(.shared, task: task, willPerformHTTPRedirection: response, newRequest: redirected) { continuation.resume(returning: $0) }
        }
        XCTAssertNil(choice)
    }
}
