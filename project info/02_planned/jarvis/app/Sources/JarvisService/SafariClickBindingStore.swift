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
    private let clock: @Sendable () -> TimeInterval
    private let lifetime: TimeInterval
    private var lastTime: TimeInterval?
    private var entries: [UUID: Entry] = [:]
    init(lifetime: TimeInterval = 60, clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.lifetime = lifetime; self.clock = clock
    }
    private func now() -> TimeInterval? {
        let value = clock()
        guard value.isFinite, value >= 0, lastTime.map({ value >= $0 }) ?? true else { entries.removeAll(); return nil }
        lastTime = value
        return value
    }
    func issue(_ snapshot: Snapshot) -> UUID? {
        guard let time = now(), lifetime.isFinite, lifetime > 0, !snapshot.targetDigest.isEmpty else { return nil }
        entries = entries.filter { $0.value.expires > time }
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
    func consume(token: UUID, taskID: UUID, requestID: UUID, digest: String, targetDigest: String) -> Bool {
        guard let time = now(), let entry = entries.removeValue(forKey: token), time < entry.expires else { return false }
        return entry.snapshot.taskID == taskID && entry.requestID == requestID && entry.requestDigest == digest && entry.snapshot.targetDigest == targetDigest
    }
    func cancel(token: UUID) { entries.removeValue(forKey: token) }
    func cancel(taskID: UUID) { entries = entries.filter { $0.value.snapshot.taskID != taskID } }
}
