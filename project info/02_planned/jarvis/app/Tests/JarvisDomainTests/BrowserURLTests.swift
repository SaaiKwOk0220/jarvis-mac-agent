import XCTest
@testable import JarvisDomain

final class BrowserURLTests: XCTestCase {
    func testOnlyHTTPSWithoutCredentialsQueryOrFragmentIsAccepted() {
        XCTAssertNotNil(BrowserOpenURL.validated("https://example.com/docs"))
        for value in ["http://example.com", "javascript:alert(1)", "https://user:pass@example.com", "https://example.com/?token=abc", "https://example.com/#secret", "https://", "https://printer.LOCAL", "https://foo.localhost", "https://example..com", "https://-bad.example.com", "https://example.com\\n.evil.com"] {
            XCTAssertNil(BrowserOpenURL.validated(value), value)
        }
    }
}
