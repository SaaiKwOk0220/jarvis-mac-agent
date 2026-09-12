import Foundation
import JarvisDomain
import JarvisPersistence
import JarvisPolicy

public struct ToolResult: Codable, Equatable, Sendable {
    public let summary: String

    public init(summary: String) {
        self.summary = summary
    }
}

public protocol ToolExecutor: Sendable {
    func execute(_ request: ToolRequest) async throws -> ToolResult
}

/// Foundation executor. It deliberately performs no system or network action.
public struct NoOpToolExecutor: ToolExecutor {
    public init() {}

    public func execute(_ request: ToolRequest) async throws -> ToolResult {
        ToolResult(summary: "demo executor completed")
    }
}

public enum TaskServiceError: Error, Equatable, Sendable {
    case taskNotFound
    case requestNotFound
    case requestNotAwaitingApproval
    case approvalDigestMismatch
    case illegalTransition(from: TaskStatus, to: TaskStatus)
}

/// Coordinates persisted task state, policy gates, immutable pending requests, and redacted auditing.
public final class TaskService: TaskServiceAPI, @unchecked Sendable {
    private let taskRepository: any TaskRepository
    private let auditRepository: any AuditRepository
    private let policy: any PolicyEvaluator
    private let policyConfig: PolicyConfig
    private let executor: any ToolExecutor
    private let lock = NSLock()
    private var pendingRequests: [UUID: ToolRequest] = [:]

    public init(
        taskRepository: any TaskRepository,
        auditRepository: any AuditRepository,
        policy: any PolicyEvaluator,
        policyConfig: PolicyConfig = PolicyConfig(),
        executor: any ToolExecutor = NoOpToolExecutor()
    ) {
        self.taskRepository = taskRepository
        self.auditRepository = auditRepository
        self.policy = policy
        self.policyConfig = policyConfig
        self.executor = executor
    }

    public func createTask(title: String) async throws -> Task {
        try lock.withLock {
            let task = Task(title: title)
            try taskRepository.insert(task)
            try audit(taskID: task.id, sideEffect: .read, digest: "", summary: "task created", result: "created")
            return task
        }
    }

    public func getTask(id: UUID) async throws -> Task? {
        try lock.withLock { try taskRepository.fetch(id: id) }
    }

    public func listTasks() async throws -> [Task] {
        try lock.withLock { try taskRepository.list() }
    }

    /// Records a request before evaluating it; only explicitly approved protected requests are executed.
    public func submit(request: ToolRequest) async throws -> PolicyDecision {
        try moveTaskToRunningIfNeeded(taskID: request.taskID)
        try lock.withLock {
            guard try taskRepository.fetch(id: request.taskID) != nil else {
                throw TaskServiceError.taskNotFound
            }
            try auditRequest(request, summary: "tool request received", result: "received")
        }

        let decision = policy.evaluate(request, config: policyConfig)
        switch decision {
        case .allow:
            try lock.withLock {
                try auditRequest(request, summary: "policy allowed", result: "allowed")
            }
            try await executeAllowedRequest(request)
        case let .requireApproval(reason):
            try lock.withLock {
                // The complete request, including its ToolScope-bound digest, is immutable while pending.
                pendingRequests[request.id] = request
                try auditRequest(request, summary: "policy requires approval", result: reason)
            }
            try transition(taskID: request.taskID, to: .awaitingApproval)
        case let .deny(reason):
            try lock.withLock {
                try auditRequest(request, summary: "policy denied", result: reason)
            }
            try transition(taskID: request.taskID, to: .blocked)
        }
        return decision
    }

    public func approve(requestID: UUID, digest: String) async throws {
        let request = try lock.withLock { () throws -> ToolRequest in
            guard let request = pendingRequests[requestID] else { throw TaskServiceError.requestNotFound }
            guard validateApproval(request: request, approvalDigest: digest) else {
                try auditRequest(request, summary: "approval rejected", result: "digest mismatch")
                throw TaskServiceError.approvalDigestMismatch
            }
            pendingRequests.removeValue(forKey: requestID)
            return request
        }

        let approvalID = UUID()
        try lock.withLock {
            try audit(
                taskID: request.taskID,
                sideEffect: request.sideEffect,
                digest: request.payloadDigest,
                summary: "approval accepted",
                result: "approved",
                approvalID: approvalID,
                target: request.target
            )
        }
        try transition(taskID: request.taskID, to: .running)
        try await executeAllowedRequest(request, approvalID: approvalID)
    }

