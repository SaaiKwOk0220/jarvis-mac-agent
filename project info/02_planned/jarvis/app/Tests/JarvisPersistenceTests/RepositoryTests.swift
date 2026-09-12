import Foundation
import GRDB
import XCTest
@testable import JarvisDomain
@testable import JarvisPersistence

final class RepositoryTests: XCTestCase {
    func testMigrationCreatesTheRequiredTables() throws {
        let database = try JarvisPersistence.Database(path: ":memory:")

        try database.migrate()

        let tables = try database.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name"
            )
        }
        XCTAssertTrue(Set(["tasks", "tool_requests", "approvals", "audit_events", "policy_rules"]).isSubset(of: Set(tables)))
    }

    func testTaskRoundTripPreservesFieldsAndStatusUpdate() throws {
        let database = try migratedDatabase()
        let repository = SQLiteTaskRepository(database: database)
        let createdAt = Date(timeIntervalSince1970: 1_725_000_000)
        let initialUpdate = Date(timeIntervalSince1970: 1_725_000_001)
        let updatedAt = Date(timeIntervalSince1970: 1_725_000_002)
        let task = Task(
            title: "Prepare a release",
            status: .planning,
            createdAt: createdAt,
            updatedAt: initialUpdate
        )

        try repository.insert(task)
        try repository.updateStatus(task.id, status: .running, updatedAt: updatedAt)

        let stored = try XCTUnwrap(repository.fetch(id: task.id))
        XCTAssertEqual(stored.id, task.id)
        XCTAssertEqual(stored.title, "Prepare a release")
        XCTAssertEqual(stored.status, .running)
        XCTAssertEqual(stored.createdAt, createdAt)
        XCTAssertEqual(stored.updatedAt, updatedAt)
        let listed = try repository.list()
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed.first?.id, stored.id)
    }

    func testAuditEventsAreReturnedInTimestampOrderAndSecretsAreRedacted() throws {
        let database = try migratedDatabase()
        let repository = SQLiteAuditRepository(database: database)
        let taskID = UUID()
        let later = AuditEvent(
            timestamp: Date(timeIntervalSince1970: 1_725_000_010),
            taskID: taskID,
            worker: "operator",
            target: "https://example.com",
            sideEffect: .externalSend,
            actionDigest: "digest-later",
            summary: "Authorization: Bearer first-token",
            result: "cookie=session=secret-cookie",
            approvalID: UUID()
        )
        let earlier = AuditEvent(
            timestamp: Date(timeIntervalSince1970: 1_725_000_005),
            taskID: taskID,
            worker: "operator",
            target: "https://example.com",
            sideEffect: .externalSend,
            actionDigest: "digest-earlier",
            summary: "password=do-not-store",
            result: "api_key=also-do-not-store",
            approvalID: nil
        )

        try repository.append(later)
        try repository.append(earlier)

        let events = try repository.events(for: taskID)
        XCTAssertEqual(events.map(\.id), [earlier.id, later.id])
        XCTAssertEqual(events[0].summary, "password=[REDACTED]")
        XCTAssertEqual(events[0].result, "api_key=[REDACTED]")
        XCTAssertEqual(events[1].summary, "Authorization: Bearer [REDACTED]")
        XCTAssertEqual(events[1].result, "cookie=session=[REDACTED]")
    }

    func testRedactSecretsCoversRepresentativeSecretShapes() {
        XCTAssertEqual(redactSecrets("api_key=abc123"), "api_key=[REDACTED]")
        XCTAssertEqual(redactSecrets("Cookie: sid=secret"), "Cookie: [REDACTED]")
        XCTAssertEqual(redactSecrets("Bearer token-value"), "Bearer [REDACTED]")
        XCTAssertEqual(redactSecrets("password: hunter2"), "password: [REDACTED]")
    }

    private func migratedDatabase() throws -> JarvisPersistence.Database {
        let database = try JarvisPersistence.Database(path: ":memory:")
        try database.migrate()
        return database
    }
}
