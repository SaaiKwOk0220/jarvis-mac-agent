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
    private let approvals: any ApprovalRepository
    private let uow: any PersistenceUnitOfWork
    private let policy: any PolicyEvaluator
    private let config: PolicyConfig
    private let executor: any ToolExecutor
    private let lock = NSLock()
    private var executions: [UUID: Swift.Task<Void, Error>] = [:]

    public init(taskRepository: any TaskRepository, auditRepository: any AuditRepository, policy: any PolicyEvaluator, policyConfig: PolicyConfig = .init(), executor: any ToolExecutor = NoOpToolExecutor(), requestRepository: (any ToolRequestRepository)? = nil, approvalRepository: (any ApprovalRepository)? = nil, unitOfWork: (any PersistenceUnitOfWork)? = nil) throws {
        guard let sqliteTasks = taskRepository as? SQLiteTaskRepository,
              let sqliteAudits = auditRepository as? SQLiteAuditRepository,
              sqliteTasks.database === sqliteAudits.database else { throw TaskServiceError.incompatiblePersistence }
        let database = sqliteTasks.database
        if let requestRepository {
            guard let sqlite = requestRepository as? SQLiteToolRequestRepository, sqlite.database === database else { throw TaskServiceError.incompatiblePersistence }
            self.requests = sqlite
        } else { self.requests = SQLiteToolRequestRepository(database: database) }
        if let approvalRepository {
            guard let sqlite = approvalRepository as? SQLiteApprovalRepository, sqlite.database === database else { throw TaskServiceError.incompatiblePersistence }
            self.approvals = sqlite
        } else { self.approvals = SQLiteApprovalRepository(database: database) }
        if let unitOfWork {
            guard let sqlite = unitOfWork as? SQLitePersistenceUnitOfWork, sqlite.database === database else { throw TaskServiceError.incompatiblePersistence }
            self.uow = sqlite
        } else { self.uow = SQLitePersistenceUnitOfWork(database: database) }
        self.tasks = taskRepository; self.audits = auditRepository; self.policy = policy; self.config = policyConfig; self.executor = executor
    }

    public func createTask(title: String) async throws -> Task { try lock.withLock { let task = Task(title: title); try uow.createTask(task, audit: event(taskID: task.id, summary: "task created", result: "created")); return task } }
    public func getTask(id: UUID) async throws -> Task? { try lock.withLock { try tasks.fetch(id: id) } }
    public func listTasks() async throws -> [Task] { try lock.withLock { try tasks.list() } }

    public func listPendingApprovalRequests(taskID: UUID) async throws -> [PendingApprovalRequest] {
        try lock.withLock {
            guard try tasks.fetch(id: taskID) != nil else { throw TaskServiceError.taskNotFound }
            let pending = try requests.list(status: .pending).filter { $0.0.taskID == taskID }
            return try pending.map { request, _ in
                let reason = (try? audits.events(for: taskID).reversed().first(where: {
                    $0.actionDigest == request.payloadDigest && $0.summary == "policy requires approval"
                })?.result) ?? "Approval requested by policy"
                let redactedPayload = redactSecrets(request.payload)
                return PendingApprovalRequest(id: request.id, taskID: request.taskID, reason: reason,
                    target: request.target, payload: redactedPayload == request.payload ? redactedPayload : "[REDACTED]", digest: request.payloadDigest)
            }
        }
    }

    public func submit(request: ToolRequest) async throws -> PolicyDecision {
        try lock.withLock { try ensureRunning(request.taskID) }
        let decision = policy.evaluate(request, config: config)
        switch decision {
        case .allow:
            try lock.withLock {
                try requireRunning(request.taskID)
                try uow.recordRequest(request, status: .executing, audits: [event(request, summary: "tool request received", result: "received"), event(request, summary: "policy allowed", result: "allowed")])
            }
            try await runTracked(request)
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
            for (requestID, job) in executions {
                if let (request, _) = try requests.fetch(id: requestID), request.taskID == taskID { job.cancel() }
            }
            try uow.cancelTask(taskID: taskID, requestIDs: [], audits: [event(taskID: taskID, summary: "task cancelled", result: "cancelled")])
        }
    }

    public func transition(taskID: UUID, to: TaskStatus) throws { try lock.withLock { let task = try requiredTask(taskID); try transition(task, to: to) } }

    private func startExecution(_ request: ToolRequest) {
        let gate = ExecutionGate()
        let job: Swift.Task<Void, Error> = Swift.Task { [weak self] in
            await gate.wait()
            defer { self?.removeExecution(request.id) }
            guard let self else { return }
            try await self.execute(request)
        }
        lock.withLock { executions[request.id] = job }
        gate.open()
    }

    private func runTracked(_ request: ToolRequest) async throws {
        let gate = ExecutionGate()
        let job: Swift.Task<Void, Error> = Swift.Task { [weak self] in
            await gate.wait()
            defer { self?.removeExecution(request.id) }
            guard let self else { return }
            try await self.execute(request)
        }
        lock.withLock { executions[request.id] = job }
        gate.open()
        try await job.value
    }

    private func removeExecution(_ requestID: UUID) {
        _ = lock.withLock { executions.removeValue(forKey: requestID) }
    }

    private func execute(_ request: ToolRequest) async throws {
        do {
            try lock.withLock { guard let (_, status) = try requests.fetch(id: request.id), status == .executing else { throw TaskServiceError.requestNotAwaitingApproval }; try requireRunning(request.taskID) }
            let result = try await executor.execute(request)
            try lock.withLock {
                guard let task = try tasks.fetch(id: request.taskID), task.status != .cancelled else { return }
                try uow.finishRequest(request, status: .completed, taskStatus: nil, audits: [event(request, summary: "tool result", result: bounded(result.summary))])
            }
        } catch is CancellationError {
            // Cancellation transaction already sets request and task to cancelled; never add success/failure after it.
        } catch {
            try lock.withLock {
                guard let task = try tasks.fetch(id: request.taskID), task.status != .cancelled else { return }
                try uow.finishRequest(request, status: .failed, taskStatus: .failed, audits: [event(request, summary: "tool failure", result: "failed")])
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

private final class ExecutionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock { () -> Bool in
                guard !isOpen else { return true }
                self.continuation = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func open() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            isOpen = true
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume()
    }
}
private extension NSLock { func withLock<T>(_ body: () throws -> T) rethrows -> T { lock(); defer { unlock() }; return try body() } }
