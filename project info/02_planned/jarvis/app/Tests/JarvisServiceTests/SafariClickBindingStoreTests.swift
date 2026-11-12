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
