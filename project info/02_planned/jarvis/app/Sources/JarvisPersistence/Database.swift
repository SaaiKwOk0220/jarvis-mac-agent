import Foundation
import GRDB

public final class Database: @unchecked Sendable {
    private let queue: DatabaseQueue

    public init(path: String) throws {
        queue = try DatabaseQueue(path: path)
    }

    public func migrate() throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("create foundation tables") { database in
            try database.create(table: "tasks") { table in
                table.column("id", .text).primaryKey()
                table.column("title", .text).notNull()
                table.column("status", .text).notNull()
                table.column("created_at", .datetime).notNull()
                table.column("updated_at", .datetime).notNull()
            }

            try database.create(table: "tool_requests") { table in
                table.column("id", .text).primaryKey()
                table.column("task_id", .text).notNull().indexed()
                table.column("name", .text).notNull()
                table.column("side_effect", .text).notNull()
                table.column("target", .text).notNull()
                table.column("payload", .text).notNull()
                table.column("payload_digest", .text).notNull()
                table.column("status", .text).notNull()
                table.column("created_at", .datetime).notNull()
            }

            try database.create(table: "approvals") { table in
                table.column("id", .text).primaryKey()
                table.column("tool_request_id", .text).notNull().indexed()
                table.column("action_digest", .text).notNull()
                table.column("decision", .text).notNull()
                table.column("decided_at", .datetime).notNull()
            }

            try database.create(table: "audit_events") { table in
                table.column("id", .text).primaryKey()
                table.column("timestamp", .datetime).notNull().indexed()
                table.column("task_id", .text).notNull().indexed()
                table.column("worker", .text).notNull()
                table.column("target", .text).notNull()
                table.column("side_effect", .text).notNull()
                table.column("action_digest", .text).notNull()
                table.column("summary", .text).notNull()
                table.column("result", .text).notNull()
                table.column("approval_id", .text)
            }

            try database.create(table: "policy_rules") { table in
                table.column("id", .text).primaryKey()
                table.column("name", .text).notNull().unique()
                table.column("rule", .text).notNull()
                table.column("enabled", .boolean).notNull().defaults(to: true)
                table.column("created_at", .datetime).notNull()
                table.column("updated_at", .datetime).notNull()
            }
        }

        // Kept separate from the foundation migration so existing installations upgrade safely.
        migrator.registerMigration("persist tool request scope") { database in
            let existing = Set(try database.columns(in: "tool_requests").map(\.name))
            if !existing.contains("browser_profile") {
                try database.alter(table: "tool_requests") { $0.add(column: "browser_profile", .text) }
            }
            if !existing.contains("working_directory") {
                try database.alter(table: "tool_requests") { $0.add(column: "working_directory", .text) }
            }
        }

        try migrator.migrate(queue)
    }

    public func read<T>(_ value: (GRDB.Database) throws -> T) throws -> T {
        try queue.read(value)
    }

    public func write<T>(_ updates: (GRDB.Database) throws -> T) throws -> T {
        try queue.write(updates)
    }
}
