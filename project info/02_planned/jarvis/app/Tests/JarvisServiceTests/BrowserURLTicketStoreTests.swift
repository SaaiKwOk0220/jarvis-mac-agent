import XCTest
@testable import JarvisService
import JarvisDomain

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

extension BrowserURLTicketStoreTests {
    func testExpiredTicketCannotBindToRequest() {
        let store = BrowserURLTicketStore(lifetime: 0)
        let ticket = store.issue(url: "https://example.com/private")
        XCTAssertFalse(store.bind(ticket, taskID: UUID(), requestID: UUID()))
    }

    func testBoundTicketRequiresMatchingTaskAndRequestAndCannotUseUnboundConsume() {
        let store = BrowserURLTicketStore()
        let ticket = store.issue(url: "https://example.com/private")
        let task = UUID(), request = UUID()
        XCTAssertTrue(store.bind(ticket, taskID: task, requestID: request))
        XCTAssertFalse(store.bind(ticket, taskID: task, requestID: request))
        XCTAssertNil(store.consume(id: ticket.id, digest: ticket.digest))
        XCTAssertNil(store.peekBound(ticket, taskID: UUID(), requestID: request))
        XCTAssertNil(store.consumeBound(ticket, taskID: task, requestID: UUID()))
        XCTAssertEqual(store.consumeBound(ticket, taskID: task, requestID: request), "https://example.com/private")
        XCTAssertNil(store.consumeBound(ticket, taskID: task, requestID: request))
    }

    func testPeekChecksDigestAndExpiryWithoutConsuming() {
        let store = BrowserURLTicketStore(lifetime: 5)
        let ticket = store.issue(url: "https://example.com/private", now: Date(timeIntervalSince1970: 10))
        XCTAssertNil(store.peek(id: ticket.id, digest: "wrong", now: Date(timeIntervalSince1970: 11)))
        XCTAssertEqual(store.peek(id: ticket.id, digest: ticket.digest, now: Date(timeIntervalSince1970: 11)), "https://example.com/private")
        XCTAssertNil(store.peek(id: ticket.id, digest: ticket.digest, now: Date(timeIntervalSince1970: 15)))
    }
    func testConcurrentConsumptionReturnsValueExactlyOnce() async {
        let store = BrowserURLTicketStore()
        let ticket = store.issue(url: "https://example.com/private")
        let count = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for _ in 0..<20 { group.addTask { store.consume(id: ticket.id, digest: ticket.digest) != nil } }
            var count = 0
            for await succeeded in group { if succeeded { count += 1 } }
            return count
        }
        XCTAssertEqual(count, 1)
    }
}

extension BrowserURLTicketStoreTests {
    func testPersistableRequestContainsOnlyOriginAndTicket() throws {
        let store = BrowserURLTicketStore()
        let url = "https://example.com/private?token=secret"
        let ticket = store.issue(url: url)
        let original = ToolRequest(taskID: UUID(), name: "browser_open", sideEffect: .externalSend, target: url, payload: "Open in browser")
        let stored = try store.persistableRequest(original, ticket: ticket)
        XCTAssertEqual(stored.target, "https://example.com")
        XCTAssertFalse(stored.payload.contains("secret"))
        XCTAssertFalse(stored.payload.contains("private"))
        XCTAssertTrue(stored.payload.contains(ticket.digest))
    }
}

extension BrowserURLTicketStoreTests {
    func testNewStoreCannotRestorePriorProcessTicket() {
        let firstStore = BrowserURLTicketStore()
        let ticket = firstStore.issue(url: "https://example.com/private?token=secret")
        let restartedStore = BrowserURLTicketStore()
        XCTAssertNil(restartedStore.peek(id: ticket.id, digest: ticket.digest))
        XCTAssertNil(restartedStore.consume(id: ticket.id, digest: ticket.digest))
    }
}
