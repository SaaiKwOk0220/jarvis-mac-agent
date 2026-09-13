import Foundation
import GRDB
import XCTest
@testable import JarvisDomain
@testable import JarvisPersistence

final class RepositoryTests: XCTestCase {
    func testMigrationCreatesTheRequiredTables() throws {
        let database = try JarvisPersistence.Database(path: ":memory:")

        try database.migrate()
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
        let task = JarvisTask(
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
            summary: #"{"password":"do-not-store","api_key":"also-do-not-store"}"#,
            result: "api_key=also-do-not-store",
            approvalID: nil
        )

        try repository.append(later)
        try repository.append(earlier)

        let rawAuditFields = try database.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT summary, result FROM audit_events WHERE id = ?",
                arguments: [earlier.id.uuidString]
            )
        }
        XCTAssertEqual(
            rawAuditFields?["summary"] as String?,
            #"{"password":"[REDACTED]","api_key":"[REDACTED]"}"#
        )
        XCTAssertEqual(rawAuditFields?["result"] as String?, "api_key=[REDACTED]")

        let events = try repository.events(for: taskID)
        XCTAssertEqual(events.map(\.id), [earlier.id, later.id])
        XCTAssertEqual(events[0].summary, #"{"password":"[REDACTED]","api_key":"[REDACTED]"}"#)
        XCTAssertEqual(events[0].result, "api_key=[REDACTED]")
        XCTAssertEqual(events[1].summary, "Authorization: Bearer [REDACTED]")
        XCTAssertEqual(events[1].result, "cookie=session=[REDACTED]")
    }

    func testAuditEventsWithTheSameTimestampKeepAppendOrder() throws {
        let database = try migratedDatabase()
        let repository = SQLiteAuditRepository(database: database)
        let taskID = UUID()
        let timestamp = Date(timeIntervalSince1970: 1_725_000_000)
        let first = AuditEvent(timestamp: timestamp, taskID: taskID, worker: "worker", target: "one",
            sideEffect: .read, actionDigest: "one", summary: "first", result: "one", approvalID: nil)
        let second = AuditEvent(timestamp: timestamp, taskID: taskID, worker: "worker", target: "two",
            sideEffect: .read, actionDigest: "two", summary: "second", result: "two", approvalID: nil)

        try repository.append(first)
        try repository.append(second)

        XCTAssertEqual(try repository.events(for: taskID).map(\.id), [first.id, second.id])
    }

    func testRedactSecretsCoversRepresentativeSecretShapes() {
        XCTAssertEqual(redactSecrets("api_key=abc123"), "api_key=[REDACTED]")
        XCTAssertEqual(redactSecrets("Cookie: sid=secret"), "Cookie: [REDACTED]")
        XCTAssertEqual(redactSecrets("Bearer token-value"), "Bearer [REDACTED]")
        XCTAssertEqual(redactSecrets("password: hunter2"), "password: [REDACTED]")
    }

    func testRedactSecretsPreservesQuotedJSONStructureWhileRemovingValues() {
        let input = #"{"password":"hunter2","api_key":"abc123","cookie":"sid=secret"}"#

        XCTAssertEqual(
            redactSecrets(input),
            #"{"password":"[REDACTED]","api_key":"[REDACTED]","cookie":"[REDACTED]"}"#
        )
    }

    func testRedactSecretsCoversAdditionalAuthorizationURLTokenAndQuotedPasswordForms() {
        XCTAssertEqual(
            redactSecrets("Authorization: Basic dXNlcjpwYXNz"),
            "Authorization: Basic [REDACTED]"
        )
        XCTAssertEqual(
            redactSecrets("https://alice:very-secret@example.com/path"),
            "https://[REDACTED]@example.com/path"
        )
        XCTAssertEqual(redactSecrets("refresh_token=refresh-secret"), "refresh_token=[REDACTED]")
        XCTAssertEqual(redactSecrets(#"password="secret with spaces""#), #"password="[REDACTED]""#)
    }

    func testAuditStorageRedactsAdditionalSecretFormsInRawFields() throws {
        let database = try migratedDatabase()
        let repository = SQLiteAuditRepository(database: database)
        let event = AuditEvent(
            taskID: UUID(),
            worker: "Authorization: Basic basic-secret",
            target: "https://alice:very-secret@example.com/path",
            sideEffect: .externalSend,
            actionDigest: "refresh_token=refresh-secret",
            summary: #"password="secret with spaces""#,
            result: "completed",
            approvalID: nil
        )

        try repository.append(event)

        let row = try XCTUnwrap(database.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT worker, target, action_digest, summary, result FROM audit_events WHERE id = ?",
                arguments: [event.id.uuidString]
            )
        })
        let rawFields: [String] = try [
            row.decode(String.self, forColumn: "worker"),
            row.decode(String.self, forColumn: "target"),
            row.decode(String.self, forColumn: "action_digest"),
            row.decode(String.self, forColumn: "summary"),
            row.decode(String.self, forColumn: "result"),
        ]

        for secret in ["basic-secret", "alice", "very-secret", "refresh-secret", "secret with spaces"] {
            XCTAssertFalse(rawFields.joined(separator: " ").contains(secret))
        }
    }

    func testRedactSecretsCoversUsernameOnlyCookieAndEscapedJSONForms() {
        XCTAssertEqual(
            redactSecrets("https://oauth-token@example.com/path"),
            "https://[REDACTED]@example.com/path"
        )
        XCTAssertEqual(redactSecrets("cookie=secret-cookie"), "cookie=[REDACTED]")
        XCTAssertEqual(
            redactSecrets(#"{"password":"prefix\" second-secret"}"#),
            #"{"password":"[REDACTED]"}"#
        )
    }

    func testAuditStorageRedactsUsernameOnlyCookieAndEscapedJSONFormsInRawFields() throws {
        let database = try migratedDatabase()
        let repository = SQLiteAuditRepository(database: database)
        let event = AuditEvent(
            taskID: UUID(),
            worker: "https://oauth-token@example.com/path",
            target: "cookie=secret-cookie",
            sideEffect: .externalSend,
            actionDigest: "digest",
            summary: #"{"password":"prefix\" second-secret"}"#,
            result: "completed",
            approvalID: nil
        )

        try repository.append(event)

        let row = try XCTUnwrap(database.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT worker, target, action_digest, summary, result FROM audit_events WHERE id = ?",
                arguments: [event.id.uuidString]
            )
        })
        let rawFields: [String] = try [
            row.decode(String.self, forColumn: "worker"),
            row.decode(String.self, forColumn: "target"),
            row.decode(String.self, forColumn: "action_digest"),
            row.decode(String.self, forColumn: "summary"),
            row.decode(String.self, forColumn: "result"),
        ]

        for secret in ["oauth-token", "secret-cookie", "second-secret"] {
            XCTAssertFalse(rawFields.joined(separator: " ").contains(secret))
        }
    }

    func testApprovalRepositoryRoundTripsApprovalsInDecisionOrder() throws {
        let repository = SQLiteApprovalRepository(database: try migratedDatabase())
        let later = Approval(
            toolRequestID: UUID(),
            actionDigest: "digest-later",
            decision: .approved,
            decidedAt: Date(timeIntervalSince1970: 1_725_000_010)
        )
        let earlier = Approval(
            toolRequestID: UUID(),
            actionDigest: "digest-earlier",
            decision: .rejected,
            decidedAt: Date(timeIntervalSince1970: 1_725_000_005)
        )

        try repository.insert(later)
        try repository.insert(earlier)

        XCTAssertEqual(try repository.fetch(id: later.id), later)
        XCTAssertEqual(try repository.list(), [earlier, later])
    }

    func testPolicyRuleRepositoryRoundTripsEnabledStateInDeterministicNameOrder() throws {
        let repository = SQLitePolicyRuleRepository(database: try migratedDatabase())
        let alpha = PolicyRule(
            name: "alpha",
            rule: "allow read-only tools",
            enabled: false,
            createdAt: Date(timeIntervalSince1970: 1_725_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_725_000_001)
        )
        let zulu = PolicyRule(
            name: "Zulu",
            rule: "require approval for sends",
            enabled: true,
            createdAt: Date(timeIntervalSince1970: 1_725_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_725_000_001)
        )

        try repository.upsert(zulu)
        try repository.upsert(alpha)

        XCTAssertEqual(try repository.fetch(id: alpha.id), alpha)
        XCTAssertEqual(try repository.list(), [alpha, zulu])
    }

    func testTaskRepositoryThrowsForCorruptUUIDEnumAndNullFields() throws {
        let database = try corruptDatabase(with: """
            CREATE TABLE tasks (
                id,
                title,
                status,
                created_at,
                updated_at
            )
            """)
        let repository = SQLiteTaskRepository(database: database)
        let date = Date(timeIntervalSince1970: 1_725_000_000)

        try database.write { db in
            try db.execute(
                sql: "INSERT INTO tasks VALUES (?, ?, ?, ?, ?)",
                arguments: ["not-a-uuid", "title", "draft", date, date]
            )
        }
        XCTAssertThrowsError(try repository.list())

        try database.write { db in
            try db.execute(sql: "DELETE FROM tasks")
            try db.execute(
                sql: "INSERT INTO tasks VALUES (?, ?, ?, ?, ?)",
                arguments: [UUID().uuidString, "title", "not-a-status", date, date]
            )
        }
        XCTAssertThrowsError(try repository.list())

        try database.write { db in
            try db.execute(sql: "DELETE FROM tasks")
            try db.execute(
                sql: "INSERT INTO tasks VALUES (?, ?, ?, ?, ?)",
                arguments: [UUID().uuidString, nil, "draft", date, date]
            )
        }
        XCTAssertThrowsError(try repository.list())
    }

    func testAuditRepositoryThrowsForCorruptUUIDEnumAndNullFields() throws {
        let database = try corruptDatabase(with: """
            CREATE TABLE audit_events (
                id,
                timestamp,
                task_id,
                worker,
                target,
                side_effect,
                action_digest,
                summary,
                result,
                approval_id
            )
            """)
        let repository = SQLiteAuditRepository(database: database)
        let taskID = UUID()
        let date = Date(timeIntervalSince1970: 1_725_000_000)

        try database.write { db in
            try db.execute(
                sql: "INSERT INTO audit_events VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                arguments: ["not-a-uuid", date, taskID.uuidString, "worker", "target", "read", "digest", "summary", "result", nil]
            )
        }
        XCTAssertThrowsError(try repository.events(for: taskID))

        try database.write { db in
            try db.execute(sql: "DELETE FROM audit_events")
            try db.execute(
                sql: "INSERT INTO audit_events VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                arguments: [UUID().uuidString, date, taskID.uuidString, "worker", "target", "not-an-effect", "digest", "summary", "result", nil]
            )
        }
        XCTAssertThrowsError(try repository.events(for: taskID))

        try database.write { db in
            try db.execute(sql: "DELETE FROM audit_events")
            try db.execute(
                sql: "INSERT INTO audit_events VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                arguments: [UUID().uuidString, date, taskID.uuidString, "worker", "target", "read", "digest", nil, "result", nil]
            )
        }
        XCTAssertThrowsError(try repository.events(for: taskID))
    }

    private func migratedDatabase() throws -> JarvisPersistence.Database {
        let database = try JarvisPersistence.Database(path: ":memory:")
        try database.migrate()
        return database
    }

    private func corruptDatabase(with tableDefinition: String) throws -> JarvisPersistence.Database {
        let database = try JarvisPersistence.Database(path: ":memory:")
        try database.write { db in
            try db.execute(sql: tableDefinition)
        }
        return database
    }
}
