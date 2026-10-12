import Foundation
import XCTest
import JarvisPersistence
import JarvisMenuBar

/// Verifies that the SQLite-backed memory store survives the round-trip from
/// `set` → `list` → `formatContext`, that upserts by `(category, key)` do not
/// produce duplicates, and that the LLM-facing context string matches the
/// format the prompt layer expects.
///
/// The store is constructed against a `:memory:` SQLite database using the
/// same `migrate()` pattern as `RepositoryTests`, so each test sees a fresh
/// schema with no fixtures to clean up.
final class SQLiteMemoryStoreTests: XCTestCase {

    func testSetCreatesNewEntry() async throws {
        let store = try freshStore()

        try await store.set(category: "identity", key: "name", value: "Alex")

        let entries = try await store.list(category: nil)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].category, "identity")
        XCTAssertEqual(entries[0].key, "name")
        XCTAssertEqual(entries[0].value, "Alex")
    }

    func testSetUpdatesExistingEntryByCategoryKey() async throws {
        let store = try freshStore()

        try await store.set(category: "preference", key: "editor", value: "vim")
        let originalList = try await store.list(category: nil)
        let original = try XCTUnwrap(originalList.first)
        let originalCreatedAt = original.createdAt
        let originalUpdatedAt = original.updatedAt
        // Bump the clock so the upsert's `updated_at` is provably later than
        // the insert's. Two same-tick writes would still be valid updates but
        // would not let us assert that updatedAt changes.
        try await Task.sleep(nanoseconds: 2_000_000)

        try await store.set(category: "preference", key: "editor", value: "emacs")

        let entries = try await store.list(category: nil)
        XCTAssertEqual(entries.count, 1, "upsert must not create a duplicate row")
        let updated = try XCTUnwrap(entries.first)
        XCTAssertEqual(updated.value, "emacs")
        XCTAssertEqual(
            updated.id,
            original.id,
            "upsert must reuse the existing row's id"
        )
        XCTAssertEqual(
            updated.createdAt,
            originalCreatedAt,
            "createdAt must be preserved across an upsert"
        )
        XCTAssertGreaterThanOrEqual(updated.updatedAt, originalUpdatedAt)
    }

    func testDeleteRemovesEntry() async throws {
        let store = try freshStore()
        try await store.set(category: "fact", key: "workdir", value: "/Users")
        let initialEntries = try await store.list(category: nil)
        let entry = try XCTUnwrap(initialEntries.first)

        try await store.delete(id: entry.id)

        let entries = try await store.list(category: nil)
        XCTAssertTrue(entries.isEmpty)
    }

    func testListFiltersByCategory() async throws {
        let store = try freshStore()
        try await store.set(category: "identity", key: "name", value: "Alex")
        try await store.set(category: "preference", key: "editor", value: "vim")
        try await store.set(category: "fact", key: "workdir", value: "/path")

        let identity = try await store.list(category: "identity")
        XCTAssertEqual(identity.map(\.category), ["identity"])

        let preference = try await store.list(category: "preference")
        XCTAssertEqual(preference.map(\.category), ["preference"])

        let fact = try await store.list(category: "fact")
        XCTAssertEqual(fact.map(\.category), ["fact"])

        let all = try await store.list(category: nil)
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(Set(all.map(\.category)), ["identity", "preference", "fact"])
    }

    func testFormatContextEmpty() async throws {
        let store = try freshStore()

        let context = try await store.formatContext()

        XCTAssertEqual(context, "")
    }

    func testFormatContextRendersKnownFacts() async throws {
        let store = try freshStore()
        try await store.set(category: "identity", key: "name", value: "Alex")
        try await store.set(category: "preference", key: "editor", value: "vim")
        try await store.set(category: "fact", key: "workdir", value: "/path")

        let context = try await store.formatContext()

        XCTAssertEqual(context, """
        Known facts:
        - identity: name = "Alex"
        - preference: editor = "vim"
        - fact: workdir = "/path"
        """)
    }

    /// Builds a fresh `:memory:` database and constructs a store on top of
    /// it. Mirrors `RepositoryTests.migratedDatabase` so failures share the
    /// same shape and tests stay independent.
    private func freshStore() throws -> SQLiteMemoryStore {
        let database = try Database(path: ":memory:")
        return try SQLiteMemoryStore(database: database)
    }
}