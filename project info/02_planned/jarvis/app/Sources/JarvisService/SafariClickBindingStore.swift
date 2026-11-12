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
    private let beforeIssue: @Sendable () async -> Void
    private var lastTime: TimeInterval?
    private var entries: [UUID: Entry] = [:]
    init(lifetime: TimeInterval = 60, clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }, beforeIssue: @escaping @Sendable () async -> Void = {}) {
        self.lifetime = lifetime; self.clock = clock; self.beforeIssue = beforeIssue
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
    func consume(token: UUID, taskID: UUID, requestID: UUID, digest: String, targetDigest: String) -> Bool {
        guard let time = now(), let entry = entries.removeValue(forKey: token), time < entry.expires else { return false }
        return entry.snapshot.taskID == taskID && entry.requestID == requestID && entry.requestDigest == digest && entry.snapshot.targetDigest == targetDigest
    }
    func purgeExpired() -> [UUID] {
        guard let time = now() else { let ids = Array(entries.keys); entries.removeAll(); return ids }
        let ids = entries.filter { $0.value.expires <= time }.map(\.key)
        for id in ids { entries.removeValue(forKey: id) }
        return ids
    }
    func cancel(token: UUID) { entries.removeValue(forKey: token) }
    func cancel(taskID: UUID) { entries = entries.filter { $0.value.snapshot.taskID != taskID } }
}

#if os(macOS)
/// Experimental capture binding only; not connected to TaskService or AX actions.
actor SafariClickStagedCaptures {
    private let bindings: SafariClickBindingStore
    private let expiryDelay: Duration
    private var captures: [UUID: SafariClickCapture] = [:]
    private var inUse: Set<ObjectIdentifier> = []
    init(bindings: SafariClickBindingStore, expiryDelay: Duration = .seconds(60)) { self.bindings = bindings; self.expiryDelay = expiryDelay }
    func purgeExpired() async {
        let ids = await bindings.purgeExpired()
        for token in ids { await release(token: token) }
    }
    private func release(token: UUID) async {
        guard let capture = captures.removeValue(forKey: token) else { return }
        await capture.clear()
        inUse.remove(ObjectIdentifier(capture))
    }
    func stage(taskID: UUID, identity: SafariClickIdentity, targetDigest: String, capture: SafariClickCapture) async throws -> UUID? {
        await purgeExpired()
        try Task.checkCancellation()
        let key = ObjectIdentifier(capture)
        guard inUse.count < 32, inUse.insert(key).inserted else { return nil }
        var published = false
        var token: UUID?
        do {
            try await capture.capture(expected: identity)
            try Task.checkCancellation()
            token = await bindings.issue(.init(taskID: taskID, targetDigest: targetDigest))
            try Task.checkCancellation()
            guard let token else { await capture.clear(); inUse.remove(key); return nil }
            captures[token] = capture
            published = true
            let delay = expiryDelay
            Task { [weak self] in
                try? await Task.sleep(for: delay)
                await self?.cancel(token: token)
            }
            return token
        } catch {
            if let token { await bindings.cancel(token: token) }
            if !published { await capture.clear(); inUse.remove(key) }
            throw error
        }
    }
    func bind(token: UUID, taskID: UUID, requestID: UUID, digest: String) async -> Bool {
        guard captures[token] != nil else { return false }
        let success = await bindings.bind(token: token, taskID: taskID, requestID: requestID, digest: digest)
        guard success, captures[token] != nil, !Task.isCancelled else {
            await bindings.cancel(token: token)
            await release(token: token)
            return false
        }
        return true
    }
    func cancel(token: UUID) async {
        let capture = captures.removeValue(forKey: token)
        await bindings.cancel(token: token)
        if let capture {
            await capture.clear()
            inUse.remove(ObjectIdentifier(capture))
        }
    }
}
#endif
