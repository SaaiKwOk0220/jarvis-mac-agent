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

private actor ClickFixtureCounter {
    var count: TimeInterval = 0
    func next() -> Date { count += 1; return Date(timeIntervalSince1970: count) }
}

extension SafariClickTicketTests {
    func testCaptureRejectsReusedPIDWithDifferentLaunchDate() async throws {
        let identity = SafariClickIdentity(pid: 42, window: "window", url: "https://example.com", role: "AXButton", title: "Open", enabled: true, requestDigest: "digest")
        let ref = AXUIElementCreateSystemWide()
        let candidate = SafariClickCandidate(element: ref, window: ref, launchDate: Date(timeIntervalSince1970: 0), identity: identity)
        let counter = ClickFixtureCounter()
        let capture = SafariClickCapture {
            let date = await counter.next()
            return [SafariClickCandidate(element: candidate.element, window: candidate.window, launchDate: date, identity: identity)]
        }
        try await capture.capture(expected: identity)
        do { try await capture.verify(expected: identity); XCTFail("PID reuse must fail") }
        catch SafariClickCapture.CaptureError.changed { }
    }

    func testCaptureRejectsMissingCandidates() async throws {
        let identity = SafariClickIdentity(pid: 42, window: "window", url: "https://example.com", role: "AXButton", title: "Open", enabled: true, requestDigest: "digest")
        let capture = SafariClickCapture { [] }
        do { try await capture.capture(expected: identity); XCTFail("missing target must be rejected") }
        catch SafariClickCapture.CaptureError.ambiguousOrMissing { }
    }

    func testCaptureRejectsAmbiguousCandidates() async throws {
        let identity = SafariClickIdentity(pid: 42, window: "window", url: "https://example.com", role: "AXButton", title: "Open", enabled: true, requestDigest: "digest")
        let candidate = SafariClickCandidate(element: AXUIElementCreateSystemWide(), window: AXUIElementCreateSystemWide(), launchDate: Date(timeIntervalSince1970: 1), identity: identity)
        let capture = SafariClickCapture { [candidate, candidate] }
        do {
            try await capture.capture(expected: identity)
            XCTFail("ambiguous target must be rejected")
        } catch SafariClickCapture.CaptureError.ambiguousOrMissing { }
    }
}
#endif
