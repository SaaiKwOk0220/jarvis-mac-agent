import Foundation

/// A single remembered fact about the user, surfaced to the agent loop at the
/// start of every Ask Jarvis run so the model can act on identity, preference,
/// and environmental knowledge without re-asking.
///
/// The store behind `Memory` is intentionally flat: `category + key` is the
/// composite identity (an upsert key), and `value` is the free-form text the
/// model reads. No nested structure, no per-entry timestamps in the prompt —
/// the wire format is what reaches the LLM, so the type deliberately mirrors
/// the prompt lines the loop emits.
public struct MemoryEntry: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let category: String
    public let key: String
    public let value: String
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: UUID = UUID(),
        category: String,
        key: String,
        value: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.category = category
        self.key = key
        self.value = value
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Key-value store of user-known facts the agent loop can read as a second
/// system prompt. Categories are conventional strings (`identity`,
/// `preference`, `fact`) rather than an enum so callers can add new ones
/// without a schema migration; the UI surfaces the three conventional ones.
public protocol Memory: Sendable {
    /// Returns every entry, optionally filtered to a single category. The
    /// store orders by insertion order so repeated reads are deterministic.
    func list(category: String?) async throws -> [MemoryEntry]

    /// Creates or updates the entry identified by `(category, key)`. On an
    /// update the original `createdAt` is preserved and `updatedAt` is bumped.
    func set(category: String, key: String, value: String) async throws

    /// Removes the entry by its UUID. Removing a non-existent id is a no-op.
    func delete(id: UUID) async throws

    /// Renders the entire store as text the loop prepends to its system
    /// messages. An empty store yields an empty string so the loop can
    /// suppress the second system prompt cleanly.
    func formatContext() async throws -> String
}