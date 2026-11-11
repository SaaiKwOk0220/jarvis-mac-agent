import Foundation

/// Captured metadata; a UUID here is an opaque identity supplied by a future
/// trusted capture mechanism, not proof of AX window or document identity.
struct SafariCapturedTarget: Equatable, Sendable {
    let url: String
    let processID: Int32
    let windowIdentity: UUID
}

/// In-memory, scoped, single-use storage for a potential future approval flow.
/// Not an authorization decision and not wired to the disabled Safari tool.
final class SafariTargetGrantStore: @unchecked Sendable {
    private struct Entry {
        let target: SafariCapturedTarget
        let taskID: UUID
        let requestID: UUID
        let requestDigest: String
        let expires: TimeInterval
    }
    private let lock = NSLock()
    private let lifetime: TimeInterval
    private var entries: [UUID: Entry] = [:]
    init(lifetime: TimeInterval = 60) { self.lifetime = max(0, lifetime) }

    func insert(_ target: SafariCapturedTarget, token: UUID, taskID: UUID, requestID: UUID, requestDigest: String, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> UUID {
        lock.lock(); defer { lock.unlock() }
        entries = entries.filter { $0.value.expires > now }
        if entries.count >= 32, let oldest = entries.min(by: { $0.value.expires < $1.value.expires })?.key { entries.removeValue(forKey: oldest) }
        entries[token] = Entry(target: target, taskID: taskID, requestID: requestID, requestDigest: requestDigest, expires: now + lifetime)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + lifetime) { [weak self] in self?.purge() }
        return token
    }

    func consume(token: UUID, taskID: UUID, requestID: UUID, requestDigest: String, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> SafariCapturedTarget? {
        lock.lock(); defer { lock.unlock() }
        entries = entries.filter { $0.value.expires > now }
        guard let entry = entries[token], entry.taskID == taskID, entry.requestID == requestID, entry.requestDigest == requestDigest else { return nil }
        entries.removeValue(forKey: token)
        return entry.target
    }

    func clear(taskID: UUID) {
        lock.lock(); defer { lock.unlock() }
        entries = entries.filter { $0.value.taskID != taskID }
    }

    private func purge() {
        lock.lock(); defer { lock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        entries = entries.filter { $0.value.expires > now }
    }
}
