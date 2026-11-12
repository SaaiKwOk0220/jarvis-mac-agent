import Foundation
import Atomics

/// Identifying metadata for a future captured AX element; not itself an AX identity.
struct SafariClickIdentity: Equatable, Sendable {
    var pid: Int32
    var window: String
    var url: String
    var role: String
    var title: String
    var enabled: Bool
    var requestDigest: String
}

/// Preliminary in-memory authorization primitive; it does not perform AX actions.
actor SafariClickTicketStore {
    private var entries: [UUID: (SafariClickIdentity, TimeInterval)] = [:]
    func issue(identity: SafariClickIdentity, now: TimeInterval) -> UUID {
        let token = UUID()
        entries[token] = (identity, now + 60)
        return token
    }
    func consume(token: UUID, current: SafariClickIdentity, now: TimeInterval) -> Bool {
        guard let (original, expires) = entries.removeValue(forKey: token) else { return false }
        return now < expires && original == current && current.enabled
    }
}

#if os(macOS)
import ApplicationServices

/// Holds actual AX references in memory. The provider must inspect the focused
/// Safari window and return only candidates belonging to its current web area.
struct SafariClickCandidate: @unchecked Sendable {
    let element: AXUIElement
    let window: AXUIElement
    let launchDate: Date
    let identity: SafariClickIdentity
}

actor SafariClickCapture {
    enum CaptureError: Error { case ambiguousOrMissing, changed }
    typealias Provider = @Sendable () async throws -> [SafariClickCandidate]
    private let provider: Provider
    private let beforeClear: @Sendable () async -> Void
    private var captured: SafariClickCandidate?

    init(beforeClear: @escaping @Sendable () async -> Void = {}, provider: @escaping Provider) { self.beforeClear = beforeClear; self.provider = provider }

    func clear() async { await beforeClear(); captured = nil }

    func capture(expected: SafariClickIdentity) async throws {
        let matches = try await provider().filter { $0.identity == expected && $0.identity.enabled }
        guard matches.count == 1 else { throw CaptureError.ambiguousOrMissing }
        captured = matches[0]
    }

    /// Re-observes both metadata and the retained AX identity. No action is performed.
    func verify(expected: SafariClickIdentity) async throws {
        guard let original = captured, original.identity == expected else { throw CaptureError.changed }
        let matches = try await provider().filter { $0.identity == expected && $0.identity.enabled }
        guard matches.count == 1, original.launchDate == matches[0].launchDate,
              CFEqual(original.window, matches[0].window),
              CFEqual(original.element, matches[0].element) else {
            captured = nil
            throw CaptureError.changed
        }
    }

    /// Revalidation and AXPress remain non-atomic with respect to Safari.
    fileprivate func press(expected: SafariClickIdentity,
               timeout: TimeInterval, onTimeout: @escaping @Sendable () -> Void,
               action: @escaping @Sendable (AXUIElement, CFString) -> AXError) async throws {
        guard let before = captured else { throw CaptureError.changed }
        try await verify(expected: expected)
        try Task.checkCancellation()
        guard let after = captured, after.identity == before.identity,
              after.launchDate == before.launchDate,
              CFEqual(after.window, before.window), CFEqual(after.element, before.element) else {
            throw CaptureError.changed
        }
        try await SafariAXPressAdapter.perform(after, timeout: timeout, onTimeout: onTimeout, action: action)
        captured = nil
    }
}
#endif

#if os(macOS)
/// CAS linearizes revocation and the start of AXPress. Once started,
/// cancellation returns immediately and cannot undo the action.
private final class SafariClickRevocationGate: @unchecked Sendable {
    enum Result { case revoked, alreadyStarted, idle }
    private let state = ManagedAtomic<Int>(0) // idle, pending, started, revoked, completed
    func activate() { state.store(1, ordering: .releasing) }
    func finish() { _ = state.compareExchange(expected: 4, desired: 0, ordering: .acquiringAndReleasing) }
    func revoke() -> Result {
        if state.compareExchange(expected: 1, desired: 3, ordering: .acquiringAndReleasing).exchanged { return .revoked }
        let current = state.load(ordering: .acquiring)
        return current == 2 || current == 4 ? .alreadyStarted : .idle
    }
    func run(_ action: () -> AXError) -> AXError {
        guard state.compareExchange(expected: 1, desired: 2, ordering: .acquiringAndReleasing).exchanged else { return .failure }
        defer { _ = state.compareExchange(expected: 2, desired: 4, ordering: .acquiringAndReleasing) }
        return action()
    }
}

