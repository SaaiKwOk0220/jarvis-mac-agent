import XCTest
@testable import JarvisService

private final class BindingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 1
    func read() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ next: TimeInterval) { lock.lock(); defer { lock.unlock() }; value = next }
}

final class SafariClickBindingStoreTests: XCTestCase {
    func testTwoPhaseBindingAndIsolation() async throws {
        let store = SafariClickBindingStore(clock: { 1 })
        let first = UUID(), second = UUID(), request = UUID()
        let av = await store.issue(.init(taskID: first, targetDigest: "target-a")); let a = try XCTUnwrap(av)
        let bv = await store.issue(.init(taskID: second, targetDigest: "target-b")); let b = try XCTUnwrap(bv)
        let boundA = await store.bind(token: a, taskID: first, requestID: request, digest: "digest")
        XCTAssertTrue(boundA)
        await store.cancel(taskID: second)
        let consumedA = await store.consume(token: a, taskID: first, requestID: request, digest: "digest", targetDigest: "target-a")
        let replayA = await store.consume(token: a, taskID: first, requestID: request, digest: "digest", targetDigest: "target-a")
        let boundB = await store.bind(token: b, taskID: second, requestID: UUID(), digest: "digest")
        XCTAssertTrue(consumedA); XCTAssertFalse(replayA); XCTAssertFalse(boundB)
    }
    func testConcurrentTasksRemainIndependent() async throws {
        let store = SafariClickBindingStore(clock: { 1 })
        let succeeded = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for _ in 0..<16 {
                group.addTask {
                    let task = UUID(), request = UUID()
                    guard let token = await store.issue(.init(taskID: task, targetDigest: "target")) else { return false }
                    guard await store.bind(token: token, taskID: task, requestID: request, digest: "digest") else { return false }
                    return await store.consume(token: token, taskID: task, requestID: request, digest: "digest", targetDigest: "target")
                }
            }
            var total = 0
            for await success in group { if success { total += 1 } }
            return total
        }
        XCTAssertEqual(succeeded, 16)
    }
    func testWrongDigestsConsumeBoundTicket() async throws {
        let store = SafariClickBindingStore(clock: { 1 })
        let task = UUID(), request = UUID()
        for variant in 0..<4 {
            let value = await store.issue(.init(taskID: task, targetDigest: "target")); let token = try XCTUnwrap(value)
            let bound = await store.bind(token: token, taskID: task, requestID: request, digest: "request")
            XCTAssertTrue(bound)
            let result = await store.consume(token: token, taskID: variant == 2 ? UUID() : task, requestID: variant == 3 ? UUID() : request, digest: variant == 0 ? "wrong" : "request", targetDigest: variant == 1 ? "wrong" : "target")
            let replay = await store.consume(token: token, taskID: task, requestID: request, digest: "request", targetDigest: "target")
            XCTAssertFalse(result); XCTAssertFalse(replay)
        }
    }
    func testExpiryAndCancellationPreventBinding() async throws {
        let clock = BindingClock(), task = UUID()
        let store = SafariClickBindingStore(lifetime: 5, clock: { clock.read() })
        let firstValue = await store.issue(.init(taskID: task, targetDigest: "target")); let first = try XCTUnwrap(firstValue)
        await store.cancel(token: first)
        let cancelled = await store.bind(token: first, taskID: task, requestID: UUID(), digest: "digest")
        XCTAssertFalse(cancelled)
        let secondValue = await store.issue(.init(taskID: task, targetDigest: "target")); let second = try XCTUnwrap(secondValue)
        clock.set(6)
        let expired = await store.bind(token: second, taskID: task, requestID: UUID(), digest: "digest")
        XCTAssertFalse(expired)
    }
    func testUnboundOrMismatchedTicketCannotBeConsumed() async throws {
        let store = SafariClickBindingStore(clock: { 1 })
        let task = UUID(), request = UUID()
        let value = await store.issue(.init(taskID: task, targetDigest: "target")); let token = try XCTUnwrap(value)
        let result = await store.consume(token: token, taskID: task, requestID: request, digest: "digest", targetDigest: "target")
        XCTAssertFalse(result)
    }
}

