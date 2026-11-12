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
    // Remains disabled until the approval, cancellation and executor paths are verified end-to-end.
    private let exactBrowserAllowed: Bool
    private let exactBrowserGate = ExactBrowserSessionGate()
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
    private let browserOpen: BrowserOpenExecutor?
    private let browserTickets: BrowserURLTicketStore
    var testBrowserTicketCount: Int { browserTickets.testEntryCount }
    private let lock = NSLock()
    private var executions: [UUID: Task<Void, Error>] = [:]
    // Process-local fallback when a started browser operation cannot persist its outcome.
    private var browserUnknownEvents: [UUID: (taskID: UUID, event: TimelineEvent)] = [:]
    private static let maximumUnresolvedExactBrowserRequests = 64

    /// Called under `lock`: never evict unknown outcomes to make space.
    private func hasExactBrowserCapacityLocked() throws -> Bool {
        var reserved = Set(browserUnknownEvents.keys)
        for status: ToolRequestStatus in [.pending, .executing] {
            for (request, _) in try requests.list(status: status)
            where request.name == "browser_open" && BrowserURLTicketStore.Ticket(payload: request.payload) != nil {
                reserved.insert(request.id)
            }
        }
        for id in executions.keys {
            if let (request, _) = try requests.fetch(id: id), request.name == "browser_open",
               BrowserURLTicketStore.Ticket(payload: request.payload) != nil { reserved.insert(id) }
        }
        return reserved.count < Self.maximumUnresolvedExactBrowserRequests
    }
    #if JARVIS_SAFARI_CLICK_TESTING
    var testAfterExactBrowserOpen: @Sendable () async -> Void = {}
    #endif

    private func recordBrowserUnknownLocked(_ request: ToolRequest) {
        let message = BrowserOpenError.outcomeUnknown.errorDescription ?? "Browser open outcome unknown"
        browserUnknownEvents[request.id] = (request.taskID, TimelineEvent(id: UUID(), timestamp: Date(), worker: "task-service", target: Self.browserAuditTarget(request.target), sideEffect: request.sideEffect, actionDigest: request.payloadDigest, summary: "browser open outcome unknown", result: message, approvalID: nil, requestID: request.id))
    }

    public init(taskRepository: any TaskRepository, auditRepository: any AuditRepository, policy: any PolicyEvaluator, policyConfig: PolicyConfig = .init(), executor: any ToolExecutor = NoOpToolExecutor(), terminal: TerminalToolExecutor? = nil, webFetch: WebFetchToolExecutor? = nil, screenshot: ScreenshotToolExecutor? = nil, accessibility: AccessibilityQueryToolExecutor? = nil, browserOpen: BrowserOpenExecutor? = nil, requestRepository: (any ToolRequestRepository)? = nil, approvalRepository: (any ApprovalRepository)? = nil, unitOfWork: (any PersistenceUnitOfWork)? = nil, exactBrowserEnabled: Bool = false, browserTicketLifetime: TimeInterval = 300, allowExactBrowserToggle: Bool = false) throws {
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
        self.browserTickets = BrowserURLTicketStore(lifetime: browserTicketLifetime)
        #if JARVIS_EXACT_BROWSER_EXPERIMENT || JARVIS_COMBINED_EXPERIMENT
        self.exactBrowserAllowed = exactBrowserEnabled || allowExactBrowserToggle
        self.exactBrowserGate.setEnabled(exactBrowserEnabled)
        #else
        self.exactBrowserAllowed = false
        #endif
        self.tasks = taskRepository; self.audits = auditRepository; self.policy = policy; self.config = policyConfig; self.executor = executor; self.terminal = terminal; self.webFetch = webFetch; self.screenshot = screenshot; self.accessibility = accessibility; self.browserOpen = browserOpen
    }

    public func createTask(title: String) async throws -> JarvisTask { try lock.withLock { let task = JarvisTask(title: title); try uow.createTask(task, audit: event(taskID: task.id, summary: "task created", result: "created")); return task } }
    public func getTask(id: UUID) async throws -> JarvisTask? { try lock.withLock { try tasks.fetch(id: id) } }
    public func listTasks() async throws -> [JarvisTask] { try lock.withLock { try tasks.list() } }

    public func listPendingApprovalRequests(taskID: UUID) async throws -> [PendingApprovalRequest] {
        try lock.withLock {
            guard try tasks.fetch(id: taskID) != nil else { throw TaskServiceError.taskNotFound }
            let pending = try requests.list(status: .pending).filter { $0.0.taskID == taskID }
            return try pending.map { request, _ in
                let reason = (try? audits.events(for: taskID).reversed().first(where: {
                    $0.actionDigest == request.payloadDigest && $0.summary == "policy requires approval"
                })?.result) ?? "Approval requested by policy"
                let redactedPayload = redactSecrets(request.payload)
                let target: String
                if request.name == "browser_open", let ticket = BrowserURLTicketStore.Ticket(payload: request.payload) {
                    if let generation = exactBrowserGate.capture() {
                        target = (try? exactBrowserGate.withCurrentGeneration(generation) { browserTickets.peekBound(ticket, taskID: request.taskID, requestID: request.id) }) ?? "[目标已失效，请拒绝此请求后重新请求]"
                    } else { target = "[目标已失效，请拒绝此请求后重新请求]" }
                } else { target = request.target }
                return PendingApprovalRequest(id: request.id, taskID: request.taskID, reason: reason,
                    target: target, payload: redactedPayload == request.payload ? redactedPayload : "[REDACTED]", digest: request.payloadDigest)
            }
        }
    }

    public func listTimelineEvents(taskID: UUID) async throws -> [TimelineEvent] {
        try lock.withLock {
            let fallback = browserUnknownEvents.values.filter { $0.taskID == taskID }.map(\.event)
            do {
                guard try tasks.fetch(id: taskID) != nil else { throw TaskServiceError.taskNotFound }
                let persisted = try audits.events(for: taskID).map { event in
                    TimelineEvent(id: event.id, timestamp: event.timestamp, worker: event.worker,
                        target: redactSecrets(event.target), sideEffect: event.sideEffect,
                        actionDigest: event.actionDigest, summary: event.summary, result: event.result,
                        approvalID: event.approvalID, requestID: event.requestID)
                }
                return persisted + fallback
            } catch {
                if !fallback.isEmpty { return fallback }
                throw error
            }
        }
    }

    public func isExactBrowserEnabled() -> Bool { exactBrowserGate.capture() != nil }
    public func setExactBrowserEnabled(_ enabled: Bool) throws {
        guard !enabled || exactBrowserAllowed else { throw TaskServiceCapabilityError.unavailable }
        exactBrowserGate.setEnabled(enabled) { if !enabled { browserTickets.revokeAll() } }
    }

    public func submitDemoApproval(taskID: UUID) async throws {
        guard let directory = config.approvedDirectories.first else { throw TaskServiceError.incompatiblePersistence }
        let target = URL(fileURLWithPath: directory).appendingPathComponent("Jarvis demo draft.txt").path
        let request = ToolRequest(taskID: taskID, name: "demo_write", sideEffect: .localWrite,
            target: target, payload: "Create a local demo draft")
        _ = try await submit(request: request)
    }

    public func submit(request: ToolRequest) async throws -> PolicyDecision {
        try lock.withLock { try ensureRunning(request.taskID) }
        if request.name == "browser_open", BrowserOpenURL.validated(request.target) == nil,
           BrowserOpenURL.validatedExact(request.target) != nil {
            guard let exactGeneration = exactBrowserGate.capture() else {
                let reason = "invalid browser destination"
                try lock.withLock {
                    try requireRunning(request.taskID)
                    let task = try requiredTask(request.taskID)
                    try uow.transition(taskID: task.id, from: task.status, to: .blocked, audits: [event(request, summary: "tool request received", result: "received"), event(request, summary: "policy denied", result: reason)])
                }
                return .deny(reason: reason)
            }
            guard request.sideEffect == .externalSend, request.payload == "Open in browser", request.scope == nil else { throw BrowserURLTicketError.invalidRequest }
            guard let policy = policy as? Policy,
                  case .requireApproval(let reason) = policy.evaluateExactBrowserDestination(request) else {
                throw BrowserURLTicketError.invalidRequest
            }
            return try exactBrowserGate.withCurrentGeneration(exactGeneration) {
            guard try lock.withLock({ try hasExactBrowserCapacityLocked() }) else { throw BrowserOpenError.exactCapacityReached }
            let ticket = browserTickets.issue(url: request.target)
            do {
                let stored = try browserTickets.persistableRequest(request, ticket: ticket)
                guard browserTickets.bind(ticket, taskID: request.taskID, requestID: request.id) else { throw BrowserURLTicketError.invalidRequest }
                try lock.withLock {
                    try requireRunning(request.taskID)
                    try uow.submitRequest(stored, status: .pending, taskStatus: .awaitingApproval, audits: [event(stored, summary: "tool request received", result: "received"), event(stored, summary: "policy requires approval", result: reason)])
                }
                return .requireApproval(reason: reason)
            } catch { browserTickets.revoke(id: ticket.id); throw error }
            }
        }
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
        let preliminary = try lock.withLock { () throws -> ToolRequest in
            guard let (request, status) = try requests.fetch(id: requestID), status == .pending else { throw TaskServiceError.requestNotAwaitingApproval }
            return request
        }
        let exactGeneration = BrowserURLTicketStore.Ticket(payload: preliminary.payload) != nil && preliminary.name == "browser_open" ? exactBrowserGate.capture() : nil
        if preliminary.name == "browser_open", BrowserURLTicketStore.Ticket(payload: preliminary.payload) != nil, exactGeneration == nil { throw TaskServiceCapabilityError.unavailable }
        let commitApproval = { [self] in try lock.withLock { () throws -> (ToolRequest, ToolRequest?) in
            guard let (request, status) = try requests.fetch(id: requestID), status == .pending else { throw TaskServiceError.requestNotAwaitingApproval }
            guard validateApproval(request: request, approvalDigest: digest) else { try audits.append(event(request, summary: "approval rejected", result: "digest mismatch")); throw TaskServiceError.approvalDigestMismatch }
            var transient: ToolRequest?
            if request.name == "browser_open", let ticket = BrowserURLTicketStore.Ticket(payload: request.payload) {
                guard let target = browserTickets.consumeBound(ticket, taskID: request.taskID, requestID: request.id),
                      BrowserOpenURL.validatedExact(target) != nil else { throw TaskServiceError.requestNotAwaitingApproval }
                transient = ToolRequest(id: request.id, taskID: request.taskID, name: request.name, sideEffect: request.sideEffect, target: target, payload: "Open in browser")
            }
            let approval = Approval(toolRequestID: request.id, actionDigest: request.payloadDigest, decision: .approved)
            let taskStatus = try aggregateStatus(forTask: request.taskID, excluding: request.id, fallback: .running)
            try uow.approveRequest(request, approval: approval, taskStatus: taskStatus, audits: [event(request, summary: "approval accepted", result: "approved", approvalID: approval.id)])
            return (request, transient)
        } }
        let pair = try exactGeneration.map { try exactBrowserGate.withCurrentGeneration($0, commitApproval) } ?? commitApproval()
        startExecution(pair.0, executionRequest: pair.1, exactGeneration: exactGeneration)
    }

    public func reject(requestID: UUID) async throws {
        try lock.withLock {
            guard let (request, status) = try requests.fetch(id: requestID), status == .pending else { throw TaskServiceError.requestNotAwaitingApproval }
            let approval = Approval(toolRequestID: request.id, actionDigest: request.payloadDigest, decision: .rejected)
            let taskStatus = try aggregateStatus(forTask: request.taskID, excluding: request.id, fallback: .blocked)
            try uow.rejectRequest(request, approval: approval, taskStatus: taskStatus, audits: [event(request, summary: "approval rejected", result: "rejected", approvalID: approval.id)])
            if let ticket = BrowserURLTicketStore.Ticket(payload: request.payload), request.name == "browser_open" { browserTickets.revoke(id: ticket.id) }
        }
    }

    public func cancel(taskID: UUID) async throws {
        try lock.withLock {
            let task = try requiredTask(taskID)
            if task.status == .cancelled || task.status == .completed || task.status == .failed {
                throw TaskServiceError.illegalTransition(from: task.status, to: .cancelled)
            }
            var uncertainBrowserRequests: [ToolRequest] = []
            for (requestID, job) in executions {
                if let (request, _) = try requests.fetch(id: requestID), request.taskID == taskID {
                    if request.name == "browser_open", BrowserURLTicketStore.Ticket(payload: request.payload) != nil {
                        // Conservatively treat any in-flight exact open as unknown on cancel,
                        // including the narrow window before the system call starts.
                        recordBrowserUnknownLocked(request)
                        uncertainBrowserRequests.append(request)
                    }
                    job.cancel()
                }
            }
            let pending = try requests.list(status: .pending).filter { $0.0.taskID == taskID }
            var cancelAudits = [event(taskID: taskID, summary: "task cancelled", result: "cancelled")]
            cancelAudits += uncertainBrowserRequests.map { event($0, summary: "browser open outcome unknown", result: BrowserOpenError.outcomeUnknown.errorDescription ?? "Browser open outcome unknown") }
            try uow.cancelTask(taskID: taskID, requestIDs: [], audits: cancelAudits)
            for (request, _) in pending where request.name == "browser_open" {
                if let ticket = BrowserURLTicketStore.Ticket(payload: request.payload) { browserTickets.revoke(id: ticket.id) }
            }
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
            try uow.transition(
                taskID: task.id,
                from: task.status,
                to: .completed,
                audits: [event(taskID: task.id, summary: "task completed", result: "completed")]
            )
        }
    }

    private func startExecution(_ request: ToolRequest, executionRequest: ToolRequest? = nil, exactGeneration: UInt64? = nil) {
        let gate = ExecutionGate()
        let job: Task<Void, Error> = Task { [weak self] in
            await gate.wait()
            defer { self?.removeExecution(request.id) }
            guard let self else { return }
            try await self.execute(request, executionRequest: executionRequest, exactGeneration: exactGeneration)
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
    // The stored request is authoritative for status and audit.  A separate
    // transient request may be supplied to the executor after approval.
    private func execute(_ request: ToolRequest, executionRequest: ToolRequest? = nil, exactGeneration: UInt64? = nil) async throws {
        var exactOpenReturned = false
        do {
            if let executionRequest {
                guard executionRequest.id == request.id,
                      executionRequest.taskID == request.taskID,
                      executionRequest.name == request.name,
                      executionRequest.sideEffect == request.sideEffect else {
                    throw TaskServiceError.approvalDigestMismatch
                }
            }
            try lock.withLock { guard let (_, status) = try requests.fetch(id: request.id), status == .executing else { throw TaskServiceError.requestNotAwaitingApproval }; try requireRunning(request.taskID) }
            if request.name == "browser_open" && browserOpen == nil { throw BrowserOpenError.unavailable }
            let picked: any ToolExecutor = {
                if request.name == "browser_open", let browserOpen = self.browserOpen { return browserOpen }
                if request.name == "shell", let terminal = self.terminal { return terminal }
                if request.name == "fetch", let webFetch = self.webFetch { return webFetch }
                if request.name == "screenshot", let screenshot = self.screenshot { return screenshot }
                if request.name == "ax_query", let accessibility = self.accessibility { return accessibility }
                return executor
            }()
            let result: ToolResult
            if let executionRequest, let browserOpen, request.name == "browser_open",
               BrowserURLTicketStore.Ticket(payload: request.payload) != nil {
                guard let exactGeneration else { throw BrowserOpenError.unavailable }
                result = try await browserOpen.executeApprovedExact(executionRequest, gate: exactBrowserGate, generation: exactGeneration)
                exactOpenReturned = true
                #if JARVIS_SAFARI_CLICK_TESTING
                await testAfterExactBrowserOpen()
                #endif
            } else {
                result = try await picked.execute(executionRequest ?? request)
            }
            try lock.withLock {
                guard let task = try tasks.fetch(id: request.taskID), task.status != .cancelled else { return }
                let taskStatus = try aggregateStatus(forTask: request.taskID, excluding: request.id, fallback: .running)
                try uow.finishRequest(request, status: .completed, taskStatus: taskStatus, audits: [event(request, summary: "tool result", result: bounded(result.summary))])
            }
        } catch is CancellationError {
            // Cancellation transaction already sets request and task to cancelled; never add success/failure after it.
        } catch {
            let browserOutcomeUnknown: Bool
            if case BrowserOpenError.outcomeUnknown = error { browserOutcomeUnknown = true } else { browserOutcomeUnknown = exactOpenReturned }
            if browserOutcomeUnknown { lock.withLock { recordBrowserUnknownLocked(request) } }
            let fallback: TaskStatus = .failed
            let aggregate: TaskStatus = (try? aggregateStatus(forTask: request.taskID, excluding: request.id, fallback: fallback)) ?? fallback
            try lock.withLock {
                guard let task = try tasks.fetch(id: request.taskID) else { return }
                let safeFailure = browserOutcomeUnknown ? (BrowserOpenError.outcomeUnknown.errorDescription ?? "Browser open outcome unknown") : "failed"
                if task.status == .cancelled {
                    if browserOutcomeUnknown { try audits.append(event(request, summary: "browser open outcome unknown", result: safeFailure)) }
                    return
                }
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
    private func event(_ request: ToolRequest, summary: String, result: String, approvalID: UUID? = nil) -> AuditEvent { event(taskID: request.taskID, sideEffect: request.sideEffect, digest: request.payloadDigest, summary: summary, result: result, approvalID: approvalID, target: request.name == "browser_open" ? Self.browserAuditTarget(request.target) : request.target, requestID: request.id) }
    private static func browserAuditTarget(_ target: String) -> String {
        guard let parts = URLComponents(string: target), parts.scheme == "https", let host = parts.host else { return "[REDACTED]" }
        return "https://\(host)" + (parts.port.map { ":\($0)" } ?? "")
    }
    private func event(taskID: UUID, sideEffect: SideEffect = .read, digest: String = "", summary: String, result: String, approvalID: UUID? = nil, target: String = "local task service", requestID: UUID? = nil) -> AuditEvent { AuditEvent(taskID: taskID, worker: "task-service", target: target, sideEffect: sideEffect, actionDigest: digest, summary: summary, result: result, approvalID: approvalID, requestID: requestID) }
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
