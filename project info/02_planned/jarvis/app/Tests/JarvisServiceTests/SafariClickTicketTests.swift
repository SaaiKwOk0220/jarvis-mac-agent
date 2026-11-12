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

private final class ClickTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 11
    func read() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ next: TimeInterval) { lock.lock(); defer { lock.unlock() }; value = next }
}

private final class BlockingClickAction: @unchecked Sendable {
    let entered: XCTestExpectation
    let release = DispatchSemaphore(value: 0)
    init(_ entered: XCTestExpectation) { self.entered = entered }
    func run() { entered.fulfill(); _ = release.wait(timeout: .now() + 5) }
}

private final class ClickActionCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); defer { lock.unlock() }; count += 1 }
}

private actor ClickVerifyGate {
    var calls = 0
    var resume: CheckedContinuation<Void, Never>?
    let entered: XCTestExpectation
    let blockAt: Int
    init(_ entered: XCTestExpectation, blockAt: Int = 2) { self.entered = entered; self.blockAt = blockAt }
    func visit() async {
        calls += 1
        if calls == blockAt {
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
        let clock = ClickTestClock()
        let coordinator = SafariClickApprovalPrototype(enabled: true, capture: capture, clock: { clock.read() }) { _, operation in XCTAssertEqual(operation as String, kAXPressAction as String); counter.increment(); return .success }
        let id = UUID()
        let token = try await coordinator.prepare(requestID: id, identity: identity)
        try await coordinator.approve(token: token, requestID: id, digest: "digest")
        do { try await coordinator.approve(token: token, requestID: id, digest: "digest"); XCTFail("replay") } catch { }
        let tampered = try await coordinator.prepare(requestID: id, identity: identity)
        do { try await coordinator.approve(token: tampered, requestID: id, digest: "tampered"); XCTFail("tampered digest") } catch { }
        let expired = try await coordinator.prepare(requestID: id, identity: identity)
        clock.set(71)
        do { try await coordinator.approve(token: expired, requestID: id, digest: "digest"); XCTFail("expired") } catch { }
        let cancelled = try await coordinator.prepare(requestID: id, identity: identity)
        await coordinator.cancel()
        do { try await capture.verify(expected: identity); XCTFail("cancelled reference retained") } catch { }
        do { try await coordinator.approve(token: cancelled, requestID: id, digest: "digest"); XCTFail("cancelled") } catch { }
        let count = counter.value
        XCTAssertEqual(count, 1)
    }

    func testOverlappingCancelKeepsCleanupBarrier() async throws {
        let identity = SafariClickIdentity(pid: 42, window: "window", url: "https://example.com", role: "AXButton", title: "Open", enabled: true, requestDigest: "digest")
        let ref = AXUIElementCreateSystemWide()
        let candidate = SafariClickCandidate(element: ref, window: ref, launchDate: Date(timeIntervalSince1970: 1), identity: identity)
        let entered = expectation(description: "first cleanup")
        let gate = ClickVerifyGate(entered, blockAt: 1)
        let capture = SafariClickCapture(beforeClear: { await gate.visit() }) { [candidate] }
        let coordinator = SafariClickApprovalPrototype(enabled: true, capture: capture, clock: { 11 }) { _, _ in .success }
        _ = try await coordinator.prepare(requestID: UUID(), identity: identity)
        let first = Task { await coordinator.cancel() }
        await fulfillment(of: [entered], timeout: 2)
        await coordinator.cancel()
        do { _ = try await coordinator.prepare(requestID: UUID(), identity: identity); XCTFail("cleanup still active") } catch { }
        await gate.release()
        await first.value
        _ = try await coordinator.prepare(requestID: UUID(), identity: identity)
    }

    func testPrepareIsBlockedUntilRejectedCaptureIsCleared() async throws {
        let identity = SafariClickIdentity(pid: 42, window: "window", url: "https://example.com", role: "AXButton", title: "Open", enabled: true, requestDigest: "digest")
        let ref = AXUIElementCreateSystemWide()
        let candidate = SafariClickCandidate(element: ref, window: ref, launchDate: Date(timeIntervalSince1970: 1), identity: identity)
        let entered = expectation(description: "cleanup started")
        let gate = ClickVerifyGate(entered, blockAt: 1)
        let capture = SafariClickCapture(beforeClear: { await gate.visit() }) { [candidate] }
        let coordinator = SafariClickApprovalPrototype(enabled: true, capture: capture, clock: { 11 }) { _, _ in .success }
        let token = try await coordinator.prepare(requestID: UUID(), identity: identity)
        let rejection = Task { await coordinator.reject(token: token) }
        await fulfillment(of: [entered], timeout: 2)
        do { _ = try await coordinator.prepare(requestID: UUID(), identity: identity); XCTFail("prepare during cleanup") } catch { }
        await gate.release()
        await rejection.value
        _ = try await coordinator.prepare(requestID: UUID(), identity: identity)
    }

    func testUnknownTokenDoesNotDiscardOtherRequest() async throws {
        let identity = SafariClickIdentity(pid: 42, window: "window", url: "https://example.com", role: "AXButton", title: "Open", enabled: true, requestDigest: "digest")
        let ref = AXUIElementCreateSystemWide()
        let candidate = SafariClickCandidate(element: ref, window: ref, launchDate: Date(timeIntervalSince1970: 1), identity: identity)
        let counter = ClickActionCounter()
        let coordinator = SafariClickApprovalPrototype(enabled: true, capture: SafariClickCapture { [candidate] }, clock: { 11 }) { _, operation in XCTAssertEqual(operation as String, kAXPressAction as String); counter.increment(); return .success }
        let id = UUID()
        let token = try await coordinator.prepare(requestID: id, identity: identity)
        await coordinator.reject(token: UUID())
        do { try await coordinator.approve(token: UUID(), requestID: id, digest: "digest"); XCTFail("unknown token") } catch { }
        try await coordinator.approve(token: token, requestID: id, digest: "digest")
        let count = counter.value
        XCTAssertEqual(count, 1)
    }

    func testTaskCancelDuringCaptureProducesNoTicket() async throws {
        let identity = SafariClickIdentity(pid: 42, window: "window", url: "https://example.com", role: "AXButton", title: "Open", enabled: true, requestDigest: "digest")
        let ref = AXUIElementCreateSystemWide()
        let candidate = SafariClickCandidate(element: ref, window: ref, launchDate: Date(timeIntervalSince1970: 1), identity: identity)
        let entered = expectation(description: "capture started")
        let gate = ClickVerifyGate(entered, blockAt: 1)
        let capture = SafariClickCapture { await gate.visit(); return [candidate] }
        let counter = ClickActionCounter()
        let coordinator = SafariClickApprovalPrototype(enabled: true, capture: capture, clock: { 11 }) { _, operation in XCTAssertEqual(operation as String, kAXPressAction as String); counter.increment(); return .success }
        let task = Task { try await coordinator.prepare(requestID: UUID(), identity: identity) }
        await fulfillment(of: [entered], timeout: 2)
        task.cancel()
        await gate.release()
        do { _ = try await task.value; XCTFail("cancelled capture issued ticket") } catch { }
        do { try await capture.verify(expected: identity); XCTFail("capture reference retained") } catch { }
        let count = counter.value
        XCTAssertEqual(count, 0)
    }

    func testClockFailureClearsCapturedReference() async throws {
        let identity = SafariClickIdentity(pid: 42, window: "window", url: "https://example.com", role: "AXButton", title: "Open", enabled: true, requestDigest: "digest")
        let ref = AXUIElementCreateSystemWide()
        let candidate = SafariClickCandidate(element: ref, window: ref, launchDate: Date(timeIntervalSince1970: 1), identity: identity)
        let capture = SafariClickCapture { [candidate] }
        let coordinator = SafariClickApprovalPrototype(enabled: true, capture: capture, clock: { .nan }) { _, _ in .success }
        do { _ = try await coordinator.prepare(requestID: UUID(), identity: identity); XCTFail("invalid clock") } catch { }
        do { try await capture.verify(expected: identity); XCTFail("clock failure retained reference") } catch { }
    }

    func testClockGoingBackwardFailsClosed() async throws {
        let identity = SafariClickIdentity(pid: 42, window: "window", url: "https://example.com", role: "AXButton", title: "Open", enabled: true, requestDigest: "digest")
        let ref = AXUIElementCreateSystemWide()
        let candidate = SafariClickCandidate(element: ref, window: ref, launchDate: Date(timeIntervalSince1970: 1), identity: identity)
        let clock = ClickTestClock()
        let counter = ClickActionCounter()
        let coordinator = SafariClickApprovalPrototype(enabled: true, capture: SafariClickCapture { [candidate] }, clock: { clock.read() }) { _, operation in XCTAssertEqual(operation as String, kAXPressAction as String); counter.increment(); return .success }
        let id = UUID()
        let token = try await coordinator.prepare(requestID: id, identity: identity)
        clock.set(10)
        do { try await coordinator.approve(token: token, requestID: id, digest: "digest"); XCTFail("clock moved backward") } catch { }
        let count = counter.value
        XCTAssertEqual(count, 0)
    }

    func testExpirationDuringVerificationPreventsPerform() async throws {
        let identity = SafariClickIdentity(pid: 42, window: "window", url: "https://example.com", role: "AXButton", title: "Open", enabled: true, requestDigest: "digest")
        let ref = AXUIElementCreateSystemWide()
        let candidate = SafariClickCandidate(element: ref, window: ref, launchDate: Date(timeIntervalSince1970: 1), identity: identity)
        let entered = expectation(description: "verification started")
        let gate = ClickVerifyGate(entered)
        let clock = ClickTestClock()
        let capture = SafariClickCapture { await gate.visit(); return [candidate] }
        let counter = ClickActionCounter()
        let coordinator = SafariClickApprovalPrototype(enabled: true, capture: capture, clock: { clock.read() }) { _, operation in XCTAssertEqual(operation as String, kAXPressAction as String); counter.increment(); return .success }
        let id = UUID()
        let token = try await coordinator.prepare(requestID: id, identity: identity)
        let task = Task { try await coordinator.approve(token: token, requestID: id, digest: "digest") }
        await fulfillment(of: [entered], timeout: 2)
        clock.set(71)
        await gate.release()
        do { try await task.value; XCTFail("expired while verifying") } catch { }
        let count = counter.value
        XCTAssertEqual(count, 0)
    }

    func testApprovalRejectAndChangedTargetNeverPerform() async throws {
        let identity = SafariClickIdentity(pid: 42, window: "window", url: "https://example.com", role: "AXButton", title: "Open", enabled: true, requestDigest: "digest")
        let ref = AXUIElementCreateSystemWide()
        let candidate = SafariClickCandidate(element: ref, window: ref, launchDate: Date(timeIntervalSince1970: 0), identity: identity)
        let clock = ClickFixtureCounter()
        let capture = SafariClickCapture { let date = await clock.next(); return [SafariClickCandidate(element: candidate.element, window: candidate.window, launchDate: date, identity: identity)] }
        let counter = ClickActionCounter()
        let coordinator = SafariClickApprovalPrototype(enabled: true, capture: capture, clock: { 11 }) { _, operation in XCTAssertEqual(operation as String, kAXPressAction as String); counter.increment(); return .success }
        let id = UUID()
        let rejected = try await coordinator.prepare(requestID: id, identity: identity)
        await coordinator.reject(token: rejected)
        do { try await capture.verify(expected: identity); XCTFail("rejected reference retained") } catch { }
        do { try await coordinator.approve(token: rejected, requestID: id, digest: "digest"); XCTFail("rejected") } catch { }
        let changed = try await coordinator.prepare(requestID: id, identity: identity)
        do { try await coordinator.approve(token: changed, requestID: id, digest: "digest"); XCTFail("changed") } catch { }
        let count = counter.value
        XCTAssertEqual(count, 0)
    }

    func testCancelAfterActionBeforeCoordinatorCompletionReportsStarted() async throws {
        let identity = SafariClickIdentity(pid: 42, window: "window", url: "https://example.com", role: "AXButton", title: "Open", enabled: true, requestDigest: "digest")
        let ref = AXUIElementCreateSystemWide()
        let candidate = SafariClickCandidate(element: ref, window: ref, launchDate: Date(timeIntervalSince1970: 1), identity: identity)
        let clearEntered = expectation(description: "post-action cleanup")
        let clearGate = ClickVerifyGate(clearEntered, blockAt: 1)
        let capture = SafariClickCapture(beforeClear: { await clearGate.visit() }) { [candidate] }
        let counter = ClickActionCounter()
        let coordinator = SafariClickApprovalPrototype(enabled: true, capture: capture, clock: { 11 }) { _, _ in counter.increment(); return .success }
        let id = UUID()
        let token = try await coordinator.prepare(requestID: id, identity: identity)
        let approval = Task { try await coordinator.approve(token: token, requestID: id, digest: "digest") }
        await fulfillment(of: [clearEntered], timeout: 2)
        let result = await coordinator.cancel()
        XCTAssertEqual(result, .alreadyStarted)
        XCTAssertEqual(counter.value, 1)
        await clearGate.release()
        try await approval.value
    }

    func testTimedOutActionKeepsWorkerBoundedUntilReturn() async throws {
        let identity = SafariClickIdentity(pid: 42, window: "window", url: "https://example.com", role: "AXButton", title: "Open", enabled: true, requestDigest: "digest")
        let ref = AXUIElementCreateSystemWide()
        let candidate = SafariClickCandidate(element: ref, window: ref, launchDate: Date(timeIntervalSince1970: 1), identity: identity)
        let entered = expectation(description: "action started")
        let blocking = BlockingClickAction(entered)
        let capture = SafariClickCapture { [candidate] }
        let coordinator = SafariClickApprovalPrototype(enabled: true, capture: capture, clock: { 11 }, actionTimeout: 0.05) { _, _ in blocking.run(); return .success }
        let id = UUID()
        let token = try await coordinator.prepare(requestID: id, identity: identity)
        let approval = Task { try await coordinator.approve(token: token, requestID: id, digest: "digest") }
        await fulfillment(of: [entered], timeout: 2)
        do { try await approval.value; XCTFail("blocked action must time out") } catch { }
        let next = try await coordinator.prepare(requestID: UUID(), identity: identity)
        do { try await coordinator.approve(token: next, requestID: UUID(), digest: "digest"); XCTFail("mismatched request") } catch { }
        let nextID = UUID()
        let busy = try await coordinator.prepare(requestID: nextID, identity: identity)
        do { try await coordinator.approve(token: busy, requestID: nextID, digest: "digest"); XCTFail("worker must remain busy") } catch { }
        blocking.release.signal()
    }

    func testCancelReturnsWhenActionAlreadyStarted() async throws {
        let identity = SafariClickIdentity(pid: 42, window: "window", url: "https://example.com", role: "AXButton", title: "Open", enabled: true, requestDigest: "digest")
        let ref = AXUIElementCreateSystemWide()
        let candidate = SafariClickCandidate(element: ref, window: ref, launchDate: Date(timeIntervalSince1970: 1), identity: identity)
        let entered = expectation(description: "action started")
        let blocking = BlockingClickAction(entered)
        let capture = SafariClickCapture { [candidate] }
        let coordinator = SafariClickApprovalPrototype(enabled: true, capture: capture, clock: { 11 }) { _, _ in blocking.run(); return .success }
        let id = UUID()
        let token = try await coordinator.prepare(requestID: id, identity: identity)
        let approval = Task { try await coordinator.approve(token: token, requestID: id, digest: "digest") }
        await fulfillment(of: [entered], timeout: 2)
        let cancelReturned = expectation(description: "cancel returned without waiting for action")
        let cancellation = Task { let result = await coordinator.cancel(); XCTAssertEqual(result, .alreadyStarted); cancelReturned.fulfill() }
        await fulfillment(of: [cancelReturned], timeout: 2)
        blocking.release.signal()
        await cancellation.value
        try await approval.value
    }

    func testCancelDuringSecondVerificationBeforeDelayedClearPreventsPress() async throws {
        let identity = SafariClickIdentity(pid: 42, window: "window", url: "https://example.com", role: "AXButton", title: "Open", enabled: true, requestDigest: "digest")
        let ref = AXUIElementCreateSystemWide()
        let candidate = SafariClickCandidate(element: ref, window: ref, launchDate: Date(timeIntervalSince1970: 1), identity: identity)
        let verifyEntered = expectation(description: "second verification")
        let clearEntered = expectation(description: "delayed clear")
        let verifyGate = ClickVerifyGate(verifyEntered, blockAt: 3)
        let clearGate = ClickVerifyGate(clearEntered, blockAt: 1)
        let capture = SafariClickCapture(beforeClear: { await clearGate.visit() }) { await verifyGate.visit(); return [candidate] }
        let counter = ClickActionCounter()
        let coordinator = SafariClickApprovalPrototype(enabled: true, capture: capture, clock: { 11 }) { _, _ in counter.increment(); return .success }
        let id = UUID()
        let token = try await coordinator.prepare(requestID: id, identity: identity)
        let approval = Task { try await coordinator.approve(token: token, requestID: id, digest: "digest") }
        await fulfillment(of: [verifyEntered], timeout: 2)
        let cancellation = Task { await coordinator.cancel() }
        await fulfillment(of: [clearEntered], timeout: 2)
        await verifyGate.release()
        await clearGate.release()
        await cancellation.value
        do { try await approval.value; XCTFail("cancelled approval") } catch { }
        XCTAssertEqual(counter.value, 0)
    }

    func testTaskCancelWhileVerifyingPreventsPerform() async throws {
        let identity = SafariClickIdentity(pid: 42, window: "window", url: "https://example.com", role: "AXButton", title: "Open", enabled: true, requestDigest: "digest")
        let ref = AXUIElementCreateSystemWide()
        let candidate = SafariClickCandidate(element: ref, window: ref, launchDate: Date(timeIntervalSince1970: 1), identity: identity)
        let entered = expectation(description: "verification started")
        let gate = ClickVerifyGate(entered)
        let capture = SafariClickCapture { await gate.visit(); return [candidate] }
        let counter = ClickActionCounter()
        let coordinator = SafariClickApprovalPrototype(enabled: true, capture: capture, clock: { 11 }) { _, operation in XCTAssertEqual(operation as String, kAXPressAction as String); counter.increment(); return .success }
        let id = UUID()
        let token = try await coordinator.prepare(requestID: id, identity: identity)
        let task = Task { try await coordinator.approve(token: token, requestID: id, digest: "digest") }
        await fulfillment(of: [entered], timeout: 2)
        do { _ = try await coordinator.prepare(requestID: UUID(), identity: identity); XCTFail("concurrent prepare") } catch { }
        task.cancel()
        await gate.release()
        do { try await task.value; XCTFail("cancelled during verification") } catch { }
        let count = counter.value
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
