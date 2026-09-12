import Foundation
import JarvisDomain
import JarvisPersistence
import JarvisPolicy

public struct ToolResult: Codable, Equatable, Sendable { public let summary: String; public init(summary: String) { self.summary = summary } }
public protocol ToolExecutor: Sendable { func execute(_ request: ToolRequest) async throws -> ToolResult }
public struct NoOpToolExecutor: ToolExecutor { public init() {} ; public func execute(_ request: ToolRequest) async throws -> ToolResult { ToolResult(summary: "demo executor completed") } }
public enum TaskServiceError: Error, Equatable, Sendable { case taskNotFound, requestNotFound, requestNotAwaitingApproval, approvalDigestMismatch, illegalTransition(from: TaskStatus, to: TaskStatus), cancelled }

public final class TaskService: TaskServiceAPI, @unchecked Sendable {
    private let tasks: any TaskRepository; private let audits: any AuditRepository; private let requests: any ToolRequestRepository; private let uow: any PersistenceUnitOfWork; private let policy: any PolicyEvaluator; private let config: PolicyConfig; private let executor: any ToolExecutor; private let lock = NSLock(); private var running: [UUID: Swift.Task<Void, Never>] = [:]
    public init(taskRepository: any TaskRepository, auditRepository: any AuditRepository, policy: any PolicyEvaluator, policyConfig: PolicyConfig = .init(), executor: any ToolExecutor = NoOpToolExecutor(), requestRepository: (any ToolRequestRepository)? = nil, approvalRepository: (any ApprovalRepository)? = nil, unitOfWork: (any PersistenceUnitOfWork)? = nil) {
        self.tasks=taskRepository; self.audits=auditRepository; self.policy=policy; self.config=policyConfig; self.executor=executor
        if let requestRepository, let unitOfWork { self.requests=requestRepository; self.uow=unitOfWork } else if let t=taskRepository as? SQLiteTaskRepository { self.requests=SQLiteToolRequestRepository(database:t.database); self.uow=SQLitePersistenceUnitOfWork(database:t.database) } else { fatalError("SQLite persistence required") }
    }
    public func createTask(title:String) async throws -> Task { try lock.withLock { let t=Task(title:title); try uow.createTask(t,audit:audit(taskID:t.id,summary:"task created",result:"created")); return t } }
    public func getTask(id:UUID) async throws -> Task? { try lock.withLock { try tasks.fetch(id:id) } }
    public func listTasks() async throws -> [Task] { try lock.withLock { try tasks.list() } }
    public func submit(request:ToolRequest) async throws -> PolicyDecision {
        try lock.withLock { guard let t=try tasks.fetch(id:request.taskID) else { throw TaskServiceError.taskNotFound }; if t.status == .draft { try transitionLocked(t,to:.planning); try transitionLocked(try tasks.fetch(id:t.id)!,to:.running) } else if t.status == .planning { try transitionLocked(t,to:.running) } else if t.status != .running { throw TaskServiceError.illegalTransition(from:t.status,to:.running) }; try audits.append(audit(request,summary:"tool request received",result:"received")) }
        let d=policy.evaluate(request,config:config)
        switch d { case .allow: try lock.withLock { try uow.recordRequest(request,status:.executing,audits:[audit(request,summary:"policy allowed",result:"allowed")]) }; try await execute(request)
        case .requireApproval(let reason): try lock.withLock { try uow.submitRequest(request,status:.pending,taskStatus:.awaitingApproval,audits:[audit(request,summary:"policy requires approval",result:reason)]) }
        case .deny(let reason): try lock.withLock { try audits.append(audit(request,summary:"policy denied",result:reason)); try transitionLocked(try tasks.fetch(id:request.taskID)!,to:.blocked) } }; return d
    }
    public func approve(requestID:UUID,digest:String) async throws { let r=try lock.withLock { guard let (r,s)=try requests.fetch(id:requestID),s == .pending else { throw TaskServiceError.requestNotFound }; guard validateApproval(request:r,approvalDigest:digest) else { try audits.append(audit(r,summary:"approval rejected",result:"digest mismatch")); throw TaskServiceError.approvalDigestMismatch }; let a=Approval(toolRequestID:r.id,actionDigest:r.payloadDigest,decision:.approved); try uow.approveRequest(r,approval:a,taskStatus:.running,audits:[audit(r,summary:"approval accepted",result:"approved",approvalID:a.id)]); return r }; let job=Swift.Task { [weak self] in _ = try? await self?.execute(r) }; lock.withLock { running[r.id]=job } }
    public func reject(requestID:UUID) async throws { try lock.withLock { guard let (r,s)=try requests.fetch(id:requestID),s == .pending else { throw TaskServiceError.requestNotFound }; let a=Approval(toolRequestID:r.id,actionDigest:r.payloadDigest,decision:.rejected); try uow.rejectRequest(r,approval:a,taskStatus:.blocked,audits:[audit(r,summary:"approval rejected",result:"rejected",approvalID:a.id)]) } }
    public func cancel(taskID:UUID) async throws { try lock.withLock { running.values.forEach{$0.cancel()}; running.removeAll(); let ids=try requests.list(status:.pending).filter{$0.0.taskID==taskID}.map{$0.0.id}; try uow.cancelTask(taskID:taskID,requestIDs:ids,audits:[audit(taskID:taskID,summary:"task cancelled",result:"cancelled")]) } }
    public func transition(taskID:UUID,to:TaskStatus) throws { try lock.withLock { guard let t=try tasks.fetch(id:taskID) else { throw TaskServiceError.taskNotFound }; try transitionLocked(t,to:to) } }
    private func transitionLocked(_ t:Task,to:TaskStatus) throws { do { try TaskStateMachine.validate(from:t.status,to:to) } catch { throw TaskServiceError.illegalTransition(from:t.status,to:to) }; try uow.transition(taskID:t.id,from:t.status,to:to,audit:audit(taskID:t.id,summary:"task transitioned",result:"\(t.status.rawValue) -> \(to.rawValue)")) }
    private func execute(_ r:ToolRequest,approvalID:UUID?=nil) async throws { do { let result=try await executor.execute(r); let summary=String(redactSecrets(result.summary).prefix(512)); try lock.withLock { guard let t=try tasks.fetch(id:r.taskID), t.status != .cancelled else { return }; try requests.updateStatus(r.id,status:.completed); try audits.append(audit(r,summary:"tool result",result:summary,approvalID:approvalID)) } } catch { throw error } }
    private func audit(_ r:ToolRequest,summary:String,result:String,approvalID:UUID?=nil)->AuditEvent { audit(taskID:r.taskID,sideEffect:r.sideEffect,digest:r.payloadDigest,summary:summary,result:result,approvalID:approvalID,target:r.target) }
    private func audit(taskID: UUID, sideEffect: SideEffect = .read, digest: String = "", summary: String, result: String, approvalID: UUID? = nil, target: String = "local task service") -> AuditEvent { AuditEvent(taskID:taskID,worker:"task-service",target:target,sideEffect:sideEffect,actionDigest:digest,summary:summary,result:result,approvalID:approvalID) }
}
private extension NSLock { func withLock<T>(_ body:() throws->T) rethrows -> T { lock(); defer{unlock()}; return try body() } }
