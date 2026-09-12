import Foundation
import JarvisDomain
import JarvisPersistence
import JarvisPolicy

public struct ToolResult: Codable, Equatable, Sendable { public let summary: String; public init(summary: String) { self.summary = summary } }
public protocol ToolExecutor: Sendable { func execute(_ request: ToolRequest) async throws -> ToolResult }
public struct NoOpToolExecutor: ToolExecutor { public init() {} ; public func execute(_ request: ToolRequest) async throws -> ToolResult { ToolResult(summary: "demo executor completed") } }
public enum TaskServiceError: Error, Equatable, Sendable { case taskNotFound, requestNotFound, requestNotAwaitingApproval, approvalDigestMismatch, illegalTransition(from: TaskStatus, to: TaskStatus), incompatiblePersistence }

public final class TaskService: TaskServiceAPI, @unchecked Sendable {
    private let tasks: any TaskRepository
    private let audits: any AuditRepository
    private let requests: any ToolRequestRepository
    private let uow: any PersistenceUnitOfWork
    private let policy: any PolicyEvaluator
    private let config: PolicyConfig
    private let executor: any ToolExecutor
    private let lock = NSLock()
    private var executions: [UUID: Swift.Task<Void, Never>] = [:]

    public init(taskRepository: any TaskRepository, auditRepository: any AuditRepository, policy: any PolicyEvaluator, policyConfig: PolicyConfig = .init(), executor: any ToolExecutor = NoOpToolExecutor(), requestRepository: (any ToolRequestRepository)? = nil, approvalRepository: (any ApprovalRepository)? = nil, unitOfWork: (any PersistenceUnitOfWork)? = nil) {
        self.tasks = taskRepository; self.audits = auditRepository; self.policy = policy; self.config = policyConfig; self.executor = executor
        if let requests = requestRepository, let unitOfWork { self.requests = requests; self.uow = unitOfWork }
        else if let sqlite = taskRepository as? SQLiteTaskRepository { self.requests = SQLiteToolRequestRepository(database: sqlite.database); self.uow = SQLitePersistenceUnitOfWork(database: sqlite.database) }
        else { preconditionFailure("TaskService requires a ToolRequestRepository and PersistenceUnitOfWork") }
        _ = approvalRepository
    }

    public func createTask(title: String) async throws -> Task { try lock.withLock { let task = Task(title: title); try uow.createTask(task, audit: event(taskID: task.id, summary: "task created", result: "created")); return task } }
    public func getTask(id: UUID) async throws -> Task? { try lock.withLock { try tasks.fetch(id: id) } }
    public func listTasks() async throws -> [Task] { try lock.withLock { try tasks.list() } }

    public func submit(request: ToolRequest) async throws -> PolicyDecision {
        try lock.withLock { try ensureRunning(request.taskID) }
        let decision = policy.evaluate(request, config: config)
        switch decision {
        case .allow:
            try lock.withLock {
                try requireRunning(request.taskID)
                try uow.recordRequest(request, status: .executing, audits: [event(request, summary: "tool request received", result: "received"), event(request, summary: "policy allowed", result: "allowed")])
            }
            try await execute(request)
        case .requireApproval(let reason):
            try lock.withLock {
                try requireRunning(request.taskID)
                try uow.submitRequest(request, status: .pending, taskStatus: .awaitingApproval, audits: [event(request, summary: "tool request received", result: "received"), event(request, summary: "policy requires approval", result: reason)])
            }
        case .deny(let reason):
            try lock.withLock {
                try requireRunning(request.taskID)
                let task = try requiredTask(request.taskID)
                try uow.transition(taskID: task.id, from: task.status, to: .blocked, audits: [event(request, summary: "tool request received", result: "received"), event(request, summary: "policy denied", result: reason)])
            }
        }
        return decision
    }

    public func approve(requestID: UUID, digest: String) async throws {
        let request = try lock.withLock { () throws -> ToolRequest in
            guard let (request, status) = try requests.fetch(id: requestID), status == .pending else { throw TaskServiceError.requestNotAwaitingApproval }
            guard validateApproval(request: request, approvalDigest: digest) else { try audits.append(event(request, summary: "approval rejected", result: "digest mismatch")); throw TaskServiceError.approvalDigestMismatch }
            let approval = Approval(toolRequestID: request.id, actionDigest: request.payloadDigest, decision: .approved)
            try uow.approveRequest(request, approval: approval, taskStatus: .running, audits: [event(request, summary: "approval accepted", result: "approved", approvalID: approval.id)])
            return request
        }
        startExecution(request)
    }

