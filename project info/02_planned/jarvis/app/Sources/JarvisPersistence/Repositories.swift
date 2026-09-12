import Foundation
import GRDB
import JarvisDomain

public struct AuditEvent: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public let timestamp: Date
    public let taskID: UUID
    public let worker: String
    public let target: String
    public let sideEffect: SideEffect
    public let actionDigest: String
    public let summary: String
    public let result: String
    public let approvalID: UUID?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        taskID: UUID,
        worker: String,
        target: String,
        sideEffect: SideEffect,
        actionDigest: String,
        summary: String,
        result: String,
        approvalID: UUID?
    ) {
        self.id = id
        self.timestamp = timestamp
        self.taskID = taskID
        self.worker = worker
        self.target = target
        self.sideEffect = sideEffect
        self.actionDigest = actionDigest
        self.summary = summary
        self.result = result
        self.approvalID = approvalID
    }
}

public protocol TaskRepository: Sendable {
    func insert(_ task: Task) throws
    func updateStatus(_ id: UUID, status: TaskStatus, updatedAt: Date) throws
    func fetch(id: UUID) throws -> Task?
    func list() throws -> [Task]
}

public protocol AuditRepository: Sendable {
    func append(_ event: AuditEvent) throws
    func events(for taskID: UUID) throws -> [AuditEvent]
}

public final class SQLiteTaskRepository: TaskRepository, @unchecked Sendable {
    private let database: Database

    public init(database: Database) {
        self.database = database
    }

    public func insert(_ task: Task) throws {
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO tasks (id, title, status, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: [task.id.uuidString, task.title, task.status.rawValue, task.createdAt, task.updatedAt]
            )
        }
    }

    public func updateStatus(_ id: UUID, status: TaskStatus, updatedAt: Date) throws {
        try database.write { db in
            try db.execute(
                sql: "UPDATE tasks SET status = ?, updated_at = ? WHERE id = ?",
                arguments: [status.rawValue, updatedAt, id.uuidString]
            )
        }
    }

    public func fetch(id: UUID) throws -> Task? {
        try database.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM tasks WHERE id = ?", arguments: [id.uuidString]) else {
                return nil
            }
            return try task(from: row)
        }
    }

    public func list() throws -> [Task] {
        try database.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM tasks ORDER BY updated_at DESC, id ASC").map(task(from:))
        }
    }
}

public final class SQLiteAuditRepository: AuditRepository, @unchecked Sendable {
    private let database: Database

    public init(database: Database) {
        self.database = database
    }

    public func append(_ event: AuditEvent) throws {
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO audit_events
                    (id, timestamp, task_id, worker, target, side_effect, action_digest, summary, result, approval_id)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    event.id.uuidString,
                    event.timestamp,
                    event.taskID.uuidString,
                    redactSecrets(event.worker),
                    redactSecrets(event.target),
                    event.sideEffect.rawValue,
                    redactSecrets(event.actionDigest),
                    redactSecrets(event.summary),
                    redactSecrets(event.result),
                    event.approvalID?.uuidString,
                ]
            )
        }
    }

    public func events(for taskID: UUID) throws -> [AuditEvent] {
        try database.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM audit_events WHERE task_id = ? ORDER BY timestamp ASC, id ASC",
                arguments: [taskID.uuidString]
            ).map(auditEvent(from:))
        }
    }
}

private func task(from row: Row) throws -> Task {
    guard
        let id = UUID(uuidString: row["id"] as String),
        let status = TaskStatus(rawValue: row["status"] as String)
    else {
        throw PersistenceError.invalidStoredTask
    }

    return Task(
        id: id,
        title: row["title"],
        status: status,
        createdAt: row["created_at"],
        updatedAt: row["updated_at"]
    )
}

private func auditEvent(from row: Row) throws -> AuditEvent {
    guard
        let id = UUID(uuidString: row["id"] as String),
        let taskID = UUID(uuidString: row["task_id"] as String),
        let sideEffect = SideEffect(rawValue: row["side_effect"] as String)
    else {
        throw PersistenceError.invalidStoredAuditEvent
    }

    let approvalID = (row["approval_id"] as String?).flatMap(UUID.init(uuidString:))
    return AuditEvent(
        id: id,
        timestamp: row["timestamp"],
        taskID: taskID,
        worker: row["worker"],
        target: row["target"],
        sideEffect: sideEffect,
        actionDigest: row["action_digest"],
        summary: row["summary"],
        result: row["result"],
        approvalID: approvalID
    )
}

private enum PersistenceError: Error {
    case invalidStoredTask
    case invalidStoredAuditEvent
}
