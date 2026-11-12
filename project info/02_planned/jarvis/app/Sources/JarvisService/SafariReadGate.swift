import Foundation

/// Process-local revocable generation for experimental Safari reads.
final class SafariReadGate: @unchecked Sendable {
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
    func withCurrentGeneration<T>(_ value: UInt64, _ operation: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard enabled && generation == value else { throw SafariReadCoordinatorError.unavailable }
        return try operation()
    }
}
