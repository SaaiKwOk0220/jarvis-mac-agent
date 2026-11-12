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
               timeout: TimeInterval, onTimeout: @escaping @Sendable () -> SafariPressFailure, onActionFailure: @escaping @Sendable () -> SafariPressFailure, beforeAction: @escaping @Sendable () -> Void,
               action: @escaping @Sendable (AXUIElement, CFString) -> AXError) async throws {
        guard let before = captured else { throw CaptureError.changed }
        try await verify(expected: expected)
        try Task.checkCancellation()
        guard let after = captured, after.identity == before.identity,
              after.launchDate == before.launchDate,
              CFEqual(after.window, before.window), CFEqual(after.element, before.element) else {
            throw CaptureError.changed
        }
        try await SafariAXPressAdapter.perform(after, timeout: timeout, onTimeout: onTimeout, onActionFailure: onActionFailure, beforeAction: beforeAction, action: action)
        captured = nil
    }
}
#endif

#if os(macOS)
/// CAS linearizes revocation and the start of AXPress. Once started,
/// cancellation returns immediately and cannot undo the action.
enum SafariClickCancellationResult { case revoked, alreadyStarted, idle }

fileprivate final class SafariClickRevocationGate: @unchecked Sendable {
    private let state = ManagedAtomic<Int>(1) // pending, started, revoked, completed
    func hasStarted() -> Bool { let current = state.load(ordering: .acquiring); return current == 2 || current == 4 }
    func finish() { _ = state.compareExchange(expected: 4, desired: 0, ordering: .acquiringAndReleasing) }
    func revoke() -> SafariClickCancellationResult {
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

/// A transferred reference remains revocable and subject to its original deadline.
actor SafariClickTransferredCapture {
    private let capture: SafariClickCapture
    private let bindings: SafariClickBindingStore
    private let deadline: TimeInterval
    private var valid = true
    private let gate: SafariClickRevocationGate
    fileprivate init(capture: SafariClickCapture, bindings: SafariClickBindingStore, deadline: TimeInterval, gate: SafariClickRevocationGate) {
        self.capture = capture; self.bindings = bindings; self.deadline = deadline; self.gate = gate
    }
    func invalidate() async { valid = false; _ = gate.revoke(); await capture.clear() }
    func verify(expected: SafariClickIdentity) async throws {
        let initialTimeValid = await bindings.isBefore(deadline)
        guard valid, !Task.isCancelled, initialTimeValid else { await invalidate(); throw SafariClickCapture.CaptureError.changed }
        try await capture.verify(expected: expected)
        let finalTimeValid = await bindings.isBefore(deadline)
        guard valid, !Task.isCancelled, finalTimeValid else { await invalidate(); throw SafariClickCapture.CaptureError.changed }
    }
    /// Experimental action path; only explicitly injected test actions are used.
    func perform(expected: SafariClickIdentity, timeout: TimeInterval = 3,
                 beforeAction: @escaping @Sendable () -> Void = {},
                 action: @escaping @Sendable (AXUIElement, CFString) -> AXError) async throws {
        let gate = self.gate, clock = bindings.clock, deadline = self.deadline
        do {
            try await verify(expected: expected)
            let time = await bindings.checkedTime(deadline: deadline)
            guard let baseline = time, valid, !Task.isCancelled else { throw SafariClickCapture.CaptureError.changed }
            valid = false
            try await capture.press(expected: expected, timeout: timeout,
                onTimeout: { gate.revoke() == .alreadyStarted ? .actionOutcomeUnknown : .timeoutBeforeStart },
                onActionFailure: { gate.hasStarted() ? .actionOutcomeUnknown : .beforeStartRejected },
                beforeAction: beforeAction) { element, operation in
                    gate.run {
                        let now = clock()
                        guard now.isFinite, now >= baseline, now < deadline else { return .failure }
                        return action(element, operation)
                    }
                }
            await capture.clear()
        } catch { _ = gate.revoke(); await capture.clear(); throw error }
    }
    /// Simulation only: no AX action is registered or performed by this path.
    func simulateOnce(expected: SafariClickIdentity, action: @Sendable () async -> Void) async throws {
        try await verify(expected: expected)
        guard valid, !Task.isCancelled else { throw SafariClickCapture.CaptureError.changed }
        valid = false
        await action()
        await capture.clear()
    }
}

/// Experimental capture binding only; not connected to TaskService or AX actions.
actor SafariClickStagedCaptures {
    private let bindings: SafariClickBindingStore
    private let sleep: @Sendable (Duration) async throws -> Void
    private var captures: [UUID: SafariClickCapture] = [:]
    private var gates: [UUID: SafariClickRevocationGate] = [:]
    private var inUse: Set<ObjectIdentifier> = []
    private var releasing: [UUID: (Task<Void, Never>, ObjectIdentifier)] = [:]
    private var consuming: Set<UUID> = []
    private var revoked: Set<UUID> = []
    private var transferred: [UUID: (SafariClickTransferredCapture, ObjectIdentifier)] = [:]
    init(bindings: SafariClickBindingStore, sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) { self.bindings = bindings; self.sleep = sleep }
    func purgeExpired() async {
        let ids = await bindings.purgeExpired()
        for token in ids { await cancel(token: token) }
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
            gates[token] = SafariClickRevocationGate()
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
                if consuming.contains(token) || transferred[token] != nil { return }
                await cancel(token: token)
                return
            }
            do { try await sleep(.seconds(remaining)) }
            catch { await cancel(token: token); return }
        }
    }
    func remaining(token: UUID) async -> TimeInterval? { await bindings.remaining(token: token) }
    func bind(token: UUID, taskID: UUID, requestID: UUID, digest: String) async -> Bool {
        guard captures[token] != nil else { return false }
        let success = await bindings.bind(token: token, taskID: taskID, requestID: requestID, digest: digest)
        guard success, captures[token] != nil, !Task.isCancelled else {
            _ = gates.removeValue(forKey: token)?.revoke()
            await bindings.cancel(token: token)
            await release(token: token)
            return false
        }
        return true
    }
    /// Transfers the captured reference only after a matching one-use binding.
    /// This bridge is experimental and does not perform or authorize an action.
    func consume(token: UUID, taskID: UUID, requestID: UUID, digest: String, targetDigest: String) async -> SafariClickTransferredCapture? {
        guard let capture = captures.removeValue(forKey: token), let gate = gates[token] else { return nil }
        consuming.insert(token)
        defer { consuming.remove(token); revoked.remove(token) }
        let deadline = await bindings.consumeWithDeadline(token: token, taskID: taskID, requestID: requestID, digest: digest, targetDigest: targetDigest)
        guard let deadline, !Task.isCancelled, !revoked.contains(token) else {
            _ = gate.revoke()
            gates.removeValue(forKey: token)
            await capture.clear()
            inUse.remove(ObjectIdentifier(capture))
            return nil
        }
        let transfer = SafariClickTransferredCapture(capture: capture, bindings: bindings, deadline: deadline, gate: gate)
        transferred[token] = (transfer, ObjectIdentifier(capture))
        Task { [weak self] in await self?.waitForTransferExpiry(token: token, deadline: deadline) }
        return transfer
    }
    private func waitForTransferExpiry(token: UUID, deadline: TimeInterval) async {
        while transferred[token] != nil {
            guard let remaining = await bindings.remaining(deadline: deadline) else { await cancel(token: token); return }
            do { try await sleep(.seconds(remaining)) } catch { await cancel(token: token); return }
        }
    }
    @discardableResult func cancel(token: UUID) async -> SafariClickCancellationResult {
        let result = gates.removeValue(forKey: token)?.revoke() ?? .idle
        if consuming.contains(token) { revoked.insert(token) }
        let transfer = transferred.removeValue(forKey: token)
        let item = beginRelease(token: token)
        await bindings.cancel(token: token)
        if let transfer { await transfer.0.invalidate(); inUse.remove(transfer.1) }
        await finishRelease(token: token, item: item)
        return result
    }
}

