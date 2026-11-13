import Foundation

/// In-memory two-phase bindings. This does not authorize an AX action by itself.
actor SafariClickBindingStore {
    struct Snapshot: Equatable, Sendable {
        let taskID: UUID
        let targetDigest: String
    }
    private struct Entry {
        let snapshot: Snapshot
        let expires: TimeInterval
        var requestID: UUID?
        var requestDigest: String?
    }
    nonisolated let clock: @Sendable () -> TimeInterval
    private let lifetime: TimeInterval
    private let beforeIssue: @Sendable () async -> Void
    private let beforeConsume: @Sendable () async -> Void
    private let beforeDeadlineCheck: @Sendable () async -> Void
    private var lastTime: TimeInterval?
    private var entries: [UUID: Entry] = [:]
    init(lifetime: TimeInterval = 60, clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }, beforeIssue: @escaping @Sendable () async -> Void = {}, beforeConsume: @escaping @Sendable () async -> Void = {}, beforeDeadlineCheck: @escaping @Sendable () async -> Void = {}) {
        self.lifetime = lifetime; self.clock = clock; self.beforeIssue = beforeIssue; self.beforeConsume = beforeConsume; self.beforeDeadlineCheck = beforeDeadlineCheck
    }
    private func now() -> TimeInterval? {
        let value = clock()
        guard value.isFinite, value >= 0, lastTime.map({ value >= $0 }) ?? true else { return nil }
        lastTime = value
        return value
    }
    func issue(_ snapshot: Snapshot) async -> UUID? {
        await beforeIssue()
        guard let time = now(), lifetime.isFinite, lifetime > 0, !snapshot.targetDigest.isEmpty else { return nil }
        guard entries.count < 32, (time + lifetime).isFinite else { return nil }
        let token = UUID()
        entries[token] = Entry(snapshot: snapshot, expires: time + lifetime)
        return token
    }
    func bind(token: UUID, taskID: UUID, requestID: UUID, digest: String) -> Bool {
        guard let time = now(), var entry = entries[token], time < entry.expires,
              entry.snapshot.taskID == taskID, entry.requestID == nil, !digest.isEmpty else { entries.removeValue(forKey: token); return false }
        entry.requestID = requestID; entry.requestDigest = digest; entries[token] = entry
        return true
    }
    func consume(token: UUID, taskID: UUID, requestID: UUID, digest: String, targetDigest: String) async -> Bool {
        await consumeWithDeadline(token: token, taskID: taskID, requestID: requestID, digest: digest, targetDigest: targetDigest) != nil
    }
    func consumeWithDeadline(token: UUID, taskID: UUID, requestID: UUID, digest: String, targetDigest: String) async -> TimeInterval? {
        await beforeConsume()
        guard let time = now(), let entry = entries.removeValue(forKey: token), time < entry.expires else { return nil }
        guard entry.snapshot.taskID == taskID && entry.requestID == requestID && entry.requestDigest == digest && entry.snapshot.targetDigest == targetDigest else { return nil }
        return entry.expires
    }
    func isBefore(_ deadline: TimeInterval) async -> Bool { await beforeDeadlineCheck(); guard let time = now() else { return false }; return time < deadline }
    func checkedTime(deadline: TimeInterval) -> TimeInterval? { guard let time = now(), time < deadline else { return nil }; return time }
    func remaining(deadline: TimeInterval) -> TimeInterval? { guard let time = now(), time < deadline else { return nil }; return deadline - time }
    func purgeExpired() -> [UUID] {
        guard let time = now() else { let ids = Array(entries.keys); entries.removeAll(); return ids }
        let ids = entries.filter { $0.value.expires <= time }.map(\.key)
        for id in ids { entries.removeValue(forKey: id) }
        return ids
    }
    /// Nil means the token is absent, expired, or the clock is invalid.
    func remaining(token: UUID) -> TimeInterval? {
        guard let time = now(), let entry = entries[token], time < entry.expires else { return nil }
        return entry.expires - time
    }
    func cancel(token: UUID) { entries.removeValue(forKey: token) }
    func cancel(taskID: UUID) { entries = entries.filter { $0.value.snapshot.taskID != taskID } }
}
