import Foundation

/// Process-local generation used to invalidate prior exact-browser authorizations.
final class ExactBrowserSessionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = false
    private var generation: UInt64 = 0

    func setEnabled(_ value: Bool, onChange: () -> Void = {}) {
        lock.lock(); defer { lock.unlock() }
        if enabled != value { generation &+= 1; enabled = value; onChange() }
    }
    func capture() -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        return enabled ? generation : nil
    }
    func isValid(_ value: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return enabled && generation == value
    }
    /// A one-use attempt whose start is serialized with session closure.
    final class OpenAttempt: @unchecked Sendable {
        fileprivate let generation: UInt64
        fileprivate var started = false // Accessed only while the gate lock is held.
        fileprivate init(generation: UInt64) { self.generation = generation }
    }

    func pendingOpen(generation: UInt64) -> OpenAttempt { OpenAttempt(generation: generation) }

    func beginOpen(_ attempt: OpenAttempt) throws {
        try withCurrentGeneration(attempt.generation) {
            guard !attempt.started, !Task.isCancelled else { throw BrowserOpenError.unavailable }
            attempt.started = true
        }
    }

    func withCurrentGeneration<T>(_ value: UInt64, _ operation: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard enabled && generation == value else { throw BrowserOpenError.unavailable }
        return try operation()
    }
}
