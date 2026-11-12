import Foundation
import JarvisDomain
import JarvisPersistence
import JarvisPolicy

public struct ToolResult: Codable, Equatable, Sendable { public let summary: String; public init(summary: String) { self.summary = summary } }
public protocol ToolExecutor: Sendable { func execute(_ request: ToolRequest) async throws -> ToolResult }
public struct NoOpToolExecutor: ToolExecutor { public init() {} ; public func execute(_ request: ToolRequest) async throws -> ToolResult { ToolResult(summary: "demo executor completed") } }
public enum TaskServiceError: Error, Equatable, Sendable { case taskNotFound, requestNotFound, requestNotAwaitingApproval, approvalDigestMismatch, illegalTransition(from: TaskStatus, to: TaskStatus), incompatiblePersistence }

/// Narrow capability used only by the bundled UI to exercise the approval flow.
public protocol DemoTaskServiceAPI: TaskServiceAPI {
    func submitDemoApproval(taskID: UUID) async throws
}

public final class TaskService: DemoTaskServiceAPI, @unchecked Sendable {
    private let tasks: any TaskRepository
    private let audits: any AuditRepository
    private let requests: any ToolRequestRepository
    private let approvals: any ApprovalRepository
    private let uow: any PersistenceUnitOfWork
    private let policy: any PolicyEvaluator
    private let config: PolicyConfig
    private let executor: any ToolExecutor
    private let terminal: TerminalToolExecutor?
    private let webFetch: WebFetchToolExecutor?
    private let screenshot: ScreenshotToolExecutor?
    private let accessibility: AccessibilityQueryToolExecutor?
    private let enableSafariRead: Bool
    private let safariCoordinator = SafariReadCoordinator()
    var safariCaptureFactory: @Sendable () -> any SafariTargetCapturing = { SafariAXTargetCapture() }
    private let ephemeralResults = EphemeralToolResultStore()
    private let lock = NSLock()
    private var executions: [UUID: Task<Void, Error>] = [:]

    public init(taskRepository: any TaskRepository, auditRepository: any AuditRepository, policy: any PolicyEvaluator, policyConfig: PolicyConfig = .init(), executor: any ToolExecutor = NoOpToolExecutor(), terminal: TerminalToolExecutor? = nil, webFetch: WebFetchToolExecutor? = nil, screenshot: ScreenshotToolExecutor? = nil, accessibility: AccessibilityQueryToolExecutor? = nil, enableSafariRead: Bool = false, requestRepository: (any ToolRequestRepository)? = nil, approvalRepository: (any ApprovalRepository)? = nil, unitOfWork: (any PersistenceUnitOfWork)? = nil) throws {
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
        self.tasks = taskRepository; self.audits = auditRepository; self.policy = policy; self.config = policyConfig; self.executor = executor; self.terminal = terminal; self.webFetch = webFetch; self.screenshot = screenshot; self.accessibility = accessibility; self.enableSafariRead = enableSafariRead
    }

    public func createTask(title: String) async throws -> JarvisTask { try lock.withLock { let task = JarvisTask(title: title); try uow.createTask(task, audit: event(taskID: task.id, summary: "task created", result: "created")); return task } }
    public func getTask(id: UUID) async throws -> JarvisTask? { try lock.withLock { try tasks.fetch(id: id) } }
    public func listTasks() async throws -> [JarvisTask] { try lock.withLock { try tasks.list() } }

