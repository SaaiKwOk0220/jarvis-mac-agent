import Foundation
import XCTest
import JarvisDomain
import JarvisPersistence
import JarvisPolicy
@testable import JarvisService

final class TaskServiceTests: XCTestCase {
    func testLegalTransitionsPersistTheNewStatus() async throws {
        let fixture = try Fixture()
        let task = try await fixture.service.createTask(title: "Build release")

        try fixture.service.transition(taskID: task.id, to: .planning)
        try fixture.service.transition(taskID: task.id, to: .running)

        let stored = try await fixture.service.getTask(id: task.id)
        XCTAssertEqual(stored?.status, .running)
    }

    func testIllegalTransitionIsRejectedWithoutChangingStoredStatus() async throws {
        let fixture = try Fixture()
        let task = try await fixture.service.createTask(title: "Build release")

        XCTAssertThrowsError(try fixture.service.transition(taskID: task.id, to: .completed)) {
            XCTAssertEqual($0 as? TaskServiceError, .illegalTransition(from: .draft, to: .completed))
        }

        let stored = try await fixture.service.getTask(id: task.id)
        XCTAssertEqual(stored?.status, .draft)
    }

    func testProtectedRequestPersistsAwaitingApproval() async throws {
        let fixture = try Fixture()
        let task = try await fixture.service.createTask(title: "Edit document")
        let request = ToolRequest(
            taskID: task.id,
            name: "write_file",
            sideEffect: .localWrite,
            target: "/tmp/jarvis-service/document.txt",
            payload: "private contents"
        )

        let decision = try await fixture.service.submit(request: request)

        XCTAssertEqual(decision, .requireApproval(reason: "local write changes local state"))
        let stored = try await fixture.service.getTask(id: task.id)
        XCTAssertEqual(stored?.status, .awaitingApproval)
    }