    public func reject(requestID: UUID) async throws {
        try lock.withLock {
            guard let (request, status) = try requests.fetch(id: requestID), status == .pending else { throw TaskServiceError.requestNotAwaitingApproval }
            let approval = Approval(toolRequestID: request.id, actionDigest: request.payloadDigest, decision: .rejected)
            try uow.rejectRequest(request, approval: approval, taskStatus: .blocked, audits: [event(request, summary: "approval rejected", result: "rejected", approvalID: approval.id)])
        }
    }

    public func cancel(taskID: UUID) async throws {
        try lock.withLock {
            executions.removeValue(forKey: taskID)?.cancel()
            let hasExecuting = try requests.list(status: .executing).contains { $0.0.taskID == taskID }
            if hasExecuting {
                try uow.cancelExecutingTask(taskID: taskID, audits: [event(taskID: taskID, summary: "task cancelled", result: "cancelled")])
            } else {
                let ids = try requests.list(status: .pending).filter { $0.0.taskID == taskID }.map { $0.0.id }
                try uow.cancelTask(taskID: taskID, requestIDs: ids, audits: [event(taskID: taskID, summary: "task cancelled", result: "cancelled")])
            }
        }
    }

    public func transition(taskID: UUID, to: TaskStatus) throws { try lock.withLock { let task = try requiredTask(taskID); try transition(task, to: to) } }

    private func startExecution(_ request: ToolRequest) {
        let task = Swift.Task { [weak self] in _ = try? await self?.execute(request) }
        lock.withLock { executions[request.taskID] = task }
    }

    private func execute(_ request: ToolRequest) async throws {
        do {
            try lock.withLock { guard let (_, status) = try requests.fetch(id: request.id), status == .executing else { throw TaskServiceError.requestNotAwaitingApproval }; try requireRunning(request.taskID) }
            let result = try await executor.execute(request)
            try lock.withLock {
                guard let task = try tasks.fetch(id: request.taskID), task.status != .cancelled else { return }
                try uow.finishRequest(request, status: .completed, taskStatus: nil, audits: [event(request, summary: "tool result", result: bounded(result.summary))])
                executions.removeValue(forKey: request.taskID)
            }
        } catch is CancellationError {
            // Cancellation transaction already sets request and task to cancelled; never add success/failure after it.
        } catch {
            try lock.withLock {
                guard let task = try tasks.fetch(id: request.taskID), task.status != .cancelled else { return }
                try uow.finishRequest(request, status: .failed, taskStatus: .failed, audits: [event(request, summary: "tool failure", result: "failed")])
                executions.removeValue(forKey: request.taskID)
            }
            throw error
        }
    }

    private func ensureRunning(_ id: UUID) throws { let task = try requiredTask(id); switch task.status { case .draft: try transition(task, to: .planning); try transition(try requiredTask(id), to: .running); case .planning: try transition(task, to: .running); case .running: return; default: throw TaskServiceError.illegalTransition(from: task.status, to: .running) } }
    private func requireRunning(_ id: UUID) throws { guard (try requiredTask(id)).status == .running else { throw TaskServiceError.illegalTransition(from: try requiredTask(id).status, to: .running) } }
    private func requiredTask(_ id: UUID) throws -> Task { guard let task = try tasks.fetch(id: id) else { throw TaskServiceError.taskNotFound }; return task }
    private func transition(_ task: Task, to: TaskStatus) throws { do { try TaskStateMachine.validate(from: task.status, to: to) } catch { throw TaskServiceError.illegalTransition(from: task.status, to: to) }; try uow.transition(taskID: task.id, from: task.status, to: to, audits: [event(taskID: task.id, summary: "task transitioned", result: "\(task.status.rawValue) -> \(to.rawValue)")]) }
    private func bounded(_ summary: String) -> String { String(redactSecrets(summary).prefix(512)) }
    private func event(_ request: ToolRequest, summary: String, result: String, approvalID: UUID? = nil) -> AuditEvent { event(taskID: request.taskID, sideEffect: request.sideEffect, digest: request.payloadDigest, summary: summary, result: result, approvalID: approvalID, target: request.target) }
    private func event(taskID: UUID, sideEffect: SideEffect = .read, digest: String = "", summary: String, result: String, approvalID: UUID? = nil, target: String = "local task service") -> AuditEvent { AuditEvent(taskID: taskID, worker: "task-service", target: target, sideEffect: sideEffect, actionDigest: digest, summary: summary, result: result, approvalID: approvalID) }
}
private extension NSLock { func withLock<T>(_ body: () throws -> T) rethrows -> T { lock(); defer { unlock() }; return try body() } }