    public func listPendingApprovalRequests(taskID: UUID) async throws -> [PendingApprovalRequest] {
        let pending: [(ToolRequest, String)] = try lock.withLock {
            guard try tasks.fetch(id: taskID) != nil else { throw TaskServiceError.taskNotFound }
            let events = try audits.events(for: taskID)
            return try requests.list(status: .pending).filter { $0.0.taskID == taskID }.map { request, _ in
                let reason = events.reversed().first { $0.actionDigest == request.payloadDigest && $0.requestID == request.id && $0.summary == "policy requires approval" }?.result ?? "Approval requested by policy"
                return (request, reason)
            }
        }
        var output: [PendingApprovalRequest] = []
        for (request, reason) in pending {
            if request.name == "safari_read" {
                let exactURL = await safariCoordinator.preview(request) ?? "Capture expired; reject and try again."
                output.append(PendingApprovalRequest(id: request.id, taskID: request.taskID, reason: reason, target: exactURL, payload: "Read accessibility text from this captured Safari window", digest: request.payloadDigest))
            } else {
                let redactedPayload = redactSecrets(request.payload)
                output.append(PendingApprovalRequest(id: request.id, taskID: request.taskID, reason: reason, target: request.target, payload: redactedPayload == request.payload ? redactedPayload : "[REDACTED]", digest: request.payloadDigest))
            }
        }
        return output
    }

    public func isSafariReadAvailable() async -> Bool { enableSafariRead }

    public func prepareSafariRead(taskID: UUID) async throws -> ToolRequest {
        guard enableSafariRead else { throw TaskServiceCapabilityError.unavailable }
        try lock.withLock { try ensureRunning(taskID) }
        let request = try await safariCoordinator.prepare(taskID: taskID, capture: safariCaptureFactory())
        do {
            try Task.checkCancellation()
            try lock.withLock { try requireRunning(taskID) }
            return request
        } catch {
            await safariCoordinator.discard(request)
            throw error
        }
    }

    public func listTimelineEvents(taskID: UUID) async throws -> [TimelineEvent] {
        try lock.withLock {
            guard try tasks.fetch(id: taskID) != nil else { throw TaskServiceError.taskNotFound }
            return try audits.events(for: taskID).map { event in
                TimelineEvent(id: event.id, timestamp: event.timestamp, worker: event.worker,
                    target: redactSecrets(event.target), sideEffect: event.sideEffect,
                    actionDigest: event.actionDigest, summary: event.summary, result: event.result,
                    approvalID: event.approvalID, requestID: event.requestID)
            }
        }
    }

    public func submitDemoApproval(taskID: UUID) async throws {
        guard let directory = config.approvedDirectories.first else { throw TaskServiceError.incompatiblePersistence }
        let target = URL(fileURLWithPath: directory).appendingPathComponent("Jarvis demo draft.txt").path
        let request = ToolRequest(taskID: taskID, name: "demo_write", sideEffect: .localWrite,
            target: target, payload: "Create a local demo draft")
        _ = try await submit(request: request)
    }

