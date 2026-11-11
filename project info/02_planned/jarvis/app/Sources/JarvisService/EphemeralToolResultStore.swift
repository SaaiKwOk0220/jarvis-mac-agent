import Foundation

/// A bounded, in-memory, single-consumer result buffer. Never persists its contents.
final class EphemeralToolResultStore: @unchecked Sendable {
    private struct Entry {
        let taskID: UUID
        let digest: String
        let value: String
        let expires: Date
    }
    private let lock = NSLock()
    private let lifetime: TimeInterval
    private var entries: [UUID: Entry] = [:]

    init(lifetime: TimeInterval = 60) { self.lifetime = lifetime }

    func put(_ value: String, taskID: UUID, requestID: UUID, digest: String, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        entries = entries.filter { $0.value.expires > now }
        if entries.count >= 64, let oldest = entries.min(by: { $0.value.expires < $1.value.expires })?.key {
            entries.removeValue(forKey: oldest)
        }
        entries[requestID] = Entry(taskID: taskID, digest: digest, value: String(value.prefix(32_000)), expires: now.addingTimeInterval(lifetime))
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(0, lifetime)) { [weak self] in
            self?.purgeExpired(now: Date())
        }
    }

    private func purgeExpired(now: Date) {
        lock.lock(); defer { lock.unlock() }
        entries = entries.filter { $0.value.expires > now }
    }

    func take(taskID: UUID, requestID: UUID, digest: String, now: Date = Date()) -> String? {
        lock.lock(); defer { lock.unlock() }
        entries = entries.filter { $0.value.expires > now }
        guard let entry = entries[requestID], entry.taskID == taskID, entry.digest == digest else { return nil }
        entries.removeValue(forKey: requestID)
        return entry.value
    }

    func clear(taskID: UUID) {
        lock.lock(); defer { lock.unlock() }
        entries = entries.filter { $0.value.taskID != taskID }
    }
}
