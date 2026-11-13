import Foundation
import XCTest
@testable import JarvisService

final class SafariTargetGrantStoreTests: XCTestCase {
    func testGrantIsBoundToRequestAndSingleUse() throws {
        let store = SafariTargetGrantStore(lifetime: 30)
        let task = UUID(), request = UUID()
        let target = SafariCapturedTarget(url: "https://example.com/path?token=secret", processID: 12, windowIdentity: UUID())
        let token = UUID()
        _ = try store.insert(target, token: token, taskID: task, requestID: request, requestDigest: "digest", now: 100)
        XCTAssertNil(store.consume(token: token, taskID: UUID(), requestID: request, requestDigest: "digest", now: 101))
        XCTAssertNil(store.consume(token: token, taskID: task, requestID: UUID(), requestDigest: "digest", now: 101))
        XCTAssertNil(store.consume(token: token, taskID: task, requestID: request, requestDigest: "changed", now: 101))
        XCTAssertEqual(store.consume(token: token, taskID: task, requestID: request, requestDigest: "digest", now: 101), target)
        XCTAssertNil(store.consume(token: token, taskID: task, requestID: request, requestDigest: "digest", now: 101))
    }

    func testRejectsUnsafeCapturedURLAndPreservesSensitiveQueryOnlyInMemory() throws {
        let store = SafariTargetGrantStore(lifetime: 30)
        let task = UUID(), request = UUID(), token = UUID()
        for raw in ["http://example.com/", "https://user:password@example.com/", "https://example.com/#fragment", "https://example.com/" + String(repeating: "a", count: 4097)] {
            let target = SafariCapturedTarget(url: raw, processID: 1, windowIdentity: UUID())
            XCTAssertThrowsError(try store.insert(target, token: token, taskID: task, requestID: request, requestDigest: "digest", now: 100))
            XCTAssertNil(store.consume(token: token, taskID: task, requestID: request, requestDigest: "digest", now: 101))
        }
    }

    func testExpiredOrClearedGrantCannotBeConsumed() throws {
        let store = SafariTargetGrantStore(lifetime: 2)
        let task = UUID(), request = UUID()
        let target = SafariCapturedTarget(url: "https://example.com/", processID: 42, windowIdentity: UUID())
        let expired = UUID()
        _ = try store.insert(target, token: expired, taskID: task, requestID: request, requestDigest: "digest", now: 10)
        XCTAssertNil(store.consume(token: expired, taskID: task, requestID: request, requestDigest: "digest", now: 12))
        let cleared = UUID()
        _ = try store.insert(target, token: cleared, taskID: task, requestID: request, requestDigest: "digest", now: 10)
        store.clear(taskID: task)
        XCTAssertNil(store.consume(token: cleared, taskID: task, requestID: request, requestDigest: "digest", now: 10))
    }
}