    public func reject(requestID: UUID) async throws {
        let request = try lock.withLock { () throws -> ToolRequest in
            guard let request = pendingRequests.removeValue(forKey: requestID) else {
                throw TaskServiceError.requestNotFound
            }
            return request
        }
        try lock.withLock {
            try auditRequest(request, summary: "approval rejected", result: "rejected")
        }
        try transition(taskID: request.taskID, to: .blocked)
    }

    public func cancel(taskID: UUID) async throws {
        lock.withLock {
            pendingRequests = pendingRequests.filter { $0.value.taskID != taskID }
        }
        try transition(taskID: taskID, to: .cancelled)
        try lock.withLock {
            try audit(taskID: taskID, sideEffect: .read, digest: "", summary: "task cancelled", result: "cancelled")
        }
    }

    public func transition(taskID: UUID, to status: TaskStatus) throws {
        try lock.withLock {
            guard let task = try taskRepository.fetch(id: taskID) else { throw TaskServiceError.taskNotFound }
            do {
                try TaskStateMachine.validate(from: task.status, to: status)
            } catch let error as TaskStateMachineError {
                switch error {
                case let .illegalTransition(from, to):
                    throw TaskServiceError.illegalTransition(from: from, to: to)
                }
            }
            try taskRepository.updateStatus(taskID, status: status, updatedAt: Date())
            try audit(taskID: taskID, sideEffect: .read, digest: "", summary: "task transitioned", result: "\(task.status.rawValue) -> \(status.rawValue)")
        }
    }

    private func moveTaskToRunningIfNeeded(taskID: UUID) throws {
        let status = try lock.withLock { try taskRepository.fetch(id: taskID)?.status }
        guard let status else { throw TaskServiceError.taskNotFound }
        switch status {
        case .draft:
            try transition(taskID: taskID, to: .planning)
            try transition(taskID: taskID, to: .running)
        case .planning:
            try transition(taskID: taskID, to: .running)
        case .running:
            break
        default:
            throw TaskServiceError.illegalTransition(from: status, to: .running)
        }
    }

    private func executeAllowedRequest(_ request: ToolRequest, approvalID: UUID? = nil) async throws {
        do {
            _ = try await executor.execute(request)
            try lock.withLock {
                try audit(
                    taskID: request.taskID,
                    sideEffect: request.sideEffect,
                    digest: request.payloadDigest,
                    summary: "tool result",
                    result: "completed",
                    approvalID: approvalID,
                    target: request.target
                )
            }
        } catch {
            try transition(taskID: request.taskID, to: .failed)
            try lock.withLock {
                try auditRequest(request, summary: "tool failure", result: "failed", approvalID: approvalID)
            }
            throw error
        }
    }

    private func auditRequest(
        _ request: ToolRequest,
        summary: String,
        result: String,
        approvalID: UUID? = nil
    ) throws {
        try audit(
            taskID: request.taskID,
            sideEffect: request.sideEffect,
            digest: request.payloadDigest,
            summary: summary,
            result: result,
            approvalID: approvalID,
            target: request.target
        )
    }

    private func audit(
        taskID: UUID,
        sideEffect: SideEffect,
        digest: String,
        summary: String,
        result: String,
        approvalID: UUID? = nil,
        target: String = "local task service"
    ) throws {
        // Never place request payloads or executor error text in audit fields.
        try auditRepository.append(AuditEvent(
            taskID: taskID,
            worker: "task-service",
            target: target,
            sideEffect: sideEffect,
            actionDigest: digest,
            summary: summary,
            result: result,
            approvalID: approvalID
        ))
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
