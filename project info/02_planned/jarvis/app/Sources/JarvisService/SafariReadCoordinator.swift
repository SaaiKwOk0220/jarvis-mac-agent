import Foundation
import JarvisDomain
import JarvisPersistence

protocol SafariTargetCapturing: Sendable {
    func capture() async throws -> SafariCapturedTarget
    func verify(_ target: SafariCapturedTarget) async throws
    func read(_ target: SafariCapturedTarget) async throws -> String
}

enum SafariReadCoordinatorError: LocalizedError {
    case unavailable, invalidTarget
    var errorDescription: String? {
        switch self {
        case .unavailable: return "The captured Safari target expired or is unavailable; start the request again."
        case .invalidTarget: return "The captured Safari URL is not supported."
        }
    }
}

/// Builds a disk-safe pending request while retaining the exact captured URL and AX reference only in memory.
/// The caller must obtain explicit user approval before calling consume.
actor SafariReadCoordinator {
    private struct Captured {
        let capture: any SafariTargetCapturing
        let taskID: UUID
        let expires: TimeInterval
        let generation: UInt64?
    }
    private let store = SafariTargetGrantStore(lifetime: 60)
    private let gate: SafariReadGate?
    private let focusTimeout: Duration
    private let focusPollInterval: Duration
    private var captures: [UUID: Captured] = [:]

    init(focusTimeout: Duration = .seconds(15), focusPollInterval: Duration = .milliseconds(250), gate: SafariReadGate? = nil) {
        self.gate = gate
        self.focusTimeout = focusTimeout
        self.focusPollInterval = focusPollInterval
    }

    func prepare(taskID: UUID, capture: any SafariTargetCapturing) async throws -> ToolRequest {
        let generation = gate?.capture()
        if gate != nil && generation == nil { throw SafariReadCoordinatorError.unavailable }
        let deadline = ContinuousClock.now.advanced(by: focusTimeout)
        let target: SafariCapturedTarget
        while true {
            try Task.checkCancellation()
            do { target = try await capture.capture(); break }
            catch SafariAXReadError.notFocused {
                guard ContinuousClock.now < deadline else { throw SafariAXReadError.focusTimedOut }
                try await Task.sleep(for: focusPollInterval)
            }
        }
        try Task.checkCancellation()
        if let gate, let generation, !gate.isValid(generation) { throw SafariReadCoordinatorError.unavailable }
        guard let parts = URLComponents(string: target.url), parts.scheme == "https", let host = parts.host, !host.isEmpty else { throw SafariReadCoordinatorError.invalidTarget }
        var originParts = URLComponents()
        originParts.scheme = "https"
        originParts.host = host
        originParts.port = parts.port
        guard let origin = originParts.string else { throw SafariReadCoordinatorError.invalidTarget }
        purge()
        guard captures.count < 32 else { throw SafariReadCoordinatorError.unavailable }
        let token = UUID(), requestID = UUID()
        let request = ToolRequest(id: requestID, taskID: taskID, name: "safari_read", sideEffect: .read, target: origin, payload: token.uuidString)
        let register = {
            _ = try self.store.insert(target, token: token, taskID: taskID, requestID: requestID, requestDigest: request.payloadDigest)
            self.captures[token] = Captured(capture: capture, taskID: taskID, expires: ProcessInfo.processInfo.systemUptime + 60, generation: generation)
        }
        if let gate, let generation { try gate.withCurrentGeneration(generation, register) }
        else { try register() }
        Task { [weak self] in try? await Task.sleep(for: .seconds(60)); await self?.purge() }
        return request
    }

    func preview(_ request: ToolRequest) -> String? {
        purge()
        guard let token = UUID(uuidString: request.payload), let captured = captures[token] else { return nil }
        let lookup = { self.store.preview(token: token, taskID: request.taskID, requestID: request.id, requestDigest: request.payloadDigest)?.url }
        if let gate, let generation = captured.generation { return try? gate.withCurrentGeneration(generation, lookup) }
        return lookup()
    }

    /// Must be called only after the exact request has been approved by TaskService.
    struct GatedResult { let text: String; let generation: UInt64? }

    func readApproved(_ request: ToolRequest, approval: Approval) async throws -> String {
        try await readApprovedWithGeneration(request, approval: approval).text
    }

    func readApprovedWithGeneration(_ request: ToolRequest, approval: Approval) async throws -> GatedResult {
        guard approval.decision == .approved, approval.toolRequestID == request.id,
              approval.actionDigest == request.payloadDigest else { throw SafariReadCoordinatorError.unavailable }
        purge()
        guard let token = UUID(uuidString: request.payload), let captured = captures[token],
              let target = store.consume(token: token, taskID: request.taskID, requestID: request.id, requestDigest: request.payloadDigest) else { throw SafariReadCoordinatorError.unavailable }
        captures.removeValue(forKey: token)
        if let gate, let generation = captured.generation, !gate.isValid(generation) { throw SafariReadCoordinatorError.unavailable }
        let deadline = ContinuousClock.now.advanced(by: focusTimeout)
        while true {
            try Task.checkCancellation()
            do { try await captured.capture.verify(target); break }
            catch SafariAXReadError.notFocused {
                guard ContinuousClock.now < deadline else { throw SafariAXReadError.focusTimedOut }
                try await Task.sleep(for: focusPollInterval)
            }
        }
        if let gate, let generation = captured.generation, !gate.isValid(generation) { throw SafariReadCoordinatorError.unavailable }
        let result = try await captured.capture.read(target)
        try Task.checkCancellation()
        try await captured.capture.verify(target)
        if let gate, let generation = captured.generation, !gate.isValid(generation) { throw SafariReadCoordinatorError.unavailable }
        return GatedResult(text: result, generation: captured.generation)
    }

    func discard(_ request: ToolRequest) {
        guard let token = UUID(uuidString: request.payload),
              store.consume(token: token, taskID: request.taskID, requestID: request.id, requestDigest: request.payloadDigest) != nil else { return }
        captures.removeValue(forKey: token)
    }

    func clear(taskID: UUID) {
        store.clear(taskID: taskID)
        captures = captures.filter { $0.value.taskID != taskID }
    }

    private func purge() {
        let now = ProcessInfo.processInfo.systemUptime
        captures = captures.filter { $0.value.expires > now }
    }
}
