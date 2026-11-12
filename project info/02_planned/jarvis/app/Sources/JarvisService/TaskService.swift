import Foundation
#if os(macOS)
import ApplicationServices
#endif
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
    private let safariToggleAllowed: Bool
    private let safariGate: SafariReadGate
    private let safariCoordinator: SafariReadCoordinator
    var safariCaptureFactory: @Sendable () -> any SafariTargetCapturing = { SafariAXTargetCapture() }
    private let ephemeralResults = EphemeralToolResultStore()
    private let browserTickets: BrowserURLTicketStore
    var testBrowserTicketCount: Int { browserTickets.testEntryCount }
    #if os(macOS)
    private var clickExperiment: ExperimentalClickCoordinator?
    #if JARVIS_SAFARI_CLICK_EXPERIMENT
    private var systemClickAuthorization: ExperimentalSystemAuthorizationState?
    private var clickModeTransition = false
    #if JARVIS_SAFARI_EXPERIMENT_BUILD || JARVIS_COMBINED_EXPERIMENT
    private var clickTargetSelector: @Sendable (String, String, @escaping @Sendable () -> Bool) async throws -> (SafariClickIdentity, SafariClickCapture) = { role, title, authorization in
        try await SafariClickTargetSelection.select(role: role, title: title, authorization: authorization)
    }
    #endif
    #if JARVIS_SAFARI_CLICK_TESTING
    private var clickBeforeCommit: @Sendable () async -> Void = {}
    #endif
    #endif
    private var clickAfterSubmit: @Sendable () async -> Void = {}
    #endif
    private let lock = NSLock()
    private var executions: [UUID: Task<Void, Error>] = [:]

    public init(taskRepository: any TaskRepository, auditRepository: any AuditRepository, policy: any PolicyEvaluator, policyConfig: PolicyConfig = .init(), executor: any ToolExecutor = NoOpToolExecutor(), terminal: TerminalToolExecutor? = nil, webFetch: WebFetchToolExecutor? = nil, screenshot: ScreenshotToolExecutor? = nil, accessibility: AccessibilityQueryToolExecutor? = nil, browserOpen: BrowserOpenExecutor? = nil, enableSafariRead: Bool = false, requestRepository: (any ToolRequestRepository)? = nil, approvalRepository: (any ApprovalRepository)? = nil, unitOfWork: (any PersistenceUnitOfWork)? = nil, exactBrowserEnabled: Bool = false, browserTicketLifetime: TimeInterval = 300, allowSafariReadToggle: Bool = false, allowExactBrowserToggle: Bool = false) throws {
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
        let safariGate = SafariReadGate()
        #if JARVIS_SAFARI_EXPERIMENT_BUILD || JARVIS_COMBINED_EXPERIMENT
        safariGate.setEnabled(enableSafariRead)
        self.safariToggleAllowed = enableSafariRead || allowSafariReadToggle
        #else
        // Ordinary builds never activate experimental Safari access, regardless of runtime arguments.
        self.safariToggleAllowed = false
        #endif
        self.safariGate = safariGate
        self.safariCoordinator = SafariReadCoordinator(gate: safariGate)
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
            if request.name == "safari_click_experiment" {
                #if os(macOS)
                let preview = await lock.withLock({ clickExperiment })?.preview(request)
                #else
                let preview: (url: String, role: String, title: String, enabled: Bool)? = nil
                #endif
                if let preview {
                    let payload = "元素类型：\(preview.role)\n元素标题：\(preview.title)\n状态：\(preview.enabled ? "已启用" : "未启用")\n风险：点击可能改变网页或触发操作；检查与点击非原子，动作开始后不可撤销。执行前会再次检查目标。完整网址可能包含敏感参数，请注意保护。"
                    output.append(PendingApprovalRequest(id: request.id, taskID: request.taskID, reason: reason, target: preview.url, payload: payload, digest: request.payloadDigest, kind: "safari_click_experiment", previewAvailable: true))
                } else {
                    output.append(PendingApprovalRequest(id: request.id, taskID: request.taskID, reason: reason, target: "实验点击", payload: "此实验请求的目标已失效或不可用，请拒绝此请求后重新发起。", digest: request.payloadDigest, kind: "safari_click_experiment", previewAvailable: false))
                }
            } else if request.name == "safari_read" {
                let exactURL = await safariCoordinator.preview(request) ?? "Capture expired; reject and try again."
                output.append(PendingApprovalRequest(id: request.id, taskID: request.taskID, reason: reason, target: exactURL, payload: "Read accessibility text from this captured Safari window", digest: request.payloadDigest))
            } else {
                let redactedPayload = redactSecrets(request.payload)
                let target: String
                if request.name == "browser_open", let ticket = BrowserURLTicketStore.Ticket(payload: request.payload) {
                    if let generation = exactBrowserGate.capture() {
                        target = (try? exactBrowserGate.withCurrentGeneration(generation) { browserTickets.peekBound(ticket, taskID: request.taskID, requestID: request.id) }) ?? "[目标已失效，请拒绝此请求后重新请求]"
                    } else { target = "[目标已失效，请拒绝此请求后重新请求]" }
                } else { target = request.target }
                output.append(PendingApprovalRequest(id: request.id, taskID: request.taskID, reason: reason, target: target, payload: redactedPayload == request.payload ? redactedPayload : "[REDACTED]", digest: request.payloadDigest))
            }
        }
        return output
    }

    public func isSafariReadAvailable() async -> Bool { safariGate.capture() != nil }

    public func isSafariReadEnabled() -> Bool { safariGate.capture() != nil }

    public func setSafariReadEnabled(_ enabled: Bool) throws {
        guard !enabled || safariToggleAllowed else { throw TaskServiceCapabilityError.unavailable }
        safariGate.setEnabled(enabled) { if !enabled { ephemeralResults.clearAll() } }
    }

    public func prepareSafariRead(taskID: UUID) async throws -> ToolRequest {
        guard safariGate.capture() != nil else { throw TaskServiceCapabilityError.unavailable }
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
        guard request.name != "safari_click_experiment" else { throw TaskServiceCapabilityError.unavailable }
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
        var decision = policy.evaluate(request, config: config)
        if request.name == "safari_read" {
            let preview = safariGate.capture() != nil ? await safariCoordinator.preview(request) : nil
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
            guard safariGate.capture() != nil, await safariCoordinator.preview(preliminary) != nil else { throw TaskServiceCapabilityError.unavailable }
        }
        let exactGeneration = BrowserURLTicketStore.Ticket(payload: preliminary.payload) != nil && preliminary.name == "browser_open" ? exactBrowserGate.capture() : nil
        if preliminary.name == "browser_open", BrowserURLTicketStore.Ticket(payload: preliminary.payload) != nil, exactGeneration == nil { throw TaskServiceCapabilityError.unavailable }
        let commitApproval = { [self] in try lock.withLock { () throws -> (ToolRequest, Approval, ToolRequest?) in
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
            return (request, approval, transient)
        } }
        let (request, approval, transient) = try exactGeneration.map { try exactBrowserGate.withCurrentGeneration($0, commitApproval) } ?? commitApproval()
        startExecution(request, approval: approval, executionRequest: transient, exactGeneration: exactGeneration)
    }

    public func reject(requestID: UUID) async throws {
        #if os(macOS)
        if let click = lock.withLock({ clickExperiment }) { await click.cancel(requestID: requestID) }
        #endif
        let rejected: ToolRequest = try lock.withLock {
            guard let (request, status) = try requests.fetch(id: requestID), status == .pending else { throw TaskServiceError.requestNotAwaitingApproval }
            let approval = Approval(toolRequestID: request.id, actionDigest: request.payloadDigest, decision: .rejected)
            let taskStatus = try aggregateStatus(forTask: request.taskID, excluding: request.id, fallback: .blocked)
            try uow.rejectRequest(request, approval: approval, taskStatus: taskStatus, audits: [event(request, summary: "approval rejected", result: "rejected", approvalID: approval.id)])
            if let ticket = BrowserURLTicketStore.Ticket(payload: request.payload), request.name == "browser_open" { browserTickets.revoke(id: ticket.id) }
            return request
        }
        if rejected.name == "safari_read" { await safariCoordinator.discard(rejected) }
    }

    public func cancel(taskID: UUID) async throws {
        #if os(macOS)
        let started = await lock.withLock({ clickExperiment })?.cancel(taskID: taskID) ?? []
        #else
        let started: [UUID] = []
        #endif
        try lock.withLock {
            let task = try requiredTask(taskID)
            if task.status == .cancelled || task.status == .completed || task.status == .failed {
                throw TaskServiceError.illegalTransition(from: task.status, to: .cancelled)
            }
            for (requestID, job) in executions {
                if let (request, _) = try requests.fetch(id: requestID), request.taskID == taskID { job.cancel() }
            }
            ephemeralResults.clear(taskID: taskID)
            let pending = try requests.list(status: .pending).filter { $0.0.taskID == taskID }
            var cancelAudits = [event(taskID: taskID, summary: "task cancelled", result: "cancelled")]
            cancelAudits += started.map { event(taskID: taskID, summary: "experimental click cancellation after start", result: "action outcome unknown; do not retry automatically", requestID: $0) }
            try uow.cancelTask(taskID: taskID, requestIDs: [], audits: cancelAudits)
            for (request, _) in pending where request.name == "browser_open" {
                if let ticket = BrowserURLTicketStore.Ticket(payload: request.payload) { browserTickets.revoke(id: ticket.id) }
            }
        }
        #if os(macOS)
        await lock.withLock({ clickExperiment })?.acknowledgeStarts(taskID: taskID, requestIDs: started)
        #endif
        await safariCoordinator.clear(taskID: taskID)
    }

    #if os(macOS)
    #if JARVIS_SAFARI_CLICK_EXPERIMENT
    /// Checks actual bundle metadata and permission; user opt-in must be provided by
    /// a future explicit UI. No production caller currently installs this capability.
    private static func experimentalSystemClickGate(bundleID: String?, marker: Any?, combinedMarker: Any? = nil, optedIn: Bool, trusted: Bool) -> Bool {
        guard let number = marker as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID(),
              number.boolValue, optedIn, trusted else { return false }
        #if JARVIS_COMBINED_EXPERIMENT
        guard bundleID == "local.jarvis.combined-experiment", let combined = combinedMarker as? NSNumber,
              CFGetTypeID(combined) == CFBooleanGetTypeID(), combined.boolValue else { return false }
        return true
        #elseif JARVIS_SAFARI_EXPERIMENT_BUILD
        return bundleID == "local.jarvis.safari-click-experiment"
        #else
        return false
        #endif
    }
    private func installExperimentalSystemClick(optedIn: @escaping @Sendable () -> Bool, systemAction: @escaping @Sendable (AXUIElement, CFString) -> AXError = { element, operation in
        AXUIElementPerformAction(element, operation)
    }) {
        let authorization: @Sendable () -> Bool = {
            Self.experimentalSystemClickGate(bundleID: Bundle.main.bundleIdentifier,
                marker: Bundle.main.object(forInfoDictionaryKey: "JarvisSafariClickExperiment"),
                combinedMarker: Bundle.main.object(forInfoDictionaryKey: "JarvisCombinedExperiment"),
                optedIn: optedIn(), trusted: AXIsProcessTrusted())
        }
        guard authorization() else { return }
        installExperimentalSystemClickCore(authorization: authorization, systemAction: systemAction)
    }
    private func installExperimentalSystemClickCore(authorization: @escaping @Sendable () -> Bool,
        beforeStart: @escaping @Sendable () -> Void = {}, beforeSystemCheck: @escaping @Sendable () -> Void = {}, systemAction: @escaping @Sendable (AXUIElement, CFString) -> AXError) {
        lock.withLock {
            guard clickExperiment == nil else { return }
            let state = ExperimentalSystemAuthorizationState(liveCheck: authorization)
            systemClickAuthorization = state
            clickExperiment = ExperimentalClickCoordinator(lifetime: 60, clock: { ProcessInfo.processInfo.systemUptime }, authorization: { state.isAllowed() }, beforeStart: beforeStart, authorizeStart: { state.beginIfAllowed($0) }) { element, operation in
                guard CFEqual(operation, kAXPressAction as CFString) else { return .failure }
                beforeSystemCheck()
                guard state.isAllowed() else { return .failure }
                return systemAction(element, kAXPressAction as CFString)
            }
        }
    }
    /// A future opt-in/permission observer must invoke this on every revocation.
    /// Synchronously prevents later action starts before crossing any actor boundary.
    private func revokeExperimentalSystemClickAuthorization() async throws -> Bool {
        let pair = lock.withLock { () -> (ExperimentalSystemAuthorizationState?, ExperimentalClickCoordinator?) in
            systemClickAuthorization?.revoke()
            return (systemClickAuthorization, clickExperiment)
        }
        guard pair.0 != nil, let click = pair.1 else { return false }
        let started = await click.revokeAll()
        do {
            for (taskID, requestIDs) in started {
                for requestID in requestIDs {
                    try lock.withLock { try audits.append(event(taskID: taskID, summary: "experimental click authorization revoked after start", result: "action outcome unknown; do not retry automatically", requestID: requestID)) }
                }
                await click.acknowledgeStarts(taskID: taskID, requestIDs: requestIDs)
            }
        } catch { throw SafariPressFailure.actionOutcomeUnknown }
        return !started.isEmpty
    }
    /// Only available in a deliberately compiled click experiment. Opening the
    /// settings view does not enable this; a user must explicitly request it.
    public var isExperimentalClickBarrierBlocking: Bool {
        lock.withLock {
            guard let sqlite = uow as? SQLitePersistenceUnitOfWork else { return true }
            return (try? sqlite.hasExperimentalClickBarrier()) ?? true
        }
    }
    public func enableExperimentalClickMode() throws {
        guard !isExperimentalClickBarrierBlocking else { throw ExperimentalClickBarrierError.unresolved }
        guard Self.experimentalSystemClickGate(bundleID: Bundle.main.bundleIdentifier,
            marker: Bundle.main.object(forInfoDictionaryKey: "JarvisSafariClickExperiment"),
            combinedMarker: Bundle.main.object(forInfoDictionaryKey: "JarvisCombinedExperiment"),
            optedIn: true, trusted: AXIsProcessTrusted()) else { throw TaskServiceCapabilityError.unavailable }
        try beginClickModeEnable()
        defer { lock.withLock { clickModeTransition = false } }
        installExperimentalSystemClick(optedIn: { true })
        guard lock.withLock({ systemClickAuthorization != nil }) else { throw TaskServiceCapabilityError.unavailable }
    }
    private func beginClickModeEnable() throws {
        try lock.withLock {
            guard !clickModeTransition, clickExperiment == nil, systemClickAuthorization == nil else { throw TaskServiceCapabilityError.unavailable }
            clickModeTransition = true
        }
    }
    /// Querying status also permanently revokes this generation if a live check fails.
    private func refreshClickAuthorizationLocked() -> ExperimentalSystemAuthorizationState? {
        guard let state = systemClickAuthorization else { return nil }
        if !state.isAllowed() { state.revoke() }
        return state
    }
    public var isExperimentalClickModeEnabled: Bool {
        lock.withLock { !clickModeTransition && !(refreshClickAuthorizationLocked()?.isRevoked ?? true) }
    }
    public var isExperimentalClickCleanupRequired: Bool {
        lock.withLock { !clickModeTransition && (refreshClickAuthorizationLocked()?.isRevoked ?? false) }
    }
    /// Revocation is synchronous with the switch action; database cleanup is awaited separately.
    public func disableExperimentalClickMode() -> Task<Bool, Error> {
        let accepted = lock.withLock { () -> Bool in
            guard !clickModeTransition else { return false }
            clickModeTransition = true
            systemClickAuthorization?.revoke()
            return true
        }
        guard accepted else { return Task { throw TaskServiceCapabilityError.unavailable } }
        return Task {
            defer { lock.withLock { clickModeTransition = false } }
            let alreadyStarted = try await revokeExperimentalSystemClickAuthorization()
            try lock.withLock {
                for (request, _) in try requests.list(status: .pending) where request.name == "safari_click_experiment" {
                    let rejection = Approval(toolRequestID: request.id, actionDigest: request.payloadDigest, decision: .rejected)
                    let status = try aggregateStatus(forTask: request.taskID, excluding: request.id, fallback: .running)
                    try uow.rejectRequest(request, approval: rejection, taskStatus: status,
                        audits: [event(request, summary: "experimental click mode disabled", result: "cancelled", approvalID: rejection.id)])
                }
                clickExperiment = nil
                systemClickAuthorization = nil
            }
            return alreadyStarted
        }
    }
    #if JARVIS_SAFARI_CLICK_TESTING
    #if JARVIS_SAFARI_EXPERIMENT_BUILD || JARVIS_COMBINED_EXPERIMENT
    func installExperimentalClickTargetSelectorForTesting(_ selector: @escaping @Sendable (String, String) async throws -> (SafariClickIdentity, SafariClickCapture)) {
        lock.withLock {
            clickTargetSelector = { role, title, authorization in
                guard authorization() else { throw TaskServiceCapabilityError.unavailable }
                let result = try await selector(role, title)
                guard authorization() else { throw TaskServiceCapabilityError.unavailable }
                return result
            }
        }
    }
    #endif
    func enableExperimentalClickModeForTesting(allowed: Bool, beforeCommit: @escaping @Sendable () async -> Void = {}, _ action: @escaping @Sendable (AXUIElement, CFString) -> AXError) throws {
        guard allowed else { throw TaskServiceCapabilityError.unavailable }
        try beginClickModeEnable()
        defer { lock.withLock { clickModeTransition = false } }
        installExperimentalSystemClickCore(authorization: { true }, systemAction: action)
        lock.withLock { clickBeforeCommit = beforeCommit }
    }
    func experimentalSystemClickAuthorizationRevokedForTesting() async throws -> Bool {
        try await revokeExperimentalSystemClickAuthorization()
    }
    /// Fake injection is only present when the explicit test macro is set.
    func installExperimentalSystemClickForTesting(authorization: @escaping @Sendable () -> Bool = { true },
        beforeStart: @escaping @Sendable () -> Void = {}, beforeSystemCheck: @escaping @Sendable () -> Void = {}, _ systemAction: @escaping @Sendable (AXUIElement, CFString) -> AXError) async {
        installExperimentalSystemClickCore(authorization: authorization, beforeStart: beforeStart, beforeSystemCheck: beforeSystemCheck, systemAction: systemAction)
    }
    static func experimentalSystemClickGateForTesting(bundleID: String?, marker: Any?, combinedMarker: Any? = nil, optedIn: Bool, trusted: Bool) -> Bool {
        experimentalSystemClickGate(bundleID: bundleID, marker: marker, combinedMarker: combinedMarker, optedIn: optedIn, trusted: trusted)
    }
    #endif
    #endif

    /// Explicitly injected laboratory path. Never installed by the application.
    func installExperimentalClickForTesting(lifetime: TimeInterval = 60, clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }, focusTimeout: Duration = .seconds(15), afterSubmit: @escaping @Sendable () async -> Void = {}, action: @escaping @Sendable (AXUIElement, CFString) -> AXError) async {
        lock.withLock { if clickExperiment == nil { clickExperiment = ExperimentalClickCoordinator(lifetime: lifetime, clock: clock, focusTimeout: focusTimeout, action: action); clickAfterSubmit = afterSubmit } }
    }

    #if JARVIS_SAFARI_CLICK_EXPERIMENT && (JARVIS_SAFARI_EXPERIMENT_BUILD || JARVIS_COMBINED_EXPERIMENT)
    /// Explicit user-selected role and title; PID, URL and window are captured internally.
    public func submitExperimentalSafariClick(taskID: UUID, role: String, title: String) async throws -> ToolRequest {
        guard !role.isEmpty, role.utf8.count <= 128, !title.isEmpty, title.utf8.count <= 512 else { throw TaskServiceCapabilityError.unavailable }
        let state = lock.withLock { (clickExperiment, clickTargetSelector, systemClickAuthorization, !clickModeTransition) }
        guard let click = state.0, let authorization = state.2, state.3, authorization.isAllowed() else { throw TaskServiceCapabilityError.unavailable }
        let (identity, capture) = try await state.1(role, title, { authorization.isAllowed() })
        guard authorization.isAllowed(), identity.role == role, identity.title == title, identity.enabled else { throw TaskServiceCapabilityError.unavailable }
        return try await submitExperimentalClick(taskID: taskID, identity: identity, capture: capture, coordinator: click)
    }
    #endif
    func submitExperimentalClick(taskID: UUID, identity: SafariClickIdentity, capture: SafariClickCapture) async throws -> ToolRequest {
        guard let click = lock.withLock({ clickExperiment }) else { throw TaskServiceCapabilityError.unavailable }
        return try await submitExperimentalClick(taskID: taskID, identity: identity, capture: capture, coordinator: click)
    }
    private func submitExperimentalClick(taskID: UUID, identity: SafariClickIdentity, capture: SafariClickCapture, coordinator click: ExperimentalClickCoordinator) async throws -> ToolRequest {
        guard lock.withLock({ clickExperiment === click }) else { throw TaskServiceCapabilityError.unavailable }
        try lock.withLock { try ensureRunning(taskID) }
        let request = try await click.prepare(taskID: taskID, identity: identity, capture: capture)
        #if JARVIS_SAFARI_CLICK_EXPERIMENT && JARVIS_SAFARI_CLICK_TESTING
        await lock.withLock { clickBeforeCommit }()
        #endif
        var submitted = false
        do {
            try Task.checkCancellation()
            try lock.withLock {
                try requireRunning(taskID)
                guard clickExperiment === click else { throw TaskServiceCapabilityError.unavailable }
                #if JARVIS_SAFARI_CLICK_EXPERIMENT
                if let state = systemClickAuthorization, !state.isAllowed() { throw TaskServiceCapabilityError.unavailable }
                #endif
                try uow.submitRequest(request, status: .pending, taskStatus: .awaitingApproval,
                    audits: [event(request, summary: "experimental click requested", result: "approval required")])
            }
            submitted = true
            await lock.withLock { clickAfterSubmit }()
            try Task.checkCancellation()
            return request
        } catch {
            await click.cancel(requestID: request.id)
            if submitted {
                try lock.withLock {
                    guard let (_, status) = try requests.fetch(id: request.id), status == .pending else { return }
                    let rejection = Approval(toolRequestID: request.id, actionDigest: request.payloadDigest, decision: .rejected)
                    let taskStatus = try aggregateStatus(forTask: request.taskID, excluding: request.id, fallback: .running)
                    try uow.rejectRequest(request, approval: rejection, taskStatus: taskStatus,
                        audits: [event(request, summary: "experimental click submission cancelled", result: "cancelled", approvalID: rejection.id)])
                }
            }
            throw error
        }
    }

    func approveExperimentalClick(requestID: UUID, digest: String) async throws {
        guard let click = lock.withLock({ clickExperiment }) else { throw TaskServiceCapabilityError.unavailable }
        let preliminary = try lock.withLock { () throws -> ToolRequest in
            guard let (request, status) = try requests.fetch(id: requestID), status == .pending,
                  request.name == "safari_click_experiment" else { throw TaskServiceError.requestNotAwaitingApproval }
            return request
        }
        guard await click.preview(preliminary) != nil else {
            await click.cancel(requestID: requestID)
            throw TaskServiceCapabilityError.unavailable
        }
        let request: ToolRequest
        do {
            try Task.checkCancellation()
            request = try lock.withLock {
                guard let (request, status) = try requests.fetch(id: requestID), status == .pending else { throw TaskServiceError.requestNotAwaitingApproval }
                guard clickExperiment === click else { throw TaskServiceCapabilityError.unavailable }
                #if JARVIS_SAFARI_CLICK_EXPERIMENT
                if let state = systemClickAuthorization, !state.isAllowed() { throw TaskServiceCapabilityError.unavailable }
                #endif
                guard validateApproval(request: request, approvalDigest: digest) else { throw TaskServiceError.approvalDigestMismatch }
                let approval = Approval(toolRequestID: request.id, actionDigest: request.payloadDigest, decision: .approved)
                let taskStatus = try aggregateStatus(forTask: request.taskID, excluding: request.id, fallback: .running)
                guard let sqlite = uow as? SQLitePersistenceUnitOfWork else { throw TaskServiceError.incompatiblePersistence }
                try sqlite.approveExperimentalClick(request, approval: approval, taskStatus: taskStatus,
                    audits: [event(request, summary: "experimental click approved", result: "approved", approvalID: approval.id)])
                return request
            }
        } catch { await click.cancel(requestID: requestID); throw error }
        var actionCompleted = false
        do {
            try Task.checkCancellation()
            try await click.perform(request)
            actionCompleted = true
            try lock.withLock {
                guard let task = try tasks.fetch(id: request.taskID), task.status != .cancelled else { return }
                let status = try aggregateStatus(forTask: request.taskID, excluding: request.id, fallback: .running)
                guard let sqlite = uow as? SQLitePersistenceUnitOfWork else { throw TaskServiceError.incompatiblePersistence }
                try sqlite.finishExperimentalClickCompleted(request, taskStatus: status, audits: [event(request, summary: "experimental click completed", result: "completed")])
            }
            await click.cancel(requestID: requestID)
            await click.acknowledgeStarts(taskID: request.taskID, requestIDs: [requestID])
        } catch {
            await click.cancel(requestID: requestID)
            let recorded = (try? lock.withLock { () throws -> Bool in
                guard let task = try tasks.fetch(id: request.taskID), task.status != .cancelled else { return false }
                let result: String
                if actionCompleted { result = "action outcome unknown; do not retry automatically" }
                else if let failure = error as? SafariPressFailure, case .actionOutcomeUnknown = failure { result = "action outcome unknown; do not retry automatically" }
                else { result = "action not completed" }
                let audit = event(request, summary: "experimental click failed", result: result)
                let confirmedNotStarted: Bool
                if !actionCompleted, let failure = error as? SafariPressFailure {
                    switch failure {
                    case .timeoutBeforeStart, .beforeStartRejected: confirmedNotStarted = true
                    case .actionOutcomeUnknown: confirmedNotStarted = false
                    }
                } else { confirmedNotStarted = !actionCompleted && error is ConfirmedClickPreflightFailure }
                if confirmedNotStarted, let sqlite = uow as? SQLitePersistenceUnitOfWork {
                    try sqlite.finishExperimentalClickNotStarted(request, taskStatus: .failed, audits: [audit])
                } else {
                    try uow.finishRequest(request, status: .failed, taskStatus: .failed, audits: [audit])
                }
                return true
            }) ?? false
            if recorded { await click.acknowledgeStarts(taskID: request.taskID, requestIDs: [requestID]) }
            if actionCompleted { throw SafariPressFailure.actionOutcomeUnknown }
            if let preflight = error as? ConfirmedClickPreflightFailure { throw preflight.underlying }
            throw error
        }
    }
    #endif

    public func takeEphemeralToolResult(taskID: UUID, requestID: UUID, digest: String) async throws -> String? {
        guard let generation = safariGate.capture() else { return nil }
        return try safariGate.withCurrentGeneration(generation) {
            try lock.withLock {
                guard let (request, status) = try requests.fetch(id: requestID), request.taskID == taskID,
                      request.name == "safari_read", request.payloadDigest == digest, status == .completed else { return nil }
                return ephemeralResults.take(taskID: taskID, requestID: requestID, digest: digest)
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
        #if os(macOS)
        if let click = lock.withLock({ clickExperiment }) { await click.cancel(taskID: taskID) }
        #endif
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

    private func startExecution(_ request: ToolRequest, approval: Approval, executionRequest: ToolRequest? = nil, exactGeneration: UInt64? = nil) {
        let gate = ExecutionGate()
        let job: Task<Void, Error> = Task { [weak self] in
            await gate.wait()
            defer { self?.removeExecution(request.id) }
            guard let self else { return }
            try await self.execute(request, approval: approval, executionRequest: executionRequest, exactGeneration: exactGeneration)
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
    static func validateExecutionCapability(_ request: ToolRequest) throws {
        guard request.name != "safari_click_experiment" else { throw TaskServiceCapabilityError.unavailable }
    }

    private func execute(_ request: ToolRequest, approval: Approval? = nil, executionRequest: ToolRequest? = nil, exactGeneration: UInt64? = nil) async throws {
        do {
            if let executionRequest {
                guard executionRequest.id == request.id,
                      executionRequest.taskID == request.taskID,
                      executionRequest.name == request.name,
                      executionRequest.sideEffect == request.sideEffect else {
                    throw TaskServiceError.approvalDigestMismatch
                }
            }
            try Self.validateExecutionCapability(request)
            try lock.withLock { guard let (_, status) = try requests.fetch(id: request.id), status == .executing else { throw TaskServiceError.requestNotAwaitingApproval }; try requireRunning(request.taskID) }
            if request.name == "safari_read" && (safariGate.capture() == nil || approval == nil) { throw SafariAXReadError.unavailable }
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
            var safariGeneration: UInt64?
            if request.name == "safari_read" {
                guard let approval else { throw SafariAXReadError.unavailable }
                let read = try await safariCoordinator.readApprovedWithGeneration(request, approval: approval)
                guard let generation = read.generation else { throw SafariReadCoordinatorError.unavailable }
                safariGeneration = generation
                result = ToolResult(summary: read.text)
            } else if let executionRequest, let browserOpen, request.name == "browser_open",
                      BrowserURLTicketStore.Ticket(payload: request.payload) != nil {
                guard let exactGeneration else { throw BrowserOpenError.unavailable }
                result = try await browserOpen.executeApprovedExact(executionRequest, gate: exactBrowserGate, generation: exactGeneration)
            } else {
                result = try await picked.execute(executionRequest ?? request)
            }
            let publish = { [self] in try lock.withLock {
                guard let task = try tasks.fetch(id: request.taskID), task.status != .cancelled else { return }
                let taskStatus = try aggregateStatus(forTask: request.taskID, excluding: request.id, fallback: .running)
                let auditResult = request.name == "safari_read" ? request.id.uuidString : bounded(result.summary)
                let summary = request.name == "safari_read" ? "ephemeral tool result" : "tool result"
                try uow.finishRequest(request, status: .completed, taskStatus: taskStatus, audits: [event(request, summary: summary, result: auditResult)])
                if request.name == "safari_read" {
                    ephemeralResults.put(result.summary, taskID: request.taskID, requestID: request.id, digest: request.payloadDigest)
                }
            } }
            if let safariGeneration { try safariGate.withCurrentGeneration(safariGeneration, publish) }
            else { try publish() }
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
    private func event(_ request: ToolRequest, summary: String, result: String, approvalID: UUID? = nil) -> AuditEvent { event(taskID: request.taskID, sideEffect: request.sideEffect, digest: request.payloadDigest, summary: summary, result: result, approvalID: approvalID, requestID: request.id, target: (request.name == "browser_open" || request.name == "safari_read") ? Self.browserAuditTarget(request.target) : request.target) }
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

#if os(macOS)
/// Constructed only at the preflight boundary after the exact gate proves
/// pending -> revoked (or was already irrevocably revoked before start).
private struct ConfirmedClickPreflightFailure: Error {
    let underlying: any Error
}

private actor ExperimentalClickCoordinator {
    private struct Entry { let taskID: UUID; let token: UUID; let targetDigest: String; let identity: SafariClickIdentity; let digest: String }
    private let staged: SafariClickStagedCaptures
    private let action: @Sendable (AXUIElement, CFString) -> AXError
    private let authorization: @Sendable () -> Bool
    private let focusTimeout: Duration
    private let beforeStart: @Sendable () -> Void
    private let authorizeStart: @Sendable (@Sendable () -> Bool) -> Bool
    private var entries: [UUID: Entry] = [:]
    private var generation: [UUID: UInt64] = [:]
    private var preparing = 0
    private var preparingTasks: [UUID: Int] = [:]
    private var inFlight: Set<UUID> = []
    private var unrecordedStarts: [UUID: Set<UUID>] = [:]
    private var cancelling: [UUID: (Task<SafariClickCancellationResult, Never>, UUID)] = [:]
    init(lifetime: TimeInterval, clock: @escaping @Sendable () -> TimeInterval, focusTimeout: Duration = .seconds(15), authorization: @escaping @Sendable () -> Bool = { true }, beforeStart: @escaping @Sendable () -> Void = {}, authorizeStart: @escaping @Sendable (@Sendable () -> Bool) -> Bool = { $0() }, action: @escaping @Sendable (AXUIElement, CFString) -> AXError) {
        self.staged = SafariClickStagedCaptures(bindings: SafariClickBindingStore(lifetime: lifetime, clock: clock))
        self.authorization = authorization
        self.focusTimeout = focusTimeout
        self.beforeStart = beforeStart
        self.authorizeStart = authorizeStart
        self.action = action
    }
    func prepare(taskID: UUID, identity: SafariClickIdentity, capture: SafariClickCapture) async throws -> ToolRequest {
        guard authorization(), entries.count + preparing < 32 else { throw TaskServiceCapabilityError.unavailable }
        preparing += 1
        preparingTasks[taskID, default: 0] += 1
        defer {
            preparing -= 1
            let count = preparingTasks[taskID, default: 0]
            if count <= 1 { preparingTasks.removeValue(forKey: taskID) } else { preparingTasks[taskID] = count - 1 }
        }
        let current = generation[taskID, default: 0], target = UUID().uuidString
        guard let token = try await staged.stage(taskID: taskID, identity: identity, targetDigest: target, capture: capture) else { throw TaskServiceCapabilityError.unavailable }
        let request = ToolRequest(taskID: taskID, name: "safari_click_experiment", sideEffect: .localWrite, target: "redacted Safari target", payload: token.uuidString)
        let bound = await staged.bind(token: token, taskID: taskID, requestID: request.id, digest: request.payloadDigest)
        guard bound, authorization(), !Task.isCancelled, generation[taskID, default: 0] == current else { await staged.cancel(token: token); throw TaskServiceCapabilityError.unavailable }
        entries[request.id] = Entry(taskID: taskID, token: token, targetDigest: target, identity: identity, digest: request.payloadDigest)
        Task { [weak self] in await self?.expire(requestID: request.id, token: token) }
        return request
    }
    private func expire(requestID: UUID, token: UUID) async {
        while entries[requestID] != nil && !inFlight.contains(requestID) {
            let remaining = await staged.remaining(token: token)
            guard entries[requestID] != nil, !inFlight.contains(requestID) else { return }
            guard let remaining else { await cancel(requestID: requestID); return }
            do { try await Task.sleep(for: .seconds(remaining)) } catch { await cancel(requestID: requestID); return }
        }
    }
    func preview(_ request: ToolRequest) async -> (url: String, role: String, title: String, enabled: Bool)? {
        guard authorization() else { await cancel(requestID: request.id); return nil }
        guard let entry = entries[request.id], entry.taskID == request.taskID,
              entry.digest == request.payloadDigest, request.payload == entry.token.uuidString,
              !inFlight.contains(request.id) else { return nil }
        let remaining = await staged.remaining(token: entry.token)
        guard authorization() else { await cancel(requestID: request.id); return nil }
        guard remaining != nil, !Task.isCancelled, let current = entries[request.id],
              current.token == entry.token, current.digest == request.payloadDigest,
              current.taskID == request.taskID, !inFlight.contains(request.id) else { return nil }
        let url = entry.identity.url, role = entry.identity.role, title = entry.identity.title
        guard url.utf8.count <= 2048, role.utf8.count <= 128, title.utf8.count <= 512,
              let parts = URLComponents(string: url), let scheme = parts.scheme?.lowercased(),
              ["http", "https"].contains(scheme), let host = parts.host, !host.isEmpty else { return nil }
        func display(_ value: String) -> String {
            value.unicodeScalars.map { scalar in
                let category = scalar.properties.generalCategory
                if category == .control || category == .format {
                    return String(format: "\\u{%04X}", scalar.value)
                }
                return scalar.value == 92 ? "\\\\" : String(scalar)
            }.joined()
        }
        return (display(url), display(role), display(title), entry.identity.enabled)
    }
    func perform(_ request: ToolRequest) async throws {
        guard authorization() else { await cancel(requestID: request.id); throw TaskServiceCapabilityError.unavailable }
        guard let e = entries[request.id], e.taskID == request.taskID, e.digest == request.payloadDigest,
              inFlight.insert(request.id).inserted else { throw TaskServiceCapabilityError.unavailable }
        defer { inFlight.remove(request.id) }
        guard let transfer = await staged.consume(token: e.token, taskID: e.taskID, requestID: request.id, digest: e.digest, targetDigest: e.targetDigest) else { throw TaskServiceCapabilityError.unavailable }
        let focusDeadline = ContinuousClock.now.advanced(by: focusTimeout)
        do {
            while true {
                try Task.checkCancellation()
                guard authorization() else { throw TaskServiceCapabilityError.unavailable }
                do { try await transfer.verify(expected: e.identity); break }
                catch SafariAXReadError.notFocused {
                    guard ContinuousClock.now < focusDeadline else { throw SafariAXReadError.focusTimedOut }
                    try await Task.sleep(for: .milliseconds(250))
                }
            }
        } catch {
            if let failure = error as? SafariPressFailure, case .actionOutcomeUnknown = failure { throw error }
            if await transfer.revokeProvingNotStarted() { throw ConfirmedClickPreflightFailure(underlying: error) }
            // A missing/started proof is never downgraded to a pre-start error.
            throw SafariPressFailure.actionOutcomeUnknown
        }
        try await transfer.perform(expected: e.identity, beforeAction: beforeStart, authorizeStart: authorizeStart, action: action)
    }
    @discardableResult func cancel(requestID: UUID) async -> SafariClickCancellationResult {
        let item: (Task<SafariClickCancellationResult, Never>, UUID)
        if let existing = cancelling[requestID] { item = existing }
        else {
            guard let entry = entries.removeValue(forKey: requestID) else { return .idle }
            let staged = self.staged
            item = (Task { await staged.cancel(token: entry.token) }, entry.taskID)
            cancelling[requestID] = item
        }
        let result = await item.0.value
        if case .alreadyStarted = result { unrecordedStarts[item.1, default: []].insert(requestID) }
        cancelling.removeValue(forKey: requestID)
        return result
    }
    @discardableResult func cancel(taskID: UUID) async -> [UUID] {
        generation[taskID, default: 0] &+= 1
        let ids = Set(entries.filter { $0.value.taskID == taskID }.map(\.key))
            .union(cancelling.filter { $0.value.1 == taskID }.map(\.key))
        for id in ids { await cancel(requestID: id) }
        return Array(unrecordedStarts[taskID, default: []])
    }
    func revokeAll() async -> [(UUID, [UUID])] {
        let taskIDs = Set(entries.values.map(\.taskID))
            .union(cancelling.values.map { $0.1 })
            .union(preparingTasks.keys)
            .union(unrecordedStarts.keys)
        var started: [(UUID, [UUID])] = []
        for taskID in taskIDs {
            let ids = await cancel(taskID: taskID)
            if !ids.isEmpty { started.append((taskID, ids)) }
        }
        return started
    }
    func acknowledgeStarts(taskID: UUID, requestIDs: [UUID]) {
        unrecordedStarts[taskID]?.subtract(requestIDs)
        if unrecordedStarts[taskID]?.isEmpty == true { unrecordedStarts.removeValue(forKey: taskID) }
    }
}
#endif

#if os(macOS) && JARVIS_SAFARI_CLICK_EXPERIMENT
private final class ExperimentalSystemAuthorizationState: @unchecked Sendable {
    private let lock = NSLock()
    private var revoked = false
    private let liveCheck: @Sendable () -> Bool
    init(liveCheck: @escaping @Sendable () -> Bool) { self.liveCheck = liveCheck }
    var isRevoked: Bool { lock.withLock { revoked } }
    func revoke() { lock.withLock { revoked = true } }
    func beginIfAllowed(_ start: @Sendable () -> Bool) -> Bool {
        guard liveCheck() else { revoke(); return false }
        return lock.withLock { !revoked && start() }
    }
    func isAllowed() -> Bool {
        guard lock.withLock({ !revoked }) else { return false }
        guard liveCheck() else { revoke(); return false }
        return lock.withLock { !revoked }
    }
}
#endif