#if os(macOS)
import ApplicationServices
private actor EarlyWakeSleeper {
    var calls = 0
    func sleep(_ duration: Duration) async throws {
        calls += 1
        if calls == 1 { return }
        try await Task.sleep(for: duration)
    }
}
private actor DeadlineCheckGate {
    let entered: XCTestExpectation
    var calls = 0
    var continuation: CheckedContinuation<Void, Never>?
    init(_ entered: XCTestExpectation) { self.entered = entered }
    func check() async {
        calls += 1
        if calls == 2 { await withCheckedContinuation { continuation = $0; entered.fulfill() } }
    }
    func release() { continuation?.resume(); continuation = nil }
}
private actor BindingGate {
    let entered: XCTestExpectation
    var continuation: CheckedContinuation<Void, Never>?
    init(_ entered: XCTestExpectation) { self.entered = entered }
    func wait() async { await withCheckedContinuation { continuation = $0; entered.fulfill() } }
    func release() { continuation?.resume(); continuation = nil }
}
extension SafariClickBindingStoreTests {
    func testAutomaticExpiryUsesTicketDeadlineAfterEarlyWake() async throws {
        let identity = SafariClickIdentity(pid: 42, window: "window", url: "https://example.com", role: "AXButton", title: "Open", enabled: true, requestDigest: "")
        let ref = AXUIElementCreateSystemWide()
        let candidate = SafariClickCandidate(element: ref, window: ref, launchDate: Date(timeIntervalSince1970: 1), identity: identity)
        for lifetime in [0.1, 0.25] {
            let sleeper = EarlyWakeSleeper()
            let staged = SafariClickStagedCaptures(bindings: SafariClickBindingStore(lifetime: lifetime), sleep: { try await sleeper.sleep($0) })
            let capture = SafariClickCapture { [candidate] }
            let token = try await staged.stage(taskID: UUID(), identity: identity, targetDigest: "target", capture: capture)
            XCTAssertNotNil(token)
            try await Task.sleep(for: .milliseconds(30))
            try await capture.verify(expected: identity)
            try await Task.sleep(for: .seconds(lifetime + 0.1))
            do { try await capture.verify(expected: identity); XCTFail("expired capture retained") } catch { }
            let calls = await sleeper.calls
            XCTAssertGreaterThanOrEqual(calls, 2)
        }
    }
    func testExpiredCapturesAreReleasedRepeatedly() async throws {
        let clock = BindingClock(), task = UUID()
        let bindings = SafariClickBindingStore(lifetime: 5, clock: { clock.read() })
        let staged = SafariClickStagedCaptures(bindings: bindings)
        let identity = SafariClickIdentity(pid: 42, window: "window", url: "https://example.com", role: "AXButton", title: "Open", enabled: true, requestDigest: "")
        let ref = AXUIElementCreateSystemWide()
        let candidate = SafariClickCandidate(element: ref, window: ref, launchDate: Date(timeIntervalSince1970: 1), identity: identity)
        for index in 0..<40 {
            let capture = SafariClickCapture { [candidate] }
            let token = try await staged.stage(taskID: task, identity: identity, targetDigest: "target", capture: capture)
            XCTAssertNotNil(token)
            clock.set(TimeInterval(6 * (index + 1)))
            await staged.purgeExpired()
            do { try await capture.verify(expected: identity); XCTFail("expired capture retained") } catch { }
        }
    }
    func testCancellationDuringCaptureReleasesReference() async throws {
        let entered = expectation(description: "capture started")
        let gate = BindingGate(entered)
        let staged = SafariClickStagedCaptures(bindings: SafariClickBindingStore(clock: { 1 }))
        let identity = SafariClickIdentity(pid: 42, window: "window", url: "https://example.com", role: "AXButton", title: "Open", enabled: true, requestDigest: "")
        let ref = AXUIElementCreateSystemWide()
        let candidate = SafariClickCandidate(element: ref, window: ref, launchDate: Date(timeIntervalSince1970: 1), identity: identity)
        let capture = SafariClickCapture { await gate.wait(); return [candidate] }
        let task = Task { try await staged.stage(taskID: UUID(), identity: identity, targetDigest: "target", capture: capture) }
        await fulfillment(of: [entered], timeout: 2)
        task.cancel(); await gate.release()
        do { _ = try await task.value; XCTFail("cancelled stage") } catch { }
        do { try await capture.verify(expected: identity); XCTFail("cancelled reference retained") } catch { }
    }
    func testCancellationDuringIssueReleasesCapture() async throws {
        let entered = expectation(description: "issue started")
        let gate = BindingGate(entered)
        let bindings = SafariClickBindingStore(clock: { 1 }, beforeIssue: { await gate.wait() })
        let staged = SafariClickStagedCaptures(bindings: bindings)
        let identity = SafariClickIdentity(pid: 42, window: "window", url: "https://example.com", role: "AXButton", title: "Open", enabled: true, requestDigest: "")
        let ref = AXUIElementCreateSystemWide()
        let candidate = SafariClickCandidate(element: ref, window: ref, launchDate: Date(timeIntervalSince1970: 1), identity: identity)
        let capture = SafariClickCapture { [candidate] }
        let task = Task { try await staged.stage(taskID: UUID(), identity: identity, targetDigest: "target", capture: capture) }
        await fulfillment(of: [entered], timeout: 2)
        task.cancel(); await gate.release()
        do { _ = try await task.value; XCTFail("cancelled stage") } catch { }
        do { try await capture.verify(expected: identity); XCTFail("cancelled reference retained") } catch { }
    }
    func testInvalidateWhileFinalDeadlineCheckSuspendsFailsClosed() async throws {
        let entered = expectation(description: "final deadline check")
        let gate = DeadlineCheckGate(entered)
        let taskID = UUID(), request = UUID()
        let bindings = SafariClickBindingStore(clock: { 1 }, beforeDeadlineCheck: { await gate.check() })
        let staged = SafariClickStagedCaptures(bindings: bindings)
        let identity = SafariClickIdentity(pid: 42, window: "window", url: "https://example.com", role: "AXButton", title: "Open", enabled: true, requestDigest: "")
        let ref = AXUIElementCreateSystemWide()
        let candidate = SafariClickCandidate(element: ref, window: ref, launchDate: Date(timeIntervalSince1970: 1), identity: identity)
        let capture = SafariClickCapture { [candidate] }
        let value = try await staged.stage(taskID: taskID, identity: identity, targetDigest: "target", capture: capture)
        let token = try XCTUnwrap(value)
        let bound = await staged.bind(token: token, taskID: taskID, requestID: request, digest: "digest")
        XCTAssertTrue(bound)
        let value2 = await staged.consume(token: token, taskID: taskID, requestID: request, digest: "digest", targetDigest: "target")
        let transfer = try XCTUnwrap(value2)
        let verification = Task { try await transfer.verify(expected: identity) }
        await fulfillment(of: [entered], timeout: 2)
        await transfer.invalidate()
        await gate.release()
        do { try await verification.value; XCTFail("invalidated transfer verified") } catch { }
    }

