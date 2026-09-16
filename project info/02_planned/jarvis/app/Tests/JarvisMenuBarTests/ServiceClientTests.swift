import XCTest
@testable import JarvisMenuBar
import JarvisDomain
import JarvisPersistence
import JarvisPolicy
import JarvisService

@MainActor
final class ServiceClientTests: XCTestCase {
    private let decoder = JSONDecoder()

    func testDecodesTaskList() throws {
        let id = UUID()
        let body = try JSONEncoder().encode([JarvisTask(id: id, title: "demo")])
        let tasks = try ServiceClient.decodeTaskList(body, decoder: decoder)
        XCTAssertEqual(tasks.first?.id, id)
        XCTAssertEqual(tasks.first?.title, "demo")
    }

    func testDecodesApprovalRequest() throws {
        let request = ApprovalRequest(id: UUID(), taskID: UUID(), reason: "send email", target: "mail", payload: "hello", digest: "abc")
        let body = try JSONEncoder().encode(request)
        XCTAssertEqual(try ServiceClient.decodeApprovalRequest(body, decoder: decoder), request)
    }

    func testDecodesAPIError() throws {
        let body = Data(#"{"message":"request cannot be completed"}"#.utf8)
        XCTAssertEqual(try ServiceClient.decodeAPIError(body, decoder: decoder).message, "request cannot be completed")
    }

    func testUnavailableErrorIsStable() {
        XCTAssertEqual(ServiceClientError.unavailable.localizedDescription, "Jarvis service is unavailable")
    }

    func testRejectsMalformedTaskList() {
        XCTAssertThrowsError(try ServiceClient.decodeTaskList(Data("{}".utf8), decoder: decoder)) {
            XCTAssertEqual($0 as? ServiceClientError, .decoding)
        }
    }

    func testRefreshReportsServiceUnavailableWhenLoopbackIsNotListening() async {
        let client = ServiceClient(baseURL: URL(string: "http://127.0.0.1:1")!)
        do {
            _ = try await client.refresh()
            XCTFail("Expected an unavailable service")
        } catch {
            XCTAssertEqual(error as? ServiceClientError, .unavailable)
            XCTAssertEqual(client.serviceError, .unavailable)
        }
    }

    func testLoadsApprovalMetadataFromRealLoopbackServer() async throws {
        let database = try Database(path: ":memory:")
        try database.migrate()
        let tasks = SQLiteTaskRepository(database: database)
        let audit = SQLiteAuditRepository(database: database)
        let service = try TaskService(
            taskRepository: tasks,
            auditRepository: audit,
            policy: Policy(),
            policyConfig: PolicyConfig(approvedDirectories: ["/tmp/jarvis-service"]),
            requestRepository: SQLiteToolRequestRepository(database: database),
            approvalRepository: SQLiteApprovalRepository(database: database),
            unitOfWork: SQLitePersistenceUnitOfWork(database: database)
        )
        let task = try await service.createTask(title: "Network approval")
        let request = ToolRequest(taskID: task.id, name: "write_file", sideEffect: .localWrite, target: "/tmp/jarvis-service/network.txt", payload: "safe")
        _ = try await service.submit(request: request)
        let server = LoopbackServer(service: service)
        let port = try await server.start()
        defer { server.stop() }

        let client = ServiceClient(baseURL: URL(string: "http://127.0.0.1:\(port)")!)
        let requests = try await client.loadApprovalRequests(taskID: task.id)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].id, request.id)
        XCTAssertEqual(requests[0].digest, request.payloadDigest)
        XCTAssertEqual(requests[0].target, request.target)

