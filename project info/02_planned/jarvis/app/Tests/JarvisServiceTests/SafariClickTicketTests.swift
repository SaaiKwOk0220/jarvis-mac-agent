import XCTest
@testable import JarvisService

final class SafariClickTicketTests: XCTestCase {
    func testTicketIsSingleUseAndRejectsChangedTarget() async throws {
        let original = SafariClickIdentity(pid: 42, window: "window", url: "https://example.com", role: "AXButton", title: "Open", enabled: true, requestDigest: "digest")
        let store = SafariClickTicketStore()
        let token = await store.issue(identity: original, now: 10)
        var changed = original
        changed.title = "Different"
        let rejected = await store.consume(token: token, current: changed, now: 11)
        XCTAssertFalse(rejected)
        let replay = await store.consume(token: token, current: original, now: 12)
        XCTAssertFalse(replay)
    }
}

#if os(macOS)
import ApplicationServices

extension SafariClickTicketTests {
    func testCaptureRejectsMissingCandidates() async throws {
        let identity = SafariClickIdentity(pid: 42, window: "window", url: "https://example.com", role: "AXButton", title: "Open", enabled: true, requestDigest: "digest")
        let capture = SafariClickCapture { [] }
        do { try await capture.capture(expected: identity); XCTFail("missing target must be rejected") }
        catch SafariClickCapture.CaptureError.ambiguousOrMissing { }
    }

    func testCaptureRejectsAmbiguousCandidates() async throws {
        let identity = SafariClickIdentity(pid: 42, window: "window", url: "https://example.com", role: "AXButton", title: "Open", enabled: true, requestDigest: "digest")
        let candidate = SafariClickCandidate(element: AXUIElementCreateSystemWide(), window: AXUIElementCreateSystemWide(), identity: identity)
        let capture = SafariClickCapture { [candidate, candidate] }
        do {
            try await capture.capture(expected: identity)
            XCTFail("ambiguous target must be rejected")
        } catch SafariClickCapture.CaptureError.ambiguousOrMissing { }
    }
}
#endif