    func testTransferredCaptureExpiresAtOriginalDeadline() async throws {
        let clock = BindingClock(), task = UUID(), request = UUID()
        let bindings = SafariClickBindingStore(lifetime: 5, clock: { clock.read() })
        let staged = SafariClickStagedCaptures(bindings: bindings)
        let identity = SafariClickIdentity(pid: 42, window: "window", url: "https://example.com", role: "AXButton", title: "Open", enabled: true, requestDigest: "")
        let ref = AXUIElementCreateSystemWide()
        let candidate = SafariClickCandidate(element: ref, window: ref, launchDate: Date(timeIntervalSince1970: 1), identity: identity)
        let capture = SafariClickCapture { [candidate] }
        let value = try await staged.stage(taskID: task, identity: identity, targetDigest: "target", capture: capture)
        let token = try XCTUnwrap(value)
        let bound = await staged.bind(token: token, taskID: task, requestID: request, digest: "digest")
        XCTAssertTrue(bound)
        let transferValue = await staged.consume(token: token, taskID: task, requestID: request, digest: "digest", targetDigest: "target")
        let transfer = try XCTUnwrap(transferValue)
        try await transfer.verify(expected: identity)
        clock.set(6)
        do { try await transfer.verify(expected: identity); XCTFail("expired transfer") } catch { }
        await staged.cancel(token: token)
        do { try await capture.verify(expected: identity); XCTFail("capture retained") } catch { }
    }

