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
    /// Nil means the token is absent, expired, or the clock is invalid.
    func remaining(token: UUID) -> TimeInterval? {
        guard let time = now(), let entry = entries[token], time < entry.expires else { return nil }
        return entry.expires - time
    }
    func cancel(token: UUID) { entries.removeValue(forKey: token) }
    func cancel(taskID: UUID) { entries = entries.filter { $0.value.snapshot.taskID != taskID } }
}

#if os(macOS)
/// Experimental capture binding only; not connected to TaskService or AX actions.
actor SafariClickStagedCaptures {
    private let bindings: SafariClickBindingStore
    private let sleep: @Sendable (Duration) async throws -> Void
    private var captures: [UUID: SafariClickCapture] = [:]
    private var inUse: Set<ObjectIdentifier> = []
    private var releasing: [UUID: (Task<Void, Never>, ObjectIdentifier)] = [:]
    init(bindings: SafariClickBindingStore, sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) { self.bindings = bindings; self.sleep = sleep }
    func purgeExpired() async {
        let ids = await bindings.purgeExpired()
        for token in ids { await release(token: token) }
        for token in Array(releasing.keys) { await release(token: token) }
    }
    private func beginRelease(token: UUID) -> (Task<Void, Never>, ObjectIdentifier)? {
        if let existing = releasing[token] { return existing }
        guard let capture = captures.removeValue(forKey: token) else { return nil }
        let item = (Task { await capture.clear() }, ObjectIdentifier(capture))
        releasing[token] = item
        return item
    }
    private func finishRelease(token: UUID, item: (Task<Void, Never>, ObjectIdentifier)?) async {
        guard let item else { return }
        await item.0.value
        if releasing.removeValue(forKey: token) != nil { inUse.remove(item.1) }
    }
    private func release(token: UUID) async {
        await finishRelease(token: token, item: beginRelease(token: token))
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
            Task { [weak self] in
                await self?.waitForExpiry(token: token)
            }
            return token
        } catch {
            if let token { await bindings.cancel(token: token) }
            if !published { await capture.clear(); inUse.remove(key) }
            throw error
        }
    }
    private func waitForExpiry(token: UUID) async {
        while captures[token] != nil {
            guard let remaining = await bindings.remaining(token: token) else {
                await cancel(token: token)
                return
            }
            do { try await sleep(.seconds(remaining)) }
            catch { await cancel(token: token); return }
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
        let item = beginRelease(token: token)
        await bindings.cancel(token: token)
        await finishRelease(token: token, item: item)
    }
}
#endif