        try await client.approve(requests[0])
        XCTAssertNil(client.serviceError)
    }

    func testLoadsTimelineFromRealLoopbackServer() async throws {
        let database = try Database(path: ":memory:")
        try database.migrate()
        let service = try TaskService(taskRepository: SQLiteTaskRepository(database: database),
            auditRepository: SQLiteAuditRepository(database: database), policy: Policy())
        let task = try await service.createTask(title: "Network timeline")
        let server = LoopbackServer(service: service)
        let port = try await server.start()
        defer { server.stop() }

        let client = ServiceClient(baseURL: URL(string: "http://127.0.0.1:\(port)")!)
        let events = try await client.loadTimeline(taskID: task.id)
        XCTAssertEqual(events.map(\.summary), ["task created"])
        XCTAssertEqual(client.timelineEvents[task.id]?.count, 1)
    }

    func testCreatesAndSelectsTaskThroughRealLoopbackServer() async throws {
        let database = try Database(path: ":memory:")
        try database.migrate()
        let service = try TaskService(taskRepository: SQLiteTaskRepository(database: database),
            auditRepository: SQLiteAuditRepository(database: database), policy: Policy())
        let server = LoopbackServer(service: service)
        let port = try await server.start()
        defer { server.stop() }

        let client = ServiceClient(baseURL: URL(string: "http://127.0.0.1:\(port)")!)
        let task = try await client.createTask(title: "Created from menu")
        XCTAssertEqual(task.title, "Created from menu")
        XCTAssertEqual(client.selectedTask?.id, task.id)
        XCTAssertEqual(client.tasks.map(\.id), [task.id])
    }

    func testApproveSurfacesActionErrorOnConflict() async throws {
        let database = try Database(path: ":memory:")
        try database.migrate()
        let service = try TaskService(taskRepository: SQLiteTaskRepository(database: database),
            auditRepository: SQLiteAuditRepository(database: database), policy: Policy(),
            policyConfig: PolicyConfig(approvedDirectories: ["/tmp/jarvis-service"]))
        let server = LoopbackServer(service: service)
        let port = try await server.start()
        defer { server.stop() }

        let client = ServiceClient(baseURL: URL(string: "http://127.0.0.1:\(port)")!)
        let task = try await client.createTask(title: "Conflict approve")
        try await client.startDemoApproval(taskID: task.id)
        let request = try XCTUnwrap(client.approvalRequests.values.first)

        try await client.approve(request)
        XCTAssertNil(client.actionError)

        do {
            try await client.approve(request)
            XCTFail("Expected approve to throw after the request is no longer pending")
        } catch {
            // Expected
        }
        XCTAssertNotNil(client.actionError)
        XCTAssertTrue(client.actionError?.contains("409") == true,
            "actionError should describe the 409 conflict, got: \(client.actionError ?? "nil")")
    }

    func testCancelSurfacesActionErrorOnConflict() async throws {
        let database = try Database(path: ":memory:")
        try database.migrate()
        let service = try TaskService(taskRepository: SQLiteTaskRepository(database: database),
            auditRepository: SQLiteAuditRepository(database: database), policy: Policy(),
            policyConfig: PolicyConfig(approvedDirectories: ["/tmp/jarvis-service"]))
        let server = LoopbackServer(service: service)
        let port = try await server.start()
        defer { server.stop() }

        let client = ServiceClient(baseURL: URL(string: "http://127.0.0.1:\(port)")!)
        let task = try await client.createTask(title: "Conflict cancel")

        try await client.cancel(taskID: task.id)
        XCTAssertNil(client.actionError)

        do {
            try await client.cancel(taskID: task.id)
            XCTFail("Expected cancel to throw after the task is already cancelled")
        } catch {
            // Expected
        }
        XCTAssertNotNil(client.actionError)
        XCTAssertTrue(client.actionError?.contains("409") == true,
                      "expected 409 in error message, got: \(client.actionError ?? "<nil>")")
    }

    func testClearActionErrorResetsPublishedValue() async throws {
        let database = try Database(path: ":memory:")
        try database.migrate()
        let service = try TaskService(taskRepository: SQLiteTaskRepository(database: database),
            auditRepository: SQLiteAuditRepository(database: database), policy: Policy(),
            policyConfig: PolicyConfig(approvedDirectories: ["/tmp/jarvis-service"]))
        let server = LoopbackServer(service: service)
        let port = try await server.start()
        defer { server.stop() }

        let client = ServiceClient(baseURL: URL(string: "http://127.0.0.1:\(port)")!)
        let task = try await client.createTask(title: "Clear action error")
        try await client.cancel(taskID: task.id)
        do { try await client.cancel(taskID: task.id); XCTFail("Expected throw") } catch { }

        XCTAssertNotNil(client.actionError)
        client.clearActionError()
        XCTAssertNil(client.actionError)
    }

    func testRunsDemoApprovalFlowThroughRealLoopbackServer() async throws {
        let database = try Database(path: ":memory:")
        try database.migrate()
        let service = try TaskService(taskRepository: SQLiteTaskRepository(database: database),
            auditRepository: SQLiteAuditRepository(database: database), policy: Policy(),
            policyConfig: PolicyConfig(approvedDirectories: ["/tmp/jarvis-demo"]))
        let server = LoopbackServer(service: service)
        let port = try await server.start()
        defer { server.stop() }

        let client = ServiceClient(baseURL: URL(string: "http://127.0.0.1:\(port)")!)
        let task = try await client.createTask(title: "Demo approval")
        try await client.startDemoApproval(taskID: task.id)
        let request = try XCTUnwrap(client.approvalRequests.values.first)
        XCTAssertEqual(client.selectedTask?.status, .awaitingApproval)
        XCTAssertEqual(request.reason, "local write changes local state")

        try await client.approve(request)
        _ = try await client.loadTimeline(taskID: task.id)
        XCTAssertTrue(client.timelineEvents[task.id]?.contains { $0.summary == "approval accepted" } == true)
    }

    /// Bug C: ApprovalView used `approvalRequests.values.first(where:)`, which is
    /// non-deterministic when multiple requests exist for the same task. The fix
    /// re-keys the dictionary by `taskID` so `approvalRequests[task.id]` is the
    /// canonical lookup the view relies on.
    func testLoadApprovalRequestsStoresRequestsKeyedByTaskID() async throws {
        let database = try Database(path: ":memory:")
        try database.migrate()
        let service = try TaskService(
            taskRepository: SQLiteTaskRepository(database: database),
            auditRepository: SQLiteAuditRepository(database: database),
            policy: Policy(),
            policyConfig: PolicyConfig(approvedDirectories: ["/tmp/jarvis-c-keying"]),
            requestRepository: SQLiteToolRequestRepository(database: database),
            approvalRepository: SQLiteApprovalRepository(database: database),
            unitOfWork: SQLitePersistenceUnitOfWork(database: database)
        )
        let task = try await service.createTask(title: "C-keying")
        let request = ToolRequest(taskID: task.id, name: "write_file", sideEffect: .localWrite,
            target: "/tmp/jarvis-c-keying/out.txt", payload: "safe payload")
        _ = try await service.submit(request: request)

        let server = LoopbackServer(service: service)
        let port = try await server.start()
        defer { server.stop() }
        let client = ServiceClient(baseURL: URL(string: "http://127.0.0.1:\(port)")!)

        _ = try await client.loadApprovalRequests(taskID: task.id)
        XCTAssertEqual(client.approvalRequests.count, 1)
        XCTAssertNotNil(client.approvalRequests[task.id],
            "approvalRequests must be keyed by taskID so ApprovalView can resolve with [task.id]")
        XCTAssertEqual(client.approvalRequests[task.id]?.id, request.id)
        XCTAssertEqual(client.approvalRequests[task.id]?.digest, request.payloadDigest)
    }

    /// Bug D: NewTaskView used to call `client.select(task)` after `createTask`,
    /// which already sets `selectedTask` internally. The redundant call
    /// triggered a second `@Published` re-render. The view layer fix relies on
    /// `createTask` being sufficient on its own.
    func testCreateTaskSetsSelectedTaskWithoutExplicitSelectCall() async throws {
        let database = try Database(path: ":memory:")
        try database.migrate()
        let service = try TaskService(taskRepository: SQLiteTaskRepository(database: database),
            auditRepository: SQLiteAuditRepository(database: database), policy: Policy())
        let server = LoopbackServer(service: service)
        let port = try await server.start()
        defer { server.stop() }

        let client = ServiceClient(baseURL: URL(string: "http://127.0.0.1:\(port)")!)
        // NewTaskView flow: just call createTask; do not call select.
        let task = try await client.createTask(title: "From new task view")
        XCTAssertEqual(client.selectedTask?.id, task.id,
            "createTask must set selectedTask on its own; NewTaskView relies on this and does not call select again")
        XCTAssertEqual(client.tasks.map(\.id), [task.id])
    }

    /// Bug E: `previousStatuses` should never grow beyond the set of tasks
    /// returned by the current refresh. Stale entries for deleted tasks must
    /// be pruned so the diff stays bounded over a long-running session.
    func testRefreshPrunesStalePreviousStatusEntries() async throws {
        let database = try Database(path: ":memory:")
        try database.migrate()
        let service = try TaskService(taskRepository: SQLiteTaskRepository(database: database),
            auditRepository: SQLiteAuditRepository(database: database), policy: Policy())
        let server = LoopbackServer(service: service)
        let port = try await server.start()
        defer { server.stop() }

        let client = ServiceClient(baseURL: URL(string: "http://127.0.0.1:\(port)")!)
        // Inject stale entries that no longer correspond to any task on the server.
        let stale1 = UUID()
        let stale2 = UUID()
        client.previousStatuses[stale1] = .completed
        client.previousStatuses[stale2] = .failed
        XCTAssertEqual(client.previousStatuses.count, 2)

        _ = try await client.refresh()
        XCTAssertNil(client.previousStatuses[stale1],
            "stale previousStatuses entry for a task no longer in /tasks must be pruned")
        XCTAssertNil(client.previousStatuses[stale2],
            "stale previousStatuses entry for a task no longer in /tasks must be pruned")
        XCTAssertEqual(client.previousStatuses.count, client.tasks.count,
            "previousStatuses size must equal current task count after every refresh")
    }
}
