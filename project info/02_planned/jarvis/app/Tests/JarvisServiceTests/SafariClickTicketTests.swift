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

private actor ClickActionCounter {
    var value = 0
    func increment() { value += 1 }
}

private actor ClickVerifyGate {
    var calls = 0
    var resume: CheckedContinuation<Void, Never>?
    let entered: XCTestExpectation
    init(_ entered: XCTestExpectation) { self.entered = entered }
    func visit() async {
        calls += 1
        if calls == 2 {
            await withCheckedContinuation { continuation in
                resume = continuation
                entered.fulfill()
            }
        }
    }
    func release() { resume?.resume(); resume = nil }
}

private actor ClickFixtureCounter {
    var count: TimeInterval = 0
    func next() -> Date { count += 1; return Date(timeIntervalSince1970: count) }
}

extension SafariClickTicketTests {
    func testApprovalPrototypeExecutesOnceAndFailsClosed() async throws {
        let identity = SafariClickIdentity(pid: 42, window: "window", url: "https://example.com", role: "AXButton", title: "Open", enabled: true, requestDigest: "digest")
        let element = AXUIElementCreateSystemWide()
        let candidate = SafariClickCandidate(element: element, window: element, launchDate: Date(timeIntervalSince1970: 1), identity: identity)
        let capture = SafariClickCapture { [candidate] }
        let counter = ClickActionCounter()
        let coordinator = SafariClickApprovalPrototype(enabled: true, capture: capture) { await counter.increment() }
        let id = UUID()
        let token = try await coordinator.prepare(requestID: id, identity: identity, now: 10)
        try await coordinator.approve(token: token, requestID: id, digest: "digest", now: 11)
        do { try await coordinator.approve(token: token, requestID: id, digest: "digest", now: 12); XCTFail("replay") } catch { }
        let expired = try await coordinator.prepare(requestID: id, identity: identity, now: 10)
        do { try await coordinator.approve(token: expired, requestID: id, digest: "digest", now: 70); XCTFail("expired") } catch { }
        let cancelled = try await coordinator.prepare(requestID: id, identity: identity, now: 10)
        await coordinator.cancel()
        do { try await coordinator.approve(token: cancelled, requestID: id, digest: "digest", now: 11); XCTFail("cancelled") } catch { }
        let count = await counter.value
        XCTAssertEqual(count, 1)
    }

    func testApprovalRejectAndChangedTargetNeverPerform() async throws {
        let identity = SafariClickIdentity(pid: 42, window: "window", url: "https://example.com", role: "AXButton", title: "Open", enabled: true, requestDigest: "digest")
        let ref = AXUIElementCreateSystemWide()
        let candidate = SafariClickCandidate(element: ref, window: ref, launchDate: Date(timeIntervalSince1970: 0), identity: identity)
        let clock = ClickFixtureCounter()
        let capture = SafariClickCapture { let date = await clock.next(); return [SafariClickCandidate(element: candidate.element, window: candidate.window, launchDate: date, identity: identity)] }
        let counter = ClickActionCounter()
        let coordinator = SafariClickApprovalPrototype(enabled: true, capture: capture) { await counter.increment() }
        let id = UUID()
        let rejected = try await coordinator.prepare(requestID: id, identity: identity, now: 1)
        await coordinator.reject(token: rejected)
        do { try await coordinator.approve(token: rejected, requestID: id, digest: "digest", now: 2); XCTFail("rejected") } catch { }
        let changed = try await coordinator.prepare(requestID: id, identity: identity, now: 1)
        do { try await coordinator.approve(token: changed, requestID: id, digest: "digest", now: 2); XCTFail("changed") } catch { }
        let count = await counter.value
        XCTAssertEqual(count, 0)
    }

    func testCancelWhileVerifyingPreventsPerform() async throws {
        let identity = SafariClickIdentity(pid: 42, window: "window", url: "https://example.com", role: "AXButton", title: "Open", enabled: true, requestDigest: "digest")
        let ref = AXUIElementCreateSystemWide()
        let candidate = SafariClickCandidate(element: ref, window: ref, launchDate: Date(timeIntervalSince1970: 1), identity: identity)
        let entered = expectation(description: "verification started")
        let gate = ClickVerifyGate(entered)
        let capture = SafariClickCapture { await gate.visit(); return [candidate] }
        let counter = ClickActionCounter()
        let coordinator = SafariClickApprovalPrototype(enabled: true, capture: capture) { await counter.increment() }
        let id = UUID()
        let token = try await coordinator.prepare(requestID: id, identity: identity, now: 1)
        let task = Task { try await coordinator.approve(token: token, requestID: id, digest: "digest", now: 2) }
        await fulfillment(of: [entered], timeout: 2)
        await coordinator.cancel()
        await gate.release()
        do { try await task.value; XCTFail("cancelled during verification") } catch { }
        let count = await counter.value
        XCTAssertEqual(count, 0)
    }

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

    func testTraversalLimitsAndMalformedNodes() throws {
        XCTAssertThrowsError(try SafariClickTraversal.find(root: 0, maxNodes: 3, expired: { false }) { n, _ in ("AXWebArea", false, [n]) })
        XCTAssertThrowsError(try SafariClickTraversal.find(root: 0, maxDepth: 1, expired: { false }) { n, _ in ("AXWebArea", false, [n + 1]) })
        XCTAssertThrowsError(try SafariClickTraversal.find(root: 0, expired: { true }) { _, _ in ("AXWebArea", false, [Int]()) })
        XCTAssertThrowsError(try SafariClickTraversal.find(root: 0, expired: { false }) { _, _ in throw SafariAXReadError.unavailable } as [Int])
        XCTAssertThrowsError(try SafariClickTraversal.find(root: 0, expired: { false }) { n, _ in n == 0 ? ("AXWebArea", false, [1, 2]) : ("AXButton", true, []) })
        let matches = try SafariClickTraversal.find(root: 0, expired: { false }) { n, _ in n == 0 ? ("AXWebArea", false, [1]) : ("AXButton", true, []) }
        XCTAssertEqual(matches, [1])
    }

    func testTraversalRejectsWideTreeBeforeInspectingChildren() throws {
        var inspections = 0
        XCTAssertThrowsError(try SafariClickTraversal.find(root: 0, maxNodes: 4, expired: { false }) { _, _ in
            inspections += 1
            return ("AXWebArea", false, Array(1...100))
        })
        XCTAssertEqual(inspections, 1)
    }

    func testTraversalRejectsProviderReturningAfterDeadline() throws {
        var expired = false
        XCTAssertThrowsError(try SafariClickTraversal.find(root: 0, expired: { expired }) { _, _ in
            expired = true
            return ("AXWebArea", false, [Int]())
        })
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