/// Testable approval coordinator. Not wired to any production tool or AX action.
actor SafariClickApprovalPrototype {
    enum Failure: Error { case disabled, invalid, expired, changed }
    private struct Pending { let requestID: UUID; let identity: SafariClickIdentity; let expires: TimeInterval; let generation: UInt64; let gate: SafariClickRevocationGate }
    private var pending: [UUID: Pending] = [:]
    private var generation: UInt64 = 0
    private var preparing = false
    private var executing = false
    private var cleaning = 0
    private let enabled: Bool
    private let capture: SafariClickCapture
    private let action: @Sendable (AXUIElement, CFString) -> AXError
    private var activeGate: SafariClickRevocationGate?
    private let clock: @Sendable () -> TimeInterval
    private let actionTimeout: TimeInterval
    private let beforeAction: @Sendable () -> Void
    private var lastReading: TimeInterval?
    private func readClock() throws -> TimeInterval {
        let value = clock()
        guard value.isFinite, value >= 0, lastReading.map({ value >= $0 }) ?? true else { throw Failure.invalid }
        lastReading = value
        return value
    }
    init(enabled: Bool = false, capture: SafariClickCapture, clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }, actionTimeout: TimeInterval = 3, beforeAction: @escaping @Sendable () -> Void = {}, action: @escaping @Sendable (AXUIElement, CFString) -> AXError) {
        self.enabled = enabled; self.capture = capture; self.clock = clock; self.actionTimeout = actionTimeout; self.beforeAction = beforeAction; self.action = action
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
            let gate = SafariClickRevocationGate()
            activeGate = gate
            pending[token] = Pending(requestID: requestID, identity: identity, expires: expires, generation: current, gate: gate)
            return token
        } catch {
            await capture.clear()
            throw error
        }
    }
    enum CancellationResult { case revoked, alreadyStarted, idle }
    @discardableResult func cancel() async -> CancellationResult {
        generation &+= 1; pending.removeAll()
        let result = activeGate?.revoke() ?? .idle
        if result == .alreadyStarted { return .alreadyStarted }
        cleaning += 1
        defer { cleaning -= 1 }
        await capture.clear()
        return result == .revoked ? .revoked : .idle
    }
    func reject(token: UUID) async {
        if let removed = pending.removeValue(forKey: token) {
            _ = removed.gate.revoke()
            cleaning += 1
            defer { cleaning -= 1 }
            await capture.clear()
        }
    }
    func approve(token: UUID, requestID: UUID, digest: String) async throws {
        guard let entry = pending.removeValue(forKey: token) else { throw Failure.invalid }
        guard entry.requestID == requestID, entry.identity.requestDigest == digest,
              entry.generation == generation else {
            _ = entry.gate.revoke()
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
            let revocation = entry.gate
            // The AX check and action are not atomic; cancellation cannot undo a started press.
            try await capture.press(expected: entry.identity, timeout: actionTimeout, onTimeout: { revocation.revoke() == .alreadyStarted ? .actionOutcomeUnknown : .timeoutBeforeStart }, onActionFailure: { revocation.hasStarted() ? .actionOutcomeUnknown : .beforeStartRejected }, beforeAction: beforeAction) { element, operation in
                let now = clock()
                guard now.isFinite, now >= beforePress, now < entry.expires,
                      !Task.isCancelled else { return .failure }
                return revocation.run { action(element, operation) }
            }
            await capture.clear()
            entry.gate.finish()
        } catch {
            _ = entry.gate.revoke()
            await capture.clear()
            entry.gate.finish()
            throw error
        }
    }
}
#endif

