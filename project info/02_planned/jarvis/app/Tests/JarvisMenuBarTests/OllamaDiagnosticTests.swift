import XCTest
@testable import JarvisMenuBar

final class OllamaDiagnosticTests: XCTestCase {
    func testModelListDistinguishesMissingAndPresent() {
        let data = Data(#"{"models":[{"name":"qwen3:4b-instruct"}]}"#.utf8)
        XCTAssertEqual(OllamaDiagnostic.classify(status: 200, data: data, model: "qwen3:4b-instruct"), .ready)
        XCTAssertEqual(OllamaDiagnostic.classify(status: 200, data: data, model: "other"), .modelMissing)
        XCTAssertEqual(OllamaDiagnostic.classify(status: 500, data: data, model: "other"), .unexpectedResponse)
        XCTAssertEqual(OllamaDiagnostic.classify(status: 200, data: Data(), model: "other"), .unexpectedResponse)
    }
}

private final class DiagnosticURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        switch url.path {
        case "/large": client?.urlProtocol(self, didLoad: Data(repeating: 65, count: 2000)); client?.urlProtocolDidFinishLoading(self)
        case "/slow":
            DispatchQueue.global().async { [weak self] in
                for _ in 0..<20 {
                    Thread.sleep(forTimeInterval: 0.02)
                    guard let self else { return }
                    self.client?.urlProtocol(self, didLoad: Data([32]))
                }
            }
        default:
            client?.urlProtocol(self, didLoad: Data(#"{"models":[{"name":"qwen3:4b-instruct"}]}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

extension OllamaDiagnosticTests {
    private func testSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DiagnosticURLProtocol.self]
        return URLSession(configuration: config)
    }
    func testNetworkNormalAndOversized() async {
        let session = testSession(); defer { session.invalidateAndCancel() }
        let normal = await OllamaDiagnostic.check(url: URL(string: "http://example.test/normal")!, session: session, limit: 1024)
        XCTAssertEqual(normal, .ready)
        let oversized = await OllamaDiagnostic.check(url: URL(string: "http://example.test/large")!, session: session, limit: 1024)
        XCTAssertEqual(oversized, .unexpectedResponse)
    }
    func testNetworkDeadlineAndCancellation() async {
        let session = testSession(); defer { session.invalidateAndCancel() }
        let slow = await OllamaDiagnostic.check(url: URL(string: "http://example.test/slow")!, session: session, timeout: .milliseconds(100))
        XCTAssertEqual(slow, .unavailable)
        let task = Task { await OllamaDiagnostic.check(url: URL(string: "http://example.test/slow")!, session: session) }
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result, .cancelled)
    }
}
