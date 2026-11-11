import XCTest
@testable import JarvisService

final class EphemeralToolResultStoreTests: XCTestCase {
    func testResultsAreScopedSingleUseAndExpire() {
        let store = EphemeralToolResultStore(lifetime: 10)
        let task = UUID(), request = UUID(), now: TimeInterval = 100
        store.put("secret", taskID: task, requestID: request, digest: "a", now: now)
        XCTAssertNil(store.take(taskID: UUID(), requestID: request, digest: "a", now: now))
        XCTAssertNil(store.take(taskID: task, requestID: request, digest: "wrong", now: now))
        XCTAssertEqual(store.take(taskID: task, requestID: request, digest: "a", now: now), "secret")
        XCTAssertNil(store.take(taskID: task, requestID: request, digest: "a", now: now))
        store.put("expired", taskID: task, requestID: request, digest: "a", now: now)
        XCTAssertNil(store.take(taskID: task, requestID: request, digest: "a", now: now + 11))
    }

    func testClearRemovesOnlyMatchingTask() {
        let store = EphemeralToolResultStore(lifetime: 10)
        let first = UUID(), second = UUID(), one = UUID(), two = UUID(), now = ProcessInfo.processInfo.systemUptime
        store.put("one", taskID: first, requestID: one, digest: "d", now: now)
        store.put("two", taskID: second, requestID: two, digest: "d", now: now)
        store.clear(taskID: first)
        XCTAssertNil(store.take(taskID: first, requestID: one, digest: "d", now: now))
        XCTAssertEqual(store.take(taskID: second, requestID: two, digest: "d", now: now), "two")
    }
}