    func testServiceRecreationApprovesPersistedRequestAndRecordsApproval() async throws {
        let fixture = try Fixture()
        let task = try await fixture.service.createTask(title: "Restart approval")
        let request = ToolRequest(taskID: task.id, name: "write_file", sideEffect: .localWrite, target: "/tmp/jarvis-service/a", payload: "content", scope: ToolScope(workingDirectory: "/tmp/jarvis-service"))
        _ = try await fixture.service.submit(request: request)
        let restarted = try fixture.makeService()

        try await restarted.approve(requestID: request.id, digest: request.payloadDigest)

        for _ in 0..<50 {
            if try fixture.requests.fetch(id: request.id)?.1 == .completed { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertEqual(try fixture.requests.fetch(id: request.id)?.1, .completed)
        XCTAssertEqual(try fixture.approvals.list().map(\.decision), [.approved])
    }

    func testServiceRecreationRejectsPersistedRequestAndRecordsRejection() async throws {
        let fixture = try Fixture()
        let task = try await fixture.service.createTask(title: "Restart rejection")
        let request = ToolRequest(taskID: task.id, name: "write_file", sideEffect: .localWrite, target: "/tmp/jarvis-service/a", payload: "content")
        _ = try await fixture.service.submit(request: request)

        try await fixture.makeService().reject(requestID: request.id)

        XCTAssertEqual(try fixture.tasks.fetch(id: task.id)?.status, .blocked)
        XCTAssertEqual(try fixture.requests.fetch(id: request.id)?.1, .rejected)
        XCTAssertEqual(try fixture.approvals.list().map(\.decision), [.rejected])
    }

    func testExecutorFailurePersistsFailedRequestTaskAndAudit() async throws {
        let fixture = try Fixture(executor: ThrowingExecutor())
        let task = try await fixture.service.createTask(title: "Failure")
        let request = ToolRequest(taskID: task.id, name: "read_file", sideEffect: .read, target: "/tmp/jarvis-service/a", payload: "")

        await XCTAssertThrowsErrorAsync(try await fixture.service.submit(request: request))

        XCTAssertEqual(try fixture.tasks.fetch(id: task.id)?.status, .failed)
        XCTAssertEqual(try fixture.requests.fetch(id: request.id)?.1, .failed)
        XCTAssertTrue(try fixture.audit.events(for: task.id).contains { $0.summary == "tool failure" })
    }

    func testCancellationCancelsExecutingRequestAndSuppressesSuccess() async throws {
        let executor = SuspendingExecutor()
        let fixture = try Fixture(executor: executor)
        let task = try await fixture.service.createTask(title: "Cancel running")
        let request = ToolRequest(taskID: task.id, name: "read_file", sideEffect: .read, target: "/tmp/jarvis-service/a", payload: "")
        let submission = Task.detached { try? await fixture.service.submit(request: request) }
        await executor.started()

        try await fixture.service.cancel(taskID: task.id)
        executor.resume()
        _ = await submission.result
        try await Task.sleep(nanoseconds: 5_000_000)

        XCTAssertEqual(try fixture.tasks.fetch(id: task.id)?.status, .cancelled)
        XCTAssertEqual(try fixture.requests.fetch(id: request.id)?.1, .cancelled)
        XCTAssertFalse(try fixture.audit.events(for: task.id).contains { $0.summary == "tool result" })
    }

    func testApprovalDigestMismatchRejectsRequestAndLeavesTaskAwaitingApproval() async throws {
        let fixture = try Fixture()
        let task = try await fixture.service.createTask(title: "Edit document")
        let request = ToolRequest(
            taskID: task.id,
            name: "write_file",
            sideEffect: .localWrite,
            target: "/tmp/jarvis-service/document.txt",
            payload: "private contents",
            scope: ToolScope(workingDirectory: "/tmp/jarvis-service")
        )
        _ = try await fixture.service.submit(request: request)

        await XCTAssertThrowsErrorAsync(try await fixture.service.approve(requestID: request.id, digest: "tampered")) {
            XCTAssertEqual($0 as? TaskServiceError, .approvalDigestMismatch)
        }

        let stored = try await fixture.service.getTask(id: task.id)
        XCTAssertEqual(stored?.status, .awaitingApproval)
        XCTAssertTrue(try fixture.audit.events(for: task.id).contains { $0.summary == "approval rejected" })
    }

    func testCancellationPersistsCancelledStatusAndAuditsIt() async throws {
        let fixture = try Fixture()
        let task = try await fixture.service.createTask(title: "Build release")

        try await fixture.service.cancel(taskID: task.id)

        let stored = try await fixture.service.getTask(id: task.id)
        XCTAssertEqual(stored?.status, .cancelled)
        XCTAssertTrue(try fixture.audit.events(for: task.id).contains { $0.summary == "task cancelled" })
    }

    func testSecondServiceCannotSubmitAfterConcurrentCancellation() async throws {
        let fixture = try Fixture()
        let task = try await fixture.service.createTask(title: "Cross service cancellation")
        let policy = BlockingAllowPolicy()
        let second = try TaskService(taskRepository: fixture.tasks, auditRepository: fixture.audit, policy: policy, policyConfig: PolicyConfig(approvedDirectories: ["/tmp/jarvis-service"]), requestRepository: fixture.requests, approvalRepository: fixture.approvals, unitOfWork: SQLitePersistenceUnitOfWork(database: fixture.database))
        let request = ToolRequest(taskID: task.id, name: "read_file", sideEffect: .read, target: "/tmp/jarvis-service/a", payload: "")
        let submission = Task.detached { try? await second.submit(request: request) }

        XCTAssertTrue(policy.waitForEvaluation())
        try await fixture.service.cancel(taskID: task.id)
        policy.open()
        _ = await submission.result

        XCTAssertEqual(try fixture.tasks.fetch(id: task.id)?.status, .cancelled)
        XCTAssertNil(try fixture.requests.fetch(id: request.id))
    }

    func testAllowedExecutionIsTrackedAndCancelled() async throws {
        let executor = SuspendingExecutor()
        let fixture = try Fixture(executor: executor)
        let task = try await fixture.service.createTask(title: "Cancel allowed execution")
        let request = ToolRequest(taskID: task.id, name: "read_file", sideEffect: .read, target: "/tmp/jarvis-service/a", payload: "")
        let submission = Task.detached { try? await fixture.service.submit(request: request) }
        await executor.started()

        try await fixture.service.cancel(taskID: task.id)
        executor.resume()
        _ = await submission.result
        XCTAssertEqual(try fixture.requests.fetch(id: request.id)?.1, .cancelled)
        XCTAssertFalse(try fixture.audit.events(for: task.id).contains { $0.summary == "tool result" })
    }

    func testCancellationCancelsMultipleExecutionsForOneTask() async throws {
        let executor = MultiSuspendingExecutor()
        let fixture = try Fixture(executor: executor)
        let task = try await fixture.service.createTask(title: "Cancel multiple executions")
        let requests = (0..<2).map { ToolRequest(taskID: task.id, name: "read_file", sideEffect: .read, target: "/tmp/jarvis-service/\($0)", payload: "") }
        let submissions = requests.map { request in Task.detached { try? await fixture.service.submit(request: request) } }
        await executor.started(ids: Set(requests.map(\.id)))

        try await fixture.service.cancel(taskID: task.id)
        requests.forEach { executor.resume(id: $0.id) }
        for submission in submissions { _ = await submission.result }
        for request in requests { XCTAssertEqual(try fixture.requests.fetch(id: request.id)?.1, .cancelled) }
        XCTAssertFalse(try fixture.audit.events(for: task.id).contains { $0.summary == "tool result" })
    }

    func testApprovedRequestCompletesTaskAfterNoOpExecutor() async throws {
        let fixture = try Fixture()
        let task = try await fixture.service.createTask(title: "Approve demo completion")
        let request = ToolRequest(taskID: task.id, name: "demo_write", sideEffect: .localWrite,
            target: "/tmp/jarvis-service/draft.txt", payload: "Create a local demo draft")
        _ = try await fixture.service.submit(request: request)
        XCTAssertEqual(try fixture.tasks.fetch(id: task.id)?.status, .awaitingApproval)

        try await fixture.service.approve(requestID: request.id, digest: request.payloadDigest)

        for _ in 0..<100 {
            if try fixture.tasks.fetch(id: task.id)?.status == .completed { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(try fixture.tasks.fetch(id: task.id)?.status, .completed,
            "Task should reach .completed once NoOpToolExecutor finishes; the demo executor must not leave the task in .running")
        XCTAssertEqual(try fixture.requests.fetch(id: request.id)?.1, .completed)
        XCTAssertTrue(try fixture.audit.events(for: task.id).contains { $0.summary == "tool result" })
    }

    func testRejectsRepositoriesFromDifferentDatabases() throws {
        let first = try Database(path: ":memory:"); try first.migrate()
        let second = try Database(path: ":memory:"); try second.migrate()
        XCTAssertThrowsError(try TaskService(taskRepository: SQLiteTaskRepository(database: first), auditRepository: SQLiteAuditRepository(database: second), policy: Policy())) {
            XCTAssertEqual($0 as? TaskServiceError, .incompatiblePersistence)
        }
    }

    func testPersistenceCannotRecordOrSubmitRequestsForCancelledTask() async throws {
        let fixture = try Fixture()
        let task = try await fixture.service.createTask(title: "Persistence guard")
        try fixture.service.transition(taskID: task.id, to: .planning)
        try fixture.service.transition(taskID: task.id, to: .running)
        try await fixture.service.cancel(taskID: task.id)
        let immediate = ToolRequest(taskID: task.id, name: "read_file", sideEffect: .read, target: "/tmp/jarvis-service/a", payload: "")
        let pending = ToolRequest(taskID: task.id, name: "write_file", sideEffect: .localWrite, target: "/tmp/jarvis-service/b", payload: "")
        let uow = SQLitePersistenceUnitOfWork(database: fixture.database)

        XCTAssertThrowsError(try uow.recordRequest(immediate, status: .executing, audits: []))
        XCTAssertThrowsError(try uow.submitRequest(pending, status: .pending, taskStatus: .awaitingApproval, audits: []))
        XCTAssertEqual(try fixture.tasks.fetch(id: task.id)?.status, .cancelled)
        XCTAssertNil(try fixture.requests.fetch(id: immediate.id))
        XCTAssertNil(try fixture.requests.fetch(id: pending.id))
    }

    func testAllowedRequestCreatesRequestDecisionAndResultAuditEvents() async throws {
        let fixture = try Fixture()
        let task = try await fixture.service.createTask(title: "Read document")
        let request = ToolRequest(
            taskID: task.id,
            name: "read_file",
            sideEffect: .read,
            target: "/tmp/jarvis-service/document.txt",
            payload: "secret=do-not-record"
        )

        let decision = try await fixture.service.submit(request: request)
        XCTAssertEqual(decision, .allow)

        let summaries = try fixture.audit.events(for: task.id).map(\.summary)
        XCTAssertTrue(summaries.contains("tool request received"))
        XCTAssertTrue(summaries.contains("policy allowed"))
        XCTAssertTrue(summaries.contains("tool result"))
        XCTAssertFalse(try fixture.audit.events(for: task.id).contains { $0.summary.contains("do-not-record") || $0.result.contains("do-not-record") })
    }

    func testLoopbackJSONEndpointsCreateListDetailAndCancelWhileRejectingRemotePeers() async throws {
        let fixture = try Fixture()
        let server = LoopbackServer(service: fixture.service)

        let create = await server.handle(
            method: "POST",
            path: "/tasks",
            body: Data("{\"title\":\"From endpoint\"}".utf8),
            peerHost: "127.0.0.1"
        )
        XCTAssertEqual(create.status, 201)
        let task = try JSONDecoder().decode(Task.self, from: create.body)

        let list = await server.handle(method: "GET", path: "/tasks", body: Data(), peerHost: "::1")
        XCTAssertEqual(list.status, 200)
        XCTAssertEqual(try JSONDecoder().decode([Task].self, from: list.body).map(\.id), [task.id])

        let detail = await server.handle(method: "GET", path: "/tasks/\(task.id.uuidString)", body: Data(), peerHost: "127.0.0.1")
        XCTAssertEqual(detail.status, 200)
        XCTAssertEqual(try JSONDecoder().decode(Task.self, from: detail.body).id, task.id)

        let cancel = await server.handle(method: "POST", path: "/tasks/\(task.id.uuidString)/cancel", body: Data(), peerHost: "127.0.0.1")
        XCTAssertEqual(cancel.status, 204)
        let stored = try await fixture.service.getTask(id: task.id)
        XCTAssertEqual(stored?.status, .cancelled)

        let remote = await server.handle(method: "GET", path: "/tasks", body: Data(), peerHost: "203.0.113.10")
        XCTAssertEqual(remote.status, 403)
    }

    func testLoopbackServerServesJSONOverLocalhost() async throws {
        let fixture = try Fixture()
        let server = LoopbackServer(service: fixture.service)
        let port = try await server.start()
        defer { server.stop() }

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/tasks")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{\"title\":\"Socket task\"}".utf8)
        let (data, response) = try await URLSession.shared.data(for: request)

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 201)
        XCTAssertEqual(try JSONDecoder().decode(Task.self, from: data).title, "Socket task")
    }

    func testLoopbackServerServesPersistedPendingApprovalMetadata() async throws {
        let fixture = try Fixture()
        let task = try await fixture.service.createTask(title: "Approval metadata")
        let request = ToolRequest(taskID: task.id, name: "write_file", sideEffect: .localWrite, target: "/tmp/jarvis-service/secret.txt", payload: "api_key=do-not-leak")
        _ = try await fixture.service.submit(request: request)
        let server = LoopbackServer(service: fixture.service)
        let response = await server.handle(method: "GET", path: "/tasks/\(task.id.uuidString)/requests", body: Data(), peerHost: "127.0.0.1")

        XCTAssertEqual(response.status, 200)
        let json = try JSONSerialization.jsonObject(with: response.body) as? [[String: Any]]
        let item = try XCTUnwrap(json?.first)
        XCTAssertEqual(item["id"] as? String, request.id.uuidString)
        XCTAssertEqual(item["taskID"] as? String, task.id.uuidString)
        XCTAssertEqual(item["digest"] as? String, request.payloadDigest)
        XCTAssertEqual(item["target"] as? String, request.target)
        XCTAssertEqual(item["reason"] as? String, "local write changes local state")
        XCTAssertEqual(item["payload"] as? String, "[REDACTED]")
    }

    func testLoopbackServerServesRedactedTaskTimeline() async throws {
        let fixture = try Fixture()
        let task = try await fixture.service.createTask(title: "Timeline")
        let response = await LoopbackServer(service: fixture.service).handle(
            method: "GET", path: "/tasks/\(task.id.uuidString)/timeline", body: Data(), peerHost: "127.0.0.1")

        XCTAssertEqual(response.status, 200)
        let events = try JSONDecoder().decode([TimelineEvent].self, from: response.body)
        XCTAssertEqual(events.map(\.summary), ["task created"])
        XCTAssertEqual(events.first?.target, "local task service")
    }
}

private final class Fixture: @unchecked Sendable {
    let database: Database
    let tasks: SQLiteTaskRepository
    let audit: SQLiteAuditRepository
    let requests: SQLiteToolRequestRepository
    let approvals: SQLiteApprovalRepository
    let service: TaskService

    init(executor: any ToolExecutor = NoOpToolExecutor()) throws {
        database = try Database(path: ":memory:")
        try database.migrate()
        tasks = SQLiteTaskRepository(database: database)
        audit = SQLiteAuditRepository(database: database)
        requests = SQLiteToolRequestRepository(database: database)
        approvals = SQLiteApprovalRepository(database: database)
        service = try TaskService(
            taskRepository: tasks,
            auditRepository: audit,
            policy: Policy(),
            policyConfig: PolicyConfig(approvedDirectories: ["/tmp/jarvis-service"]), executor: executor,
            requestRepository: requests, approvalRepository: approvals, unitOfWork: SQLitePersistenceUnitOfWork(database: database)
        )
    }

    func makeService() throws -> TaskService {
        try TaskService(taskRepository: tasks, auditRepository: audit, policy: Policy(), policyConfig: PolicyConfig(approvedDirectories: ["/tmp/jarvis-service"]), requestRepository: requests, approvalRepository: approvals, unitOfWork: SQLitePersistenceUnitOfWork(database: database))
    }
}

private struct ThrowingExecutor: ToolExecutor { func execute(_ request: ToolRequest) async throws -> ToolResult { struct Expected: Error {}; throw Expected() } }

private final class SuspendingExecutor: ToolExecutor, @unchecked Sendable {
    private let lock = NSLock(); private var continuation: CheckedContinuation<ToolResult, Never>?
    func execute(_ request: ToolRequest) async throws -> ToolResult { await withCheckedContinuation { continuation in lock.withLock { self.continuation = continuation } } }
    func started() async { for _ in 0..<100 { if lock.withLock({ continuation != nil }) { return }; try? await Task.sleep(nanoseconds: 1_000_000) } }
    func resume() { lock.withLock { continuation?.resume(returning: ToolResult(summary: "late")); continuation = nil } }
}

private final class MultiSuspendingExecutor: ToolExecutor, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: CheckedContinuation<ToolResult, Never>] = [:]
    func execute(_ request: ToolRequest) async throws -> ToolResult {
        await withCheckedContinuation { continuation in lock.withLock { continuations[request.id] = continuation } }
    }
    func started(ids: Set<UUID>) async {
        for _ in 0..<100 {
            if lock.withLock({ Set(continuations.keys).isSuperset(of: ids) }) { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }
    func resume(id: UUID) {
        lock.withLock { continuations.removeValue(forKey: id)?.resume(returning: ToolResult(summary: "late")) }
    }
}

private final class BlockingAllowPolicy: PolicyEvaluator, @unchecked Sendable {
    private let condition = NSCondition()
    private var entered = false
    private var isOpen = false

    func evaluate(_ request: ToolRequest, config: PolicyConfig) -> PolicyDecision {
        condition.lock()
        entered = true
        condition.broadcast()
        while !isOpen { condition.wait() }
        condition.unlock()
        return .allow
    }

    func waitForEvaluation(timeout: TimeInterval = 1) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while !entered {
            guard condition.wait(until: deadline) else { return false }
        }
        return true
    }

    func open() {
        condition.lock()
        isOpen = true
        condition.broadcast()
        condition.unlock()
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw")
    } catch {
        errorHandler(error)
    }
}
