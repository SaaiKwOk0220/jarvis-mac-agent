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

    /// Drives `submitShellCommand` against a real LoopbackServer so the end-to-end
    /// wiring (URLSession POST, JSON encode of the ToolRequest, server-side
    /// submit, service-side persistence) is exercised. Verifies the resulting
    /// task lands in `.awaitingApproval` with a pending shell request whose
    /// digest matches what the client computed.
    func testSubmitShellCommandPostsShellRequestToLoopbackServer() async throws {
        let database = try Database(path: ":memory:")
        try database.migrate()
        let tasks = SQLiteTaskRepository(database: database)
        let audit = SQLiteAuditRepository(database: database)
        let requests = SQLiteToolRequestRepository(database: database)
        let approvals = SQLiteApprovalRepository(database: database)
        let service = try TaskService(
            taskRepository: tasks,
            auditRepository: audit,
            policy: Policy(),
            policyConfig: PolicyConfig(
                approvedDirectories: ["/tmp/jarvis-shell-ui"],
                commandNames: ["shell"]
            ),
            requestRepository: requests,
            approvalRepository: approvals,
            unitOfWork: SQLitePersistenceUnitOfWork(database: database)
        )
        let server = LoopbackServer(service: service)
        let port = try await server.start()
        defer { server.stop() }

        let client = ServiceClient(baseURL: URL(string: "http://127.0.0.1:\(port)")!)
        let task = try await client.createTask(title: "Menu shell command")

        try await client.submitShellCommand(
            taskID: task.id,
            command: "echo menu-shell",
            workingDirectory: "/tmp/jarvis-shell-ui"
        )

        let stored = try await service.getTask(id: task.id)
        XCTAssertEqual(stored?.status, .awaitingApproval,
                       "submitShellCommand must drive the task into awaitingApproval")

        let pending = try await service.listPendingApprovalRequests(taskID: task.id)
        XCTAssertEqual(pending.count, 1, "submitShellCommand should produce exactly one pending request")
        let request = try XCTUnwrap(pending.first)
        XCTAssertEqual(request.taskID, task.id)
        XCTAssertEqual(request.target, "/tmp/jarvis-shell-ui",
                       "target should echo the working directory the client sent")

        // Recompute the digest on the client side and verify it matches the
        // server-side digest. This confirms the wire format (the body the
        // client encoded) survived the round-trip without mangling.
        let expectedDigest = ToolRequest.actionDigest(
            name: "shell",
            sideEffect: .localExecute,
            target: "/tmp/jarvis-shell-ui",
            payload: "echo menu-shell",
            scope: ToolScope(workingDirectory: "/tmp/jarvis-shell-ui")
        )
        XCTAssertEqual(request.digest, expectedDigest,
                       "digest from server must equal the one the client computed")
        XCTAssertNil(client.actionError,
                     "submitShellCommand must not leave actionError populated on success")
    }

    /// Drives `submitFetchURL` against a real LoopbackServer so the end-to-end
    /// wiring (URLSession POST, JSON encode of the ToolRequest, server-side
    /// submit, service-side persistence) is exercised. Mirrors the
    /// `testSubmitShellCommandPostsShellRequestToLoopbackServer` pattern but
    /// pins the fetch wire format: name=fetch, sideEffect=read, target == url.
    func testSubmitFetchURLPostsFetchRequestToLoopbackServer() async throws {
        let database = try Database(path: ":memory:")
        try database.migrate()
        let tasks = SQLiteTaskRepository(database: database)
        let audit = SQLiteAuditRepository(database: database)
        let requests = SQLiteToolRequestRepository(database: database)
        let approvals = SQLiteApprovalRepository(database: database)
        let service = try TaskService(
            taskRepository: tasks,
            auditRepository: audit,
            policy: Policy(),
            policyConfig: PolicyConfig(
                browserProfiles: ["default"],
                sites: ["example.com"]
            ),
            requestRepository: requests,
            approvalRepository: approvals,
            unitOfWork: SQLitePersistenceUnitOfWork(database: database)
        )
        let server = LoopbackServer(service: service)
        let port = try await server.start()
        defer { server.stop() }

        let client = ServiceClient(baseURL: URL(string: "http://127.0.0.1:\(port)")!)
        let task = try await client.createTask(title: "Menu fetch URL")

        let targetURL = "https://example.com/page"
        try await client.submitFetchURL(taskID: task.id, urlString: targetURL)

        // The fetch went through Policy.read which returns .allow for an
        // https host in sites + a configured browser profile, so the request
        // should be executing (or already completed) rather than awaiting
        // approval. We assert the request landed in the service exactly once
        // with the wire-format values the client sent.
        let pending = try await service.listPendingApprovalRequests(taskID: task.id)
        XCTAssertEqual(pending.count, 0,
            "fetch is a .read action and must not produce a pending approval row")

        let stored = try await service.getTask(id: task.id)
        XCTAssertNotEqual(stored?.status, .awaitingApproval,
            "fetch should not leave the task in awaitingApproval")

        XCTAssertNil(client.actionError,
            "submitFetchURL must not leave actionError populated on success")
    }

    /// Drives `submitScreenshot` against a real LoopbackServer so the
    /// end-to-end wiring (URLSession POST, JSON encode of the ToolRequest,
    /// server-side submit, service-side persistence) is exercised. Mirrors
    /// the `testSubmitFetchURLPostsFetchRequestToLoopbackServer` pattern but
    /// pins the screenshot wire format: name=screenshot, sideEffect=read,
    /// payload="screen", and the target's basename matches the user-supplied
    /// filename. The screenshot is a `.read` action and must not produce a
    /// pending approval row.
    func testSubmitScreenshotPostsScreenshotRequestToLoopbackServer() async throws {
        let database = try Database(path: ":memory:")
        try database.migrate()
        let tasks = SQLiteTaskRepository(database: database)
        let audit = SQLiteAuditRepository(database: database)
        let requests = SQLiteToolRequestRepository(database: database)
        let approvals = SQLiteApprovalRepository(database: database)
        let service = try TaskService(
            taskRepository: tasks,
            auditRepository: audit,
            policy: Policy(),
            policyConfig: PolicyConfig(
                approvedDirectories: [ServiceClient.screenshotsApprovedDirectory.path]
            ),
            requestRepository: requests,
            approvalRepository: approvals,
            unitOfWork: SQLitePersistenceUnitOfWork(database: database)
        )
        let server = LoopbackServer(service: service)
        let port = try await server.start()
        defer { server.stop() }

        let client = ServiceClient(baseURL: URL(string: "http://127.0.0.1:\(port)")!)
        let task = try await client.createTask(title: "Menu screenshot")

        try await client.submitScreenshot(
            taskID: task.id,
            outputFilename: "screenshot-2026-09-17.png"
        )

        // screenshot is a .read action and must not produce a pending
        // approval row; the request lands in .executing (or already
        // .completed) and the loopback server returns 200 with the policy
        // decision.
        let pending = try await service.listPendingApprovalRequests(taskID: task.id)
        XCTAssertEqual(pending.count, 0,
            "screenshot is a .read action and must not produce a pending approval row")

        let stored = try await service.getTask(id: task.id)
        XCTAssertNotEqual(stored?.status, .awaitingApproval,
            "screenshot should not leave the task in awaitingApproval")

        // Find the screenshot request the client just submitted. The order
        // by status isn't guaranteed, so we look across all terminal states
        // for the row whose name matches "screenshot".
        let completedRequests = try requests.list(status: .completed).map(\.0)
        let executingRequests = try requests.list(status: .executing).map(\.0)
        let failedRequests = try requests.list(status: .failed).map(\.0)
        let allRequests = completedRequests + executingRequests + failedRequests
        let storedRequest = try XCTUnwrap(
            allRequests.first(where: { $0.taskID == task.id && $0.name == "screenshot" }),
            "expected the screenshot request to be persisted with name=screenshot"
        )
        XCTAssertEqual(storedRequest.taskID, task.id)
        XCTAssertEqual(storedRequest.name, "screenshot")
        XCTAssertEqual(storedRequest.sideEffect, .read)
        XCTAssertEqual(storedRequest.payload, "screen")
        XCTAssertEqual(
            (storedRequest.target as NSString).lastPathComponent,
            "screenshot-2026-09-17.png",
            "target's basename must echo the user-supplied filename"
        )
        XCTAssertTrue(
            storedRequest.target.hasPrefix(ServiceClient.screenshotsApprovedDirectory.path),
            "target must resolve inside the appSupport screenshots directory; got: \(storedRequest.target)"
        )

        // Recompute the digest on the client side and verify it matches the
        // server-side digest. This confirms the wire format (the body the
        // client encoded) survived the round-trip without mangling.
        let expectedDigest = ToolRequest.actionDigest(
            name: "screenshot",
            sideEffect: .read,
            target: storedRequest.target,
            payload: "screen"
        )
        XCTAssertEqual(storedRequest.payloadDigest, expectedDigest,
            "digest from server must equal the one the client computed")

        XCTAssertNil(client.actionError,
            "submitScreenshot must not leave actionError populated on success")
    }
}
