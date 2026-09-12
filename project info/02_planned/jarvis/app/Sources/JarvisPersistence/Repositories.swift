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

public enum ApprovalDecision: String, Codable, Sendable, Equatable {
    case approved
    case rejected
}

public struct Approval: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public let toolRequestID: UUID
    public let actionDigest: String
    public let decision: ApprovalDecision
    public let decidedAt: Date

    public init(
        id: UUID = UUID(),
        toolRequestID: UUID,
        actionDigest: String,
        decision: ApprovalDecision,
        decidedAt: Date = Date()
    ) {
        self.id = id
        self.toolRequestID = toolRequestID
        self.actionDigest = actionDigest
        self.decision = decision
        self.decidedAt = decidedAt
    }
}

public struct PolicyRule: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public var name: String
    public var rule: String
    public var enabled: Bool
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        rule: String,
        enabled: Bool = true,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.rule = rule
        self.enabled = enabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
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

public protocol ApprovalRepository: Sendable {
    func insert(_ approval: Approval) throws
    func fetch(id: UUID) throws -> Approval?
    func list() throws -> [Approval]
}

public protocol PolicyRuleRepository: Sendable {
    func upsert(_ policyRule: PolicyRule) throws
    func fetch(id: UUID) throws -> PolicyRule?
    func list() throws -> [PolicyRule]
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

public final class SQLiteApprovalRepository: ApprovalRepository, @unchecked Sendable {
    private let database: Database

    public init(database: Database) {
        self.database = database
    }

    public func insert(_ approval: Approval) throws {
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO approvals (id, tool_request_id, action_digest, decision, decided_at)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: [
                    approval.id.uuidString,
                    approval.toolRequestID.uuidString,
                    approval.actionDigest,
                    approval.decision.rawValue,
                    approval.decidedAt,
                ]
            )
        }
    }

    public func fetch(id: UUID) throws -> Approval? {
        try database.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM approvals WHERE id = ?", arguments: [id.uuidString]) else {
                return nil
            }
            return try approval(from: row)
        }
    }

    public func list() throws -> [Approval] {
        try database.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM approvals ORDER BY decided_at ASC, id ASC").map(approval(from:))
        }
    }
}

public final class SQLitePolicyRuleRepository: PolicyRuleRepository, @unchecked Sendable {
    private let database: Database

    public init(database: Database) {
        self.database = database
    }

    public func upsert(_ policyRule: PolicyRule) throws {
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO policy_rules (id, name, rule, enabled, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        name = excluded.name,
                        rule = excluded.rule,
                        enabled = excluded.enabled,
                        updated_at = excluded.updated_at
                    """,
                arguments: [
                    policyRule.id.uuidString,
                    policyRule.name,
                    policyRule.rule,
                    policyRule.enabled,
                    policyRule.createdAt,
                    policyRule.updatedAt,
                ]
            )
        }
    }

    public func fetch(id: UUID) throws -> PolicyRule? {
        try database.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM policy_rules WHERE id = ?", arguments: [id.uuidString]) else {
                return nil
            }
            return try policyRule(from: row)
        }
    }

    public func list() throws -> [PolicyRule] {
        try database.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM policy_rules ORDER BY name COLLATE NOCASE ASC, id ASC"
            ).map(policyRule(from:))
        }
    }
}

private func task(from row: Row) throws -> Task {
    do {
        let idText: String = try row.decode(forColumn: "id")
        let statusText: String = try row.decode(forColumn: "status")
        guard
            let id = UUID(uuidString: idText),
            let status = TaskStatus(rawValue: statusText)
        else {
            throw PersistenceError.invalidStoredTask
        }

        let title: String = try row.decode(forColumn: "title")
        let createdAt: Date = try row.decode(forColumn: "created_at")
        let updatedAt: Date = try row.decode(forColumn: "updated_at")
        return Task(
            id: id,
            title: title,
            status: status,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    } catch {
        throw PersistenceError.invalidStoredTask
    }
}

private func auditEvent(from row: Row) throws -> AuditEvent {
    do {
        let idText: String = try row.decode(forColumn: "id")
        let taskIDText: String = try row.decode(forColumn: "task_id")
        let sideEffectText: String = try row.decode(forColumn: "side_effect")
        guard
            let id = UUID(uuidString: idText),
            let taskID = UUID(uuidString: taskIDText),
            let sideEffect = SideEffect(rawValue: sideEffectText)
        else {
            throw PersistenceError.invalidStoredAuditEvent
        }

        let approvalIDText: String? = try row.decode(forColumn: "approval_id")
        let approvalID = try approvalID(from: approvalIDText)
        return AuditEvent(
            id: id,
            timestamp: try row.decode(forColumn: "timestamp"),
            taskID: taskID,
            worker: try row.decode(forColumn: "worker"),
            target: try row.decode(forColumn: "target"),
            sideEffect: sideEffect,
            actionDigest: try row.decode(forColumn: "action_digest"),
            summary: try row.decode(forColumn: "summary"),
            result: try row.decode(forColumn: "result"),
            approvalID: approvalID
        )
    } catch {
        throw PersistenceError.invalidStoredAuditEvent
    }
}

private func approvalID(from text: String?) throws -> UUID? {
    guard let text else { return nil }
    guard let id = UUID(uuidString: text) else {
        throw PersistenceError.invalidStoredAuditEvent
    }
    return id
}

private func approval(from row: Row) throws -> Approval {
    do {
        let idText: String = try row.decode(forColumn: "id")
        let toolRequestIDText: String = try row.decode(forColumn: "tool_request_id")
        let decisionText: String = try row.decode(forColumn: "decision")
        guard
            let id = UUID(uuidString: idText),
            let toolRequestID = UUID(uuidString: toolRequestIDText),
            let decision = ApprovalDecision(rawValue: decisionText)
        else {
            throw PersistenceError.invalidStoredApproval
        }

        return Approval(
            id: id,
            toolRequestID: toolRequestID,
            actionDigest: try row.decode(forColumn: "action_digest"),
            decision: decision,
            decidedAt: try row.decode(forColumn: "decided_at")
        )
    } catch {
        throw PersistenceError.invalidStoredApproval
    }
}

private func policyRule(from row: Row) throws -> PolicyRule {
    do {
        let idText: String = try row.decode(forColumn: "id")
        guard let id = UUID(uuidString: idText) else {
            throw PersistenceError.invalidStoredPolicyRule
        }

        return PolicyRule(
            id: id,
            name: try row.decode(forColumn: "name"),
            rule: try row.decode(forColumn: "rule"),
            enabled: try row.decode(forColumn: "enabled"),
            createdAt: try row.decode(forColumn: "created_at"),
            updatedAt: try row.decode(forColumn: "updated_at")
        )
    } catch {
        throw PersistenceError.invalidStoredPolicyRule
    }
}

private enum PersistenceError: Error {
    case invalidStoredTask
    case invalidStoredAuditEvent
    case invalidStoredApproval
    case invalidStoredPolicyRule
}
