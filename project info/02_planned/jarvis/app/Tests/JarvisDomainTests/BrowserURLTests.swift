import XCTest
@testable import JarvisDomain

final class BrowserURLTests: XCTestCase {
    func testOnlyHTTPSWithoutCredentialsQueryOrFragmentIsAccepted() {
        XCTAssertNotNil(BrowserOpenURL.validated("https://example.com/"))
        for value in ["https://example.com/docs", "http://example.com", "javascript:alert(1)", "https://user:pass@example.com", "https://example.com/?token=abc", "https://example.com/#secret", "https://", "https://127.0.0.1/", "https://[::1]/", "https://printer.LOCAL", "https://example.com/secret-token", "https://foo.localhost", "https://example..com", "https://-bad.example.com", "https://example.com\\n.evil.com"] {
            XCTAssertNil(BrowserOpenURL.validated(value), value)
        }
    }
}
