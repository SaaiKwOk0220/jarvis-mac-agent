import Foundation

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
               action: (AXUIElement, CFString) -> AXError = AXUIElementPerformAction) async throws {
        guard let before = captured else { throw CaptureError.changed }
        try await verify(expected: expected)
        try Task.checkCancellation()
        guard let after = captured, after.identity == before.identity,
              after.launchDate == before.launchDate,
              CFEqual(after.window, before.window), CFEqual(after.element, before.element) else {
            throw CaptureError.changed
        }
        try SafariAXPressAdapter.perform(after, action: action)
        captured = nil
    }
}
#endif

#if os(macOS)
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
    private let clock: @Sendable () -> TimeInterval
    private var lastReading: TimeInterval?
    private func readClock() throws -> TimeInterval {
        let value = clock()
        guard value.isFinite, value >= 0, lastReading.map({ value >= $0 }) ?? true else { throw Failure.invalid }
        lastReading = value
        return value
    }
    init(enabled: Bool = false, capture: SafariClickCapture, clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }, action: @escaping @Sendable (AXUIElement, CFString) -> AXError) {
        self.enabled = enabled; self.capture = capture; self.clock = clock; self.action = action
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
            pending[token] = Pending(requestID: requestID, identity: identity, expires: expires, generation: current)
            return token
        } catch {
            await capture.clear()
            throw error
        }
    }
    func cancel() async {
        generation &+= 1; pending.removeAll(); cleaning += 1
        defer { cleaning -= 1 }
        await capture.clear()
    }
    func reject(token: UUID) async {
        if pending.removeValue(forKey: token) != nil {
            cleaning += 1
            defer { cleaning -= 1 }
            await capture.clear()
        }
    }
    func approve(token: UUID, requestID: UUID, digest: String) async throws {
        guard let entry = pending.removeValue(forKey: token) else { throw Failure.invalid }
        guard entry.requestID == requestID, entry.identity.requestDigest == digest,
              entry.generation == generation else {
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
            // The AX check and action are not atomic; cancellation cannot undo a started press.
            try await capture.press(expected: entry.identity) { element, operation in
                let now = clock()
                guard now.isFinite, now >= beforePress, now < entry.expires,
                      !Task.isCancelled else { return .failure }
                return action(element, operation)
            }
            await capture.clear()
        } catch {
            await capture.clear()
            throw error
        }
    }
}
#endif

#if os(macOS)
/// Unregistered adapter. The caller must immediately revalidate capture before
/// invoking it; AXPress is not atomic with validation and cannot be undone.
private enum SafariAXPressAdapter {
    static func perform(_ candidate: SafariClickCandidate,
                        action: (AXUIElement, CFString) -> AXError = AXUIElementPerformAction) throws {
        guard candidate.identity.enabled else { throw SafariAXReadError.targetChanged }
        try Task.checkCancellation()
        guard action(candidate.element, kAXPressAction as CFString) == .success else {
            throw SafariAXReadError.unavailable
        }
    }
}
#endif
