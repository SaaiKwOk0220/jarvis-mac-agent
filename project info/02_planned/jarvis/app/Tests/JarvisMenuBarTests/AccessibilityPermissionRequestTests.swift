import XCTest
@preconcurrency import ApplicationServices
@testable import JarvisMenuBar

final class AccessibilityPermissionRequestTests: XCTestCase {
    func testUserRequestEnablesSystemPrompt() {
        var received: [String: Bool] = [:]
        AccessibilityPermissionRequest.request { options in received = options; return false }
        XCTAssertEqual(received[kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String], true)
    }
}
