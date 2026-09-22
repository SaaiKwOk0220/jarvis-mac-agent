import Foundation
import GRDB
import JarvisPersistence

/// SQLite-backed implementation of `Memory`. The store reuses the same
/// `Database` that holds tasks, approvals, and audit events — adding a new
/// table here means one extra `CREATE TABLE IF NOT EXISTS` and one index,
/// which `SQLiteMemoryStore.init` runs lazily so callers do not have to
/// remember a separate migrate step.
///
/// `createdAt` and `updatedAt` are stored as ISO-8601 text by GRDB's
/// `.datetime` column codec, identical to the rest of the schema.
///
/// The `Database` type is qualified with the module name because `GRDB`
/// also exports a `Database` type; the existing repositories file
/// (`JarvisPersistence/Repositories.swift`) follows the same convention
/// when it needs to disambiguate at call sites.
public final class SQLiteMemoryStore: Memory, @unchecked Sendable {
    private let database: JarvisPersistence.Database

    public init(database: JarvisPersistence.Database) throws {
        self.database = database
        try ensureSchema()
    }

    /// Creates `memory_entries` and its category index if they do not already
    /// exist. Idempotent so the store is safe to instantiate against a fresh
    /// `:memory:` database or an already-migrated production database.
    private func ensureSchema() throws {
        try database.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS memory_entries (
                    id TEXT PRIMARY KEY,
                    category TEXT NOT NULL,
                    key TEXT NOT NULL,
                    value TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    UNIQUE(category, key)
                )
                """)
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_memory_category ON memory_entries(category)
                """)
        }
    }

    public func list(category: String?) async throws -> [MemoryEntry] {
        try database.read { db in
            let rows: [Row]
            if let category {
                rows = try Row.fetchAll(
                    db,
                    sql: "SELECT * FROM memory_entries WHERE category = ? ORDER BY rowid ASC",
                    arguments: [category]
                )
            } else {
                rows = try Row.fetchAll(
                    db,
                    sql: "SELECT * FROM memory_entries ORDER BY rowid ASC"
                )
            }
            return try rows.map(entry(from:))
        }
    }

    public func set(category: String, key: String, value: String) async throws {
        let trimmedCategory = category.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCategory.isEmpty, !trimmedKey.isEmpty, !trimmedValue.isEmpty else {
            throw MemoryStoreError.invalidInput
        }
        try database.write { db in
            if let existing = try Row.fetchOne(
                db,
                sql: "SELECT id FROM memory_entries WHERE category = ? AND key = ?",
                arguments: [trimmedCategory, trimmedKey]
            ) {
                let id: String = existing["id"]
                try db.execute(
                    sql: "UPDATE memory_entries SET value = ?, updated_at = ? WHERE id = ?",
                    arguments: [trimmedValue, Date(), id]
                )
            } else {
                let now = Date()
                try db.execute(
                    sql: """
                        INSERT INTO memory_entries (id, category, key, value, created_at, updated_at)
                        VALUES (?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [UUID().uuidString, trimmedCategory, trimmedKey, trimmedValue, now, now]
                )
            }
        }
    }

    public func delete(id: UUID) async throws {
        try database.write { db in
            try db.execute(
                sql: "DELETE FROM memory_entries WHERE id = ?",
                arguments: [id.uuidString]
            )
        }
    }

    public func formatContext() async throws -> String {
        let entries = try await list(category: nil)
        guard !entries.isEmpty else { return "" }
        var lines: [String] = ["Known facts:"]
        for entry in entries {
            lines.append("- \(entry.category): \(entry.key) = \"\(entry.value)\"")
        }
        return lines.joined(separator: "\n")
    }
}

/// Decodes a `memory_entries` row. The UUID must parse — corrupt storage
/// surfaces as `MemoryStoreError.invalidStoredEntry` rather than a silent
/// partial read, matching the failure mode of the other repositories.
private func entry(from row: Row) throws -> MemoryEntry {
    guard let id = UUID(uuidString: try row.decode(forColumn: "id")) else {
        throw MemoryStoreError.invalidStoredEntry
    }
    return MemoryEntry(
        id: id,
        category: try row.decode(forColumn: "category"),
        key: try row.decode(forColumn: "key"),
        value: try row.decode(forColumn: "value"),
        createdAt: try row.decode(forColumn: "created_at"),
        updatedAt: try row.decode(forColumn: "updated_at")
    )
}

private enum MemoryStoreError: Error {
    case invalidInput
    case invalidStoredEntry
}