    public func submit(request: ToolRequest) async throws -> PolicyDecision {
        guard request.name != "safari_click_experiment" else { throw TaskServiceCapabilityError.unavailable }
        try lock.withLock { try ensureRunning(request.taskID) }
        var decision = policy.evaluate(request, config: config)
        if request.name == "safari_read" {
            let preview = enableSafariRead ? await safariCoordinator.preview(request) : nil
            if preview == nil { decision = .deny(reason: "Safari capture unavailable or expired") }
            else if case .requireApproval = decision { } else { decision = .deny(reason: "Safari reading requires explicit approval") }
        }
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
            if request.name == "safari_read" { await safariCoordinator.discard(request) }
        }
        return decision
    }

    public func approve(requestID: UUID, digest: String) async throws {
        let preliminary = try lock.withLock { () throws -> ToolRequest in
            guard let (request, status) = try requests.fetch(id: requestID), status == .pending else { throw TaskServiceError.requestNotAwaitingApproval }
            return request
        }
        guard preliminary.name != "safari_click_experiment" else { throw TaskServiceCapabilityError.unavailable }
        if preliminary.name == "safari_read" {
            guard enableSafariRead, await safariCoordinator.preview(preliminary) != nil else { throw TaskServiceCapabilityError.unavailable }
        }
        let (request, approval) = try lock.withLock { () throws -> (ToolRequest, Approval) in
            guard let (request, status) = try requests.fetch(id: requestID), status == .pending else { throw TaskServiceError.requestNotAwaitingApproval }
            guard validateApproval(request: request, approvalDigest: digest) else { try audits.append(event(request, summary: "approval rejected", result: "digest mismatch")); throw TaskServiceError.approvalDigestMismatch }
            let approval = Approval(toolRequestID: request.id, actionDigest: request.payloadDigest, decision: .approved)
            let taskStatus = try aggregateStatus(forTask: request.taskID, excluding: request.id, fallback: .running)
            try uow.approveRequest(request, approval: approval, taskStatus: taskStatus, audits: [event(request, summary: "approval accepted", result: "approved", approvalID: approval.id)])
            return (request, approval)
        }
        startExecution(request, approval: approval)
    }

    public func reject(requestID: UUID) async throws {
        let rejected: ToolRequest = try lock.withLock {
            guard let (request, status) = try requests.fetch(id: requestID), status == .pending else { throw TaskServiceError.requestNotAwaitingApproval }
            let approval = Approval(toolRequestID: request.id, actionDigest: request.payloadDigest, decision: .rejected)
            let taskStatus = try aggregateStatus(forTask: request.taskID, excluding: request.id, fallback: .blocked)
            try uow.rejectRequest(request, approval: approval, taskStatus: taskStatus, audits: [event(request, summary: "approval rejected", result: "rejected", approvalID: approval.id)])
            return request
        }
        if rejected.name == "safari_read" { await safariCoordinator.discard(rejected) }
    }

    public func cancel(taskID: UUID) async throws {
        try lock.withLock {
            let task = try requiredTask(taskID)
            if task.status == .cancelled || task.status == .completed || task.status == .failed {
                throw TaskServiceError.illegalTransition(from: task.status, to: .cancelled)
            }
            for (requestID, job) in executions {
                if let (request, _) = try requests.fetch(id: requestID), request.taskID == taskID { job.cancel() }
            }
            ephemeralResults.clear(taskID: taskID)
            try uow.cancelTask(taskID: taskID, requestIDs: [], audits: [event(taskID: taskID, summary: "task cancelled", result: "cancelled")])
        }
        await safariCoordinator.clear(taskID: taskID)
    }

    public func takeEphemeralToolResult(taskID: UUID, requestID: UUID, digest: String) async throws -> String? {
        try lock.withLock {
            guard let (request, status) = try requests.fetch(id: requestID), request.taskID == taskID,
                  request.name == "safari_read", request.payloadDigest == digest, status == .completed else { return nil }
            return ephemeralResults.take(taskID: taskID, requestID: requestID, digest: digest)
        }
    }

    public func transition(taskID: UUID, to: TaskStatus) throws { try lock.withLock { let task = try requiredTask(taskID); try transition(task, to: to) } }

    /// Marks a task as `.completed` from a non-terminal state. The task must
    /// currently be `.running`, `.awaitingApproval`, `.draft`, `.planning`, or
    /// `.blocked`; calling this on an already-terminal task
    /// (`.completed`, `.cancelled`, or `.failed`) throws
    /// `TaskServiceError.illegalTransition`. Use this after a multi-request
    /// workflow finishes all of its tool runs to record the task as done.
    public func complete(taskID: UUID) async throws {
        try lock.withLock {
            let task = try requiredTask(taskID)
            guard task.status != .cancelled && task.status != .completed && task.status != .failed else {
                throw TaskServiceError.illegalTransition(from: task.status, to: .completed)
            }
            ephemeralResults.clear(taskID: taskID)
            try uow.transition(
                taskID: task.id,
                from: task.status,
                to: .completed,
                audits: [event(taskID: task.id, summary: "task completed", result: "completed")]
            )
        }
        await safariCoordinator.clear(taskID: taskID)
    }

    private func startExecution(_ request: ToolRequest, approval: Approval) {
        let gate = ExecutionGate()
        let job: Task<Void, Error> = Task { [weak self] in
            await gate.wait()
            defer { self?.removeExecution(request.id) }
            guard let self else { return }
            try await self.execute(request, approval: approval)
        }
        lock.withLock { executions[request.id] = job }
        gate.open()
    }

    private func runTracked(_ request: ToolRequest) async throws {
        let gate = ExecutionGate()
        let job: Task<Void, Error> = Task { [weak self] in
            await gate.wait()
            defer { self?.removeExecution(request.id) }
            guard let self else { return }
            try await self.execute(request)
        }
        lock.withLock { executions[request.id] = job }
        gate.open()
        try await job.value
    }

    /// Wait for an existing tracked execution to finish; returns immediately if already removed.
    func waitForTrackedExecution(_ requestID: UUID) async {
        let job = lock.withLock { executions[requestID] }
        _ = try? await job?.value
    }

    private func removeExecution(_ requestID: UUID) {
        _ = lock.withLock { executions.removeValue(forKey: requestID) }
    }

    /// On a successful executor run the task returns to the status implied by
    /// the requests that are still outstanding: `.running` when nothing else is
    /// outstanding, or `.awaitingApproval` when another request is still pending
    /// a decision. Either way further `submit(request:)` calls on this task can
    /// drive multi-request workflows. Use `complete(taskID:)` to transition to
    /// `.completed` when the workflow is done. A thrown executor goes through
    /// the same aggregate so that an in-flight failure does not orphan another
    /// pending request on the same task: failure + another pending →
    /// `.awaitingApproval`; failure + another executing → `.running`;
    /// failure + nothing else outstanding → `.failed`.
    private func execute(_ request: ToolRequest, approval: Approval? = nil) async throws {
        do {
            try lock.withLock { guard let (_, status) = try requests.fetch(id: request.id), status == .executing else { throw TaskServiceError.requestNotAwaitingApproval }; try requireRunning(request.taskID) }
            if request.name == "safari_read" && (!enableSafariRead || approval == nil) { throw SafariAXReadError.unavailable }
            let picked: any ToolExecutor = {
                if request.name == "shell", let terminal = self.terminal { return terminal }
                if request.name == "fetch", let webFetch = self.webFetch { return webFetch }
                if request.name == "screenshot", let screenshot = self.screenshot { return screenshot }
                if request.name == "ax_query", let accessibility = self.accessibility { return accessibility }
                return executor
            }()
            let result: ToolResult
            if request.name == "safari_read" {
                guard let approval else { throw SafariAXReadError.unavailable }
                result = ToolResult(summary: try await safariCoordinator.readApproved(request, approval: approval))
            } else {
                result = try await picked.execute(request)
            }
            try lock.withLock {
                guard let task = try tasks.fetch(id: request.taskID), task.status != .cancelled else { return }
                let taskStatus = try aggregateStatus(forTask: request.taskID, excluding: request.id, fallback: .running)
                let auditResult = request.name == "safari_read" ? request.id.uuidString : bounded(result.summary)
                let summary = request.name == "safari_read" ? "ephemeral tool result" : "tool result"
                try uow.finishRequest(request, status: .completed, taskStatus: taskStatus, audits: [event(request, summary: summary, result: auditResult)])
                if request.name == "safari_read" {
                    ephemeralResults.put(result.summary, taskID: request.taskID, requestID: request.id, digest: request.payloadDigest)
                }
            }
        } catch is CancellationError {
            // Cancellation transaction already sets request and task to cancelled; never add success/failure after it.
        } catch {
            let fallback: TaskStatus = .failed
            let aggregate: TaskStatus = (try? aggregateStatus(forTask: request.taskID, excluding: request.id, fallback: fallback)) ?? fallback
            try lock.withLock {
                guard let task = try tasks.fetch(id: request.taskID), task.status != .cancelled else { return }
                let safeFailure = request.name == "safari_read" ? Self.safariFailureMessage(error) : "failed"
                try uow.finishRequest(request, status: .failed, taskStatus: aggregate, audits: [event(request, summary: "tool failure", result: safeFailure)])
            }
            throw error
        }
    }

    private func ensureRunning(_ id: UUID) throws { let task = try requiredTask(id); switch task.status { case .draft: try transition(task, to: .planning); try transition(try requiredTask(id), to: .running); case .planning: try transition(task, to: .running); case .running, .awaitingApproval: return; default: throw TaskServiceError.illegalTransition(from: task.status, to: .running) } }
    /// A task that is `.awaitingApproval` is still alive: it can accept further
    /// requests while earlier ones wait for a decision, so it counts as running
    /// for the purpose of attaching new work.
    private func requireRunning(_ id: UUID) throws { let status = try requiredTask(id).status; guard status == .running || status == .awaitingApproval else { throw TaskServiceError.illegalTransition(from: status, to: .running) } }

    /// Aggregates the task status implied by the requests that remain
    /// outstanding once `excludedRequestID` has been moved out of the
    /// `.pending` / `.executing` sets by the write this value accompanies.
    /// The request being decided must be excluded, otherwise deciding the last
    /// pending request would still see itself and never reach `fallback`.
    /// Executing wins over pending; otherwise `fallback` applies.
    private func aggregateStatus(forTask taskID: UUID, excluding excludedRequestID: UUID? = nil, fallback: TaskStatus) throws -> TaskStatus {
        let executing = try requests.list(status: .executing).contains { $0.0.taskID == taskID && $0.0.id != excludedRequestID }
        if executing { return .running }
        let pending = try requests.list(status: .pending).contains { $0.0.taskID == taskID && $0.0.id != excludedRequestID }
        return pending ? .awaitingApproval : fallback
    }
    private func requiredTask(_ id: UUID) throws -> JarvisTask { guard let task = try tasks.fetch(id: id) else { throw TaskServiceError.taskNotFound }; return task }
    private func transition(_ task: JarvisTask, to: TaskStatus) throws { do { try TaskStateMachine.validate(from: task.status, to: to) } catch { throw TaskServiceError.illegalTransition(from: task.status, to: to) }; try uow.transition(taskID: task.id, from: task.status, to: to, audits: [event(taskID: task.id, summary: "task transitioned", result: "\(task.status.rawValue) -> \(to.rawValue)")]) }
    private func bounded(_ summary: String) -> String { String(redactSecrets(summary).prefix(512)) }
    private func event(_ request: ToolRequest, summary: String, result: String, approvalID: UUID? = nil) -> AuditEvent { event(taskID: request.taskID, sideEffect: request.sideEffect, digest: request.payloadDigest, summary: summary, result: result, approvalID: approvalID, requestID: request.id, target: (request.name == "safari_read") ? Self.browserAuditTarget(request.target) : request.target) }
    private static func safariFailureMessage(_ error: Error) -> String {
        if let error = error as? SafariAXReadError { return error.localizedDescription }
        if let error = error as? SafariVisiblePageError { return error.localizedDescription }
        if let error = error as? SafariReadCoordinatorError { return error.localizedDescription }
        return "Safari page reading failed safely."
    }

    private static func browserAuditTarget(_ target: String) -> String {
        guard let parts = URLComponents(string: target), parts.scheme == "https", let host = parts.host else { return "[REDACTED]" }
        return "https://\(host)" + (parts.port.map { ":\($0)" } ?? "")
    }
    private func event(taskID: UUID, sideEffect: SideEffect = .read, digest: String = "", summary: String, result: String, approvalID: UUID? = nil, requestID: UUID? = nil, target: String = "local task service") -> AuditEvent { AuditEvent(taskID: taskID, worker: "task-service", target: target, sideEffect: sideEffect, actionDigest: digest, summary: summary, result: result, approvalID: approvalID, requestID: requestID) }
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