/// Testable approval coordinator. Not wired to any production tool or AX action.
actor SafariClickApprovalPrototype {
    enum Failure: Error { case disabled, invalid, expired, changed }
    private struct Pending { let requestID: UUID; let identity: SafariClickIdentity; let expires: TimeInterval; let generation: UInt64 }
    private var pending: [UUID: Pending] = [:]
    private var generation: UInt64 = 0
    private var preparing = false
    private var executing = false
    private var cleaning = 0
    private let enabled: Bool
    private let capture: SafariClickCapture
    private let action: @Sendable (AXUIElement, CFString) -> AXError
    private let revocation = SafariClickRevocationGate()
    private let clock: @Sendable () -> TimeInterval
    private let actionTimeout: TimeInterval
    private var lastReading: TimeInterval?
    private func readClock() throws -> TimeInterval {
        let value = clock()
        guard value.isFinite, value >= 0, lastReading.map({ value >= $0 }) ?? true else { throw Failure.invalid }
        lastReading = value
        return value
    }
    init(enabled: Bool = false, capture: SafariClickCapture, clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }, actionTimeout: TimeInterval = 3, action: @escaping @Sendable (AXUIElement, CFString) -> AXError) {
        self.enabled = enabled; self.capture = capture; self.clock = clock; self.actionTimeout = actionTimeout; self.action = action
    }
    func prepare(requestID: UUID, identity: SafariClickIdentity) async throws -> UUID {
        guard enabled else { throw Failure.disabled }
        guard pending.isEmpty && !preparing && !executing && cleaning == 0 else { throw Failure.invalid }
        preparing = true
        defer { preparing = false }
        let current = generation
        try Task.checkCancellation()
        try await capture.capture(expected: identity)
        do {
            try Task.checkCancellation()
            guard current == generation else { throw Failure.invalid }
            let expires = try readClock() + 60
            let token = UUID()
            revocation.activate()
            pending[token] = Pending(requestID: requestID, identity: identity, expires: expires, generation: current)
            return token
        } catch {
            await capture.clear()
            throw error
        }
    }
    enum CancellationResult { case revoked, alreadyStarted, idle }
    @discardableResult func cancel() async -> CancellationResult {
        generation &+= 1; pending.removeAll()
        let result = revocation.revoke()
        if result == .alreadyStarted { return .alreadyStarted }
        cleaning += 1
        defer { cleaning -= 1 }
        await capture.clear()
        return result == .revoked ? .revoked : .idle
    }
    func reject(token: UUID) async {
        if pending.removeValue(forKey: token) != nil {
            _ = revocation.revoke()
            cleaning += 1
            defer { cleaning -= 1 }
            await capture.clear()
        }
    }
    func approve(token: UUID, requestID: UUID, digest: String) async throws {
        guard let entry = pending.removeValue(forKey: token) else { throw Failure.invalid }
        guard entry.requestID == requestID, entry.identity.requestDigest == digest,
              entry.generation == generation else {
            _ = revocation.revoke()
            cleaning += 1
            defer { cleaning -= 1 }
            await capture.clear()
            throw Failure.invalid
        }
        guard !executing else { throw Failure.invalid }
        executing = true
        defer { executing = false }
        do {
            guard try readClock() < entry.expires else { throw Failure.expired }
            try await capture.verify(expected: entry.identity)
            guard entry.generation == generation else { throw Failure.invalid }
            try Task.checkCancellation()
            let beforePress = try readClock()
            guard beforePress < entry.expires else { throw Failure.expired }
            let clock = self.clock
            let action = self.action
            let revocation = self.revocation
            // The AX check and action are not atomic; cancellation cannot undo a started press.
            try await capture.press(expected: entry.identity, timeout: actionTimeout, onTimeout: { _ = revocation.revoke() }) { element, operation in
                let now = clock()
                guard now.isFinite, now >= beforePress, now < entry.expires,
                      !Task.isCancelled else { return .failure }
                return revocation.run { action(element, operation) }
            }
            await capture.clear()
            revocation.finish()
        } catch {
            _ = revocation.revoke()
            await capture.clear()
            revocation.finish()
            throw error
        }
    }
}
#endif

#if os(macOS)
/// Unregistered adapter. The caller must immediately revalidate capture before
/// invoking it; AXPress is not atomic with validation and cannot be undone.
private final class SafariPressCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    init(_ continuation: CheckedContinuation<Void, Error>) { self.continuation = continuation }
    func complete(_ result: Result<Void, Error>) {
        lock.lock(); let value = continuation; continuation = nil; lock.unlock()
        value?.resume(with: result)
    }
    func timeout(_ revoke: () -> Void) {
        lock.lock()
        guard let value = continuation else { lock.unlock(); return }
        continuation = nil
        revoke()
        lock.unlock()
        value.resume(throwing: SafariAXReadError.limitExceeded)
    }
}

private enum SafariAXPressAdapter {
    private static let busy = ManagedAtomic(false)
    private static let worker = DispatchQueue(label: "jarvis.safari.axpress", qos: .userInitiated)
    static func perform(_ candidate: SafariClickCandidate, timeout: TimeInterval,
                        onTimeout: @escaping @Sendable () -> Void,
                        action: @escaping @Sendable (AXUIElement, CFString) -> AXError) async throws {
        guard candidate.identity.enabled, timeout.isFinite, timeout > 0 else { throw SafariAXReadError.unavailable }
        try Task.checkCancellation()
        guard busy.compareExchange(expected: false, desired: true, ordering: .acquiringAndReleasing).exchanged else { throw SafariAXReadError.unavailable }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let completion = SafariPressCompletion(continuation)
            worker.async {
                defer { busy.store(false, ordering: .releasing) }
                let result = action(candidate.element, kAXPressAction as CFString)
                completion.complete(result == .success ? .success(()) : .failure(SafariAXReadError.unavailable))
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
                completion.timeout(onTimeout)
            }
        }
    }
}
#endif