#if os(macOS)
/// Unregistered adapter. The caller must immediately revalidate capture before
/// invoking it; AXPress is not atomic with validation and cannot be undone.
/// A timed-out started operation may still finish; callers must not retry automatically.
enum SafariPressFailure: LocalizedError {
    case timeoutBeforeStart, beforeStartRejected, actionOutcomeUnknown
    var errorDescription: String? {
        switch self {
        case .timeoutBeforeStart: return "操作超时且尚未开始；请重新确认后再请求。"
        case .beforeStartRejected: return "操作未开始；目标或授权已失效。"
        case .actionOutcomeUnknown: return "操作已开始，但结果未知。请先检查页面；不要自动重试。"
        }
    }
}

private final class SafariPressCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    init(_ continuation: CheckedContinuation<Void, Error>) { self.continuation = continuation }
    func complete(_ result: Result<Void, Error>) {
        lock.lock(); let value = continuation; continuation = nil; lock.unlock()
        value?.resume(with: result)
    }
    func timeout(_ revoke: () -> SafariPressFailure) {
        lock.lock()
        guard let value = continuation else { lock.unlock(); return }
        continuation = nil
        let failure = revoke()
        lock.unlock()
        value.resume(throwing: failure)
    }
}

private enum SafariAXPressAdapter {
    private static let busy = ManagedAtomic(false)
    private static let worker = DispatchQueue(label: "jarvis.safari.axpress", qos: .userInitiated)
    static func perform(_ candidate: SafariClickCandidate, timeout: TimeInterval,
                        onTimeout: @escaping @Sendable () -> SafariPressFailure, onActionFailure: @escaping @Sendable () -> SafariPressFailure, beforeAction: @escaping @Sendable () -> Void,
                        action: @escaping @Sendable (AXUIElement, CFString) -> AXError) async throws {
        guard candidate.identity.enabled, timeout.isFinite, timeout > 0 else { throw SafariAXReadError.unavailable }
        try Task.checkCancellation()
        guard busy.compareExchange(expected: false, desired: true, ordering: .acquiringAndReleasing).exchanged else { throw SafariAXReadError.unavailable }
        try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let completion = SafariPressCompletion(continuation)
            worker.async {
                defer { busy.store(false, ordering: .releasing) }
                beforeAction()
                let result = action(candidate.element, kAXPressAction as CFString)
                completion.complete(result == .success ? .success(()) : .failure(onActionFailure()))
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
                completion.timeout(onTimeout)
            }
        }
        } onCancel: { _ = onTimeout() }
    }
}
#endif