    func testCancelDuringConsumePreventsTransfer() async throws {
        let entered = expectation(description: "consume started")
        let gate = BindingGate(entered)
        let taskID = UUID(), request = UUID()
        let bindings = SafariClickBindingStore(clock: { 1 }, beforeConsume: { await gate.wait() })
        let staged = SafariClickStagedCaptures(bindings: bindings)
        let identity = SafariClickIdentity(pid: 42, window: "window", url: "https://example.com", role: "AXButton", title: "Open", enabled: true, requestDigest: "")
        let ref = AXUIElementCreateSystemWide()
        let candidate = SafariClickCandidate(element: ref, window: ref, launchDate: Date(timeIntervalSince1970: 1), identity: identity)
        let capture = SafariClickCapture { [candidate] }
        let value = try await staged.stage(taskID: taskID, identity: identity, targetDigest: "target", capture: capture)
        let token = try XCTUnwrap(value)
        let bound = await staged.bind(token: token, taskID: taskID, requestID: request, digest: "digest")
        XCTAssertTrue(bound)
        let consume = Task { await staged.consume(token: token, taskID: taskID, requestID: request, digest: "digest", targetDigest: "target") }
        await fulfillment(of: [entered], timeout: 2)
        await staged.cancel(token: token)
        await gate.release()
        let transferred = await consume.value
        XCTAssertNil(transferred)
        do { try await capture.verify(expected: identity); XCTFail("capture retained") } catch { }
    }

    func testBoundCaptureTransferRequiresExactBindingAndIsSingleUse() async throws {
        let identity = SafariClickIdentity(pid: 42, window: "window", url: "https://example.com", role: "AXButton", title: "Open", enabled: true, requestDigest: "")
        let ref = AXUIElementCreateSystemWide()
        let candidate = SafariClickCandidate(element: ref, window: ref, launchDate: Date(timeIntervalSince1970: 1), identity: identity)
        let staged = SafariClickStagedCaptures(bindings: SafariClickBindingStore(clock: { 1 }))
        let task = UUID(), request = UUID()
        let firstCapture = SafariClickCapture { [candidate] }
        let firstValue = try await staged.stage(taskID: task, identity: identity, targetDigest: "target", capture: firstCapture)
        let first = try XCTUnwrap(firstValue)
        let firstBound = await staged.bind(token: first, taskID: task, requestID: request, digest: "digest")
        XCTAssertTrue(firstBound)
        let wrong = await staged.consume(token: first, taskID: task, requestID: request, digest: "wrong", targetDigest: "target")
        XCTAssertNil(wrong)
        do { try await firstCapture.verify(expected: identity); XCTFail("mismatch retained capture") } catch { }
        let secondCapture = SafariClickCapture { [candidate] }
        let secondValue = try await staged.stage(taskID: task, identity: identity, targetDigest: "target", capture: secondCapture)
        let second = try XCTUnwrap(secondValue)
        let secondBound = await staged.bind(token: second, taskID: task, requestID: request, digest: "digest")
        XCTAssertTrue(secondBound)
        let transferred = await staged.consume(token: second, taskID: task, requestID: request, digest: "digest", targetDigest: "target")
        XCTAssertNotNil(transferred)
        let replay = await staged.consume(token: second, taskID: task, requestID: request, digest: "digest", targetDigest: "target")
        XCTAssertNil(replay)
    }
    func testFailedBindingReleasesCapturedElement() async throws {
        let task = UUID()
        let identity = SafariClickIdentity(pid: 42, window: "window", url: "https://example.com", role: "AXButton", title: "Open", enabled: true, requestDigest: "")
        let ref = AXUIElementCreateSystemWide()
        let candidate = SafariClickCandidate(element: ref, window: ref, launchDate: Date(timeIntervalSince1970: 1), identity: identity)
        let capture = SafariClickCapture { [candidate] }
        let staged = SafariClickStagedCaptures(bindings: SafariClickBindingStore(clock: { 1 }))
        let value = try await staged.stage(taskID: task, identity: identity, targetDigest: "target", capture: capture)
        let token = try XCTUnwrap(value)
        let bound = await staged.bind(token: token, taskID: UUID(), requestID: UUID(), digest: "digest")
        XCTAssertFalse(bound)
        do { try await capture.verify(expected: identity); XCTFail("failed binding retained reference") } catch { }
    }
}
#endif
