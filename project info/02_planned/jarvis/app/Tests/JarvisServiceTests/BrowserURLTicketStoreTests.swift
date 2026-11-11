import XCTest
@testable import JarvisService

final class BrowserURLTicketStoreTests: XCTestCase {
    func testTicketIsDigestBoundAndConsumedOnce() {
        let store = BrowserURLTicketStore()
        let ticket = store.issue(url: "https://example.com/private?token=secret", now: Date(timeIntervalSince1970: 10))
        XCTAssertNil(store.consume(id: ticket.id, digest: "wrong", now: Date(timeIntervalSince1970: 11)))
        XCTAssertEqual(store.consume(id: ticket.id, digest: ticket.digest, now: Date(timeIntervalSince1970: 11)), "https://example.com/private?token=secret")
        XCTAssertNil(store.consume(id: ticket.id, digest: ticket.digest, now: Date(timeIntervalSince1970: 12)))
    }
    func testExpiredAndRevokedTicketsFailClosed() {
        let store = BrowserURLTicketStore(lifetime: 5)
        let first = store.issue(url: "https://example.com/a", now: Date(timeIntervalSince1970: 10))
        XCTAssertNil(store.consume(id: first.id, digest: first.digest, now: Date(timeIntervalSince1970: 15)))
        let second = store.issue(url: "https://example.com/b", now: Date(timeIntervalSince1970: 10))
        store.revoke(id: second.id)
        XCTAssertNil(store.consume(id: second.id, digest: second.digest, now: Date(timeIntervalSince1970: 11)))
    }
}
