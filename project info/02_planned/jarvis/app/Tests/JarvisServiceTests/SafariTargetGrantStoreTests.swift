import Foundation
import XCTest
@testable import JarvisService

final class SafariTargetGrantStoreTests: XCTestCase {
    func testGrantIsBoundToRequestAndSingleUse() {
        let store = SafariTargetGrantStore(lifetime: 30)
        let task = UUID(), request = UUID()
        let target = SafariCapturedTarget(url: "https://example.com/path?token=secret", processID: 12, windowIdentity: UUID())
        let token = UUID()
        _ = store.insert(target, token: token, taskID: task, requestID: request, requestDigest: "digest", now: 100)
        XCTAssertNil(store.consume(token: token, taskID: UUID(), requestID: request, requestDigest: "digest", now: 101))
        XCTAssertNil(store.consume(token: token, taskID: task, requestID: UUID(), requestDigest: "digest", now: 101))
        XCTAssertNil(store.consume(token: token, taskID: task, requestID: request, requestDigest: "changed", now: 101))
        XCTAssertEqual(store.consume(token: token, taskID: task, requestID: request, requestDigest: "digest", now: 101), target)
        XCTAssertNil(store.consume(token: token, taskID: task, requestID: request, requestDigest: "digest", now: 101))
    }

    func testExpiredOrClearedGrantCannotBeConsumed() {
        let store = SafariTargetGrantStore(lifetime: 2)
        let task = UUID(), request = UUID()
        let target = SafariCapturedTarget(url: "https://example.com/", processID: 42, windowIdentity: UUID())
        let expired = UUID()
        _ = store.insert(target, token: expired, taskID: task, requestID: request, requestDigest: "digest", now: 10)
        XCTAssertNil(store.consume(token: expired, taskID: task, requestID: request, requestDigest: "digest", now: 12))
        let cleared = UUID()
        _ = store.insert(target, token: cleared, taskID: task, requestID: request, requestDigest: "digest", now: 10)
        store.clear(taskID: task)
        XCTAssertNil(store.consume(token: cleared, taskID: task, requestID: request, requestDigest: "digest", now: 10))
    }
}
