import Foundation

/// Captured metadata; a UUID here is an opaque identity supplied by a future
/// trusted capture mechanism, not proof of AX window or document identity.
struct SafariCapturedTarget: Equatable, Sendable {
    let url: String
    let processID: Int32
    let windowIdentity: UUID
}

enum SafariTargetGrantError: Error { case invalidTarget, duplicateToken }

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

    func insert(_ target: SafariCapturedTarget, token: UUID, taskID: UUID, requestID: UUID, requestDigest: String, now: TimeInterval = ProcessInfo.processInfo.systemUptime) throws -> UUID {
        guard target.processID > 0, !requestDigest.isEmpty, target.url.utf8.count <= 4096,
              target.url.unicodeScalars.allSatisfy({ $0.isASCII && !$0.properties.isWhitespace && !CharacterSet.controlCharacters.contains($0) }),
              let components = URLComponents(string: target.url), components.scheme == "https",
              components.user == nil, components.password == nil, components.fragment == nil,
              let host = components.host, !host.isEmpty,
              let url = components.url, url.absoluteString == target.url else { throw SafariTargetGrantError.invalidTarget }
        lock.lock(); defer { lock.unlock() }
        entries = entries.filter { $0.value.expires > now }
        guard entries[token] == nil else { throw SafariTargetGrantError.duplicateToken }
        if entries.count >= 32, let oldest = entries.min(by: { $0.value.expires < $1.value.expires })?.key { entries.removeValue(forKey: oldest) }
        entries[token] = Entry(target: target, taskID: taskID, requestID: requestID, requestDigest: requestDigest, expires: now + lifetime)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + lifetime) { [weak self] in self?.purge() }
        return token
    }

    func preview(token: UUID, taskID: UUID, requestID: UUID, requestDigest: String, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> SafariCapturedTarget? {
        lock.lock(); defer { lock.unlock() }
        entries = entries.filter { $0.value.expires > now }
        guard let entry = entries[token], entry.taskID == taskID, entry.requestID == requestID, entry.requestDigest == requestDigest else { return nil }
        return entry.target
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
