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
            if try fixture.requests.fetch(id: request.id)?.1 == .completed { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(try fixture.tasks.fetch(id: task.id)?.status, .running,
            "Task stays .running after executor success; call complete(taskID:) to finish")
        XCTAssertEqual(try fixture.requests.fetch(id: request.id)?.1, .completed)
        XCTAssertTrue(try fixture.audit.events(for: task.id).contains { $0.summary == "tool result" })

        try await fixture.service.complete(taskID: task.id)
        XCTAssertEqual(try fixture.tasks.fetch(id: task.id)?.status, .completed,
            "complete(taskID:) transitions the running task to .completed")
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
        let task = try JSONDecoder().decode(JarvisTask.self, from: create.body)

        let list = await server.handle(method: "GET", path: "/tasks", body: Data(), peerHost: "::1")
        XCTAssertEqual(list.status, 200)
        XCTAssertEqual(try JSONDecoder().decode([JarvisTask].self, from: list.body).map(\.id), [task.id])

        let detail = await server.handle(method: "GET", path: "/tasks/\(task.id.uuidString)", body: Data(), peerHost: "127.0.0.1")
        XCTAssertEqual(detail.status, 200)
        XCTAssertEqual(try JSONDecoder().decode(JarvisTask.self, from: detail.body).id, task.id)

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
        XCTAssertEqual(try JSONDecoder().decode(JarvisTask.self, from: data).title, "Socket task")
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

    func testShellRequestRoutesToTerminalExecutor() async throws {
        let fixture = try Fixture(terminal: TerminalToolExecutor(timeout: .seconds(5)))
        let task = try await fixture.service.createTask(title: "Run shell through service")
        let request = ToolRequest(
            taskID: task.id,
            name: "shell",
            sideEffect: .localExecute,
            target: "/tmp/jarvis-service",
            payload: "echo routed"
        )

        let decision = try await fixture.service.submit(request: request)
        XCTAssertEqual(decision, .requireApproval(reason: "shell command requires explicit approval"))

        try await fixture.service.approve(requestID: request.id, digest: request.payloadDigest)

        for _ in 0..<100 {
            if try fixture.requests.fetch(id: request.id)?.1 == .completed { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(try fixture.tasks.fetch(id: task.id)?.status, .running,
            "Task stays .running after TerminalToolExecutor finishes; call complete(taskID:) to finish")
        XCTAssertEqual(try fixture.requests.fetch(id: request.id)?.1, .completed)
        XCTAssertTrue(
            try fixture.audit.events(for: task.id).contains { $0.summary == "tool result" && $0.result.contains("routed") },
            "audit must show TerminalToolExecutor output, not NoOp"
        )
    }

    func testShellRequestRequiresExplicitApproval() async throws {
        let fixture = try Fixture(terminal: TerminalToolExecutor(timeout: .seconds(5)))
        let task = try await fixture.service.createTask(title: "Shell awaits approval")
        let request = ToolRequest(
            taskID: task.id,
            name: "shell",
            sideEffect: .localExecute,
            target: "/tmp/jarvis-service",
            payload: "echo not-yet"
        )

        let decision = try await fixture.service.submit(request: request)

        XCTAssertEqual(decision, .requireApproval(reason: "shell command requires explicit approval"))
        XCTAssertEqual(try fixture.tasks.fetch(id: task.id)?.status, .awaitingApproval)
        XCTAssertEqual(try fixture.requests.fetch(id: request.id)?.1, .pending)
    }

    /// Verifies that `submit(request:)` reaches the TerminalToolExecutor for a
    /// shell command by looking for the executor's "exit=0" marker in the
    /// audit summary. This is distinct from `testShellRequestRoutesToTerminalExecutor`
    /// above which checks for an arbitrary echoed string — this test pins
    /// the executor's output format so future refactors can't silently swap
    /// in the NoOpToolExecutor.
    func testSubmitShellCommandReachesTerminalExecutor() async throws {
        let fixture = try Fixture(terminal: TerminalToolExecutor(timeout: .seconds(5)))
        let task = try await fixture.service.createTask(title: "Menu shell command")
        let request = ToolRequest(
            taskID: task.id,
            name: "shell",
            sideEffect: .localExecute,
            target: "/tmp/jarvis-service",
            payload: "echo hello-shell-ui"
        )

        _ = try await fixture.service.submit(request: request)
        try await fixture.service.approve(requestID: request.id, digest: request.payloadDigest)

        for _ in 0..<100 {
            if try fixture.requests.fetch(id: request.id)?.1 == .completed { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(try fixture.tasks.fetch(id: task.id)?.status, .running,
            "Task stays .running after TerminalToolExecutor finishes; call complete(taskID:) to finish")
        XCTAssertEqual(try fixture.requests.fetch(id: request.id)?.1, .completed)
        let toolResultAudit = try fixture.audit.events(for: task.id).first { $0.summary == "tool result" }
        XCTAssertNotNil(toolResultAudit, "expected a 'tool result' audit after Terminal executor finishes")
        XCTAssertTrue(
            toolResultAudit?.result.contains("exit=0") == true,
            "audit must carry TerminalToolExecutor's exit=0 marker; got: \(toolResultAudit?.result ?? "<nil>")"
        )
    }

    /// Pins the executor dispatch contract: a `name == "fetch"` request with
    /// `sideEffect == .read` must reach the WebFetchToolExecutor when one is
    /// installed. We assert on the executor's own marker ("HTTP 200") rather
    /// than the body so the assertion survives any change to the canned body
    /// string while still detecting a silent fall-through to NoOpToolExecutor.
    func testFetchRequestRoutesToWebFetchExecutor() async throws {
        let body = "hello-from-mock"
        let session = MockURLSessionFactory.make()
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/plain"])!
            return (response, Data(body.utf8))
        }
        defer { MockURLProtocol.handler = nil }

        let executor = WebFetchToolExecutor(session: session)
        let fixture = try Fixture(webFetch: executor)
        let task = try await fixture.service.createTask(title: "Fetch through service")
        let request = ToolRequest(
            taskID: task.id,
            name: "fetch",
            sideEffect: .read,
            target: "https://example.com/path",
            payload: "https://example.com/path",
            scope: ToolScope(browserProfile: "default")
        )

        let decision = try await fixture.service.submit(request: request)

        XCTAssertEqual(decision, .allow,
            "fetch should be allowed by policy without approval")
        for _ in 0..<100 {
            if try fixture.requests.fetch(id: request.id)?.1 == .completed { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(try fixture.tasks.fetch(id: task.id)?.status, .running,
            "Task stays .running after WebFetchToolExecutor finishes; call complete(taskID:) to finish")
        XCTAssertEqual(try fixture.requests.fetch(id: request.id)?.1, .completed)
        let toolResultAudit = try fixture.audit.events(for: task.id).first { $0.summary == "tool result" }
        XCTAssertNotNil(toolResultAudit, "expected a 'tool result' audit after fetch executor finishes")
        XCTAssertTrue(
            toolResultAudit?.result.contains("HTTP 200") == true,
            "audit must carry WebFetchToolExecutor's HTTP status marker; got: \(toolResultAudit?.result ?? "<nil>")"
        )
        XCTAssertTrue(
            toolResultAudit?.result.contains(body) == true,
            "audit must carry the fetched body so the user can see it; got: \(toolResultAudit?.result ?? "<nil>")"
        )
    }

    /// Pins the executor dispatch contract for screenshots: a
    /// `name == "screenshot"` request with `sideEffect == .read` must reach
    /// the `ScreenshotToolExecutor` when one is installed. The mock closure
    /// returns the PNG magic bytes so we can detect fall-through to a
    /// different executor (the NoOpToolExecutor would produce
    /// "demo executor completed"). The audit log carries the
    /// `ScreenshotToolExecutor`'s own summary format so the assertion
    /// pins the executor identity, not just that *some* tool ran.
    func testScreenshotRequestRoutesToScreenshotExecutor() async throws {
        let executor = ScreenshotToolExecutor(capture: { Data([0x89, 0x50, 0x4E, 0x47]) })
        let fixture = try Fixture(screenshot: executor)
        let task = try await fixture.service.createTask(title: "Screenshot through service")
        let request = ToolRequest(
            taskID: task.id,
            name: "screenshot",
            sideEffect: .read,
            target: "/tmp/jarvis-service/test.png",
            payload: "screen"
        )

        let decision = try await fixture.service.submit(request: request)
        XCTAssertEqual(decision, .allow,
            "screenshot is a .read action that lands inside an approved directory; policy should allow without approval")

        for _ in 0..<100 {
            if try fixture.requests.fetch(id: request.id)?.1 == .completed { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(try fixture.tasks.fetch(id: task.id)?.status, .running,
            "Task stays .running after ScreenshotToolExecutor finishes; call complete(taskID:) to finish")
        XCTAssertEqual(try fixture.requests.fetch(id: request.id)?.1, .completed)
        let toolResultAudit = try fixture.audit.events(for: task.id).first { $0.summary == "tool result" }
        XCTAssertNotNil(toolResultAudit, "expected a 'tool result' audit after Screenshot executor finishes")
        XCTAssertTrue(
            toolResultAudit?.result.contains("Screenshot saved") == true,
            "audit must carry ScreenshotToolExecutor's summary marker; got: \(toolResultAudit?.result ?? "<nil>")"
        )
        XCTAssertFalse(
            toolResultAudit?.result.contains("demo executor completed") == true,
            "audit must not show the NoOp executor's marker; got: \(toolResultAudit?.result ?? "<nil>")"
        )
    }

    /// Pins the executor dispatch contract for accessibility queries: a
    /// `name == "ax_query"` request with `sideEffect == .read` and a bundle-ID
    /// target must reach the `AccessibilityQueryToolExecutor` when one is
    /// installed. The mock closure returns a distinctive tree string so we can
    /// detect fall-through to a different executor (the NoOpToolExecutor would
    /// produce "demo executor completed"). The bundle ID is allowlisted in the
    /// Fixture's `PolicyConfig.applicationBundleIDs`, so the read-side policy
    /// gate allows the request without approval.
    func testAccessibilityQueryRoutesToExecutor() async throws {
        let executor = AccessibilityQueryToolExecutor(query: { _ in "mock accessibility tree" })
        let fixture = try Fixture(accessibility: executor)
        let task = try await fixture.service.createTask(title: "AX query through service")
        let request = ToolRequest(
            taskID: task.id,
            name: "ax_query",
            sideEffect: .read,
            target: "com.apple.Safari",
            payload: ""
        )

        let decision = try await fixture.service.submit(request: request)
        XCTAssertEqual(decision, .allow,
            "ax_query is a .read action against an allowlisted bundle ID; policy should allow without approval")

        for _ in 0..<100 {
            if try fixture.requests.fetch(id: request.id)?.1 == .completed { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(try fixture.tasks.fetch(id: task.id)?.status, .running,
            "Task stays .running after AccessibilityQueryToolExecutor finishes; call complete(taskID:) to finish")
        XCTAssertEqual(try fixture.requests.fetch(id: request.id)?.1, .completed)
        let toolResultAudit = try fixture.audit.events(for: task.id).first { $0.summary == "tool result" }
        XCTAssertNotNil(toolResultAudit, "expected a 'tool result' audit after the AX executor finishes")
        XCTAssertTrue(
            toolResultAudit?.result.contains("mock accessibility tree") == true,
            "audit must carry the accessibility tree so the user can see it; got: \(toolResultAudit?.result ?? "<nil>")"
        )
        XCTAssertFalse(
            toolResultAudit?.result.contains("demo executor completed") == true,
            "audit must not show the NoOp executor's marker; got: \(toolResultAudit?.result ?? "<nil>")"
        )
    }

    /// Drives a single executor run to completion and then verifies that
    /// `complete(taskID:)` is the only path that moves the task to
    /// `.completed`. After the executor finishes the task must be `.running`;
    /// the new action emits a "task completed" audit event so the user can
    /// see the call in the timeline.
    func testCompleteTransitionsRunningTaskToCompleted() async throws {
        let fixture = try Fixture()
        let task = try await fixture.service.createTask(title: "Complete happy path")
        let request = ToolRequest(taskID: task.id, name: "read_file", sideEffect: .read,
            target: "/tmp/jarvis-service/anything", payload: "")
        _ = try await fixture.service.submit(request: request)

        for _ in 0..<50 {
            if try fixture.requests.fetch(id: request.id)?.1 == .completed { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }

        XCTAssertEqual(try fixture.tasks.fetch(id: task.id)?.status, .running,
            "executor success leaves the task in .running; complete(taskID:) is the only path to .completed")

        try await fixture.service.complete(taskID: task.id)
        XCTAssertEqual(try fixture.tasks.fetch(id: task.id)?.status, .completed,
            "complete(taskID:) must transition .running -> .completed")
        XCTAssertTrue(try fixture.audit.events(for: task.id).contains { $0.summary == "task completed" },
            "complete(taskID:) must record a 'task completed' audit event")
    }

    /// `complete(taskID:)` must reject calls made on a task that has already
    /// reached a terminal state (`.completed`, `.cancelled`, `.failed`) with
    /// `illegalTransition`. The test exercises each terminal state in turn.
    func testCompleteRejectsAlreadyTerminalTask() async throws {
        // .completed: drive a successful run then complete() twice
        let fixture = try Fixture()
        let completedTask = try await fixture.service.createTask(title: "Already completed")
        let completedRequest = ToolRequest(taskID: completedTask.id, name: "read_file", sideEffect: .read,
            target: "/tmp/jarvis-service/anything", payload: "")
        _ = try await fixture.service.submit(request: completedRequest)
        for _ in 0..<50 {
            if try fixture.requests.fetch(id: completedRequest.id)?.1 == .completed { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        try await fixture.service.complete(taskID: completedTask.id)
        XCTAssertEqual(try fixture.tasks.fetch(id: completedTask.id)?.status, .completed)

        await XCTAssertThrowsErrorAsync(try await fixture.service.complete(taskID: completedTask.id)) {
            XCTAssertEqual($0 as? TaskServiceError, .illegalTransition(from: .completed, to: .completed))
        }

        // .cancelled: cancel and try to complete
        let cancelledTask = try await fixture.service.createTask(title: "Already cancelled")
        try await fixture.service.cancel(taskID: cancelledTask.id)
        XCTAssertEqual(try fixture.tasks.fetch(id: cancelledTask.id)?.status, .cancelled)
        await XCTAssertThrowsErrorAsync(try await fixture.service.complete(taskID: cancelledTask.id)) {
            XCTAssertEqual($0 as? TaskServiceError, .illegalTransition(from: .cancelled, to: .completed))
        }

        // .failed: trigger an executor failure then try to complete
        let failingFixture = try Fixture(executor: ThrowingExecutor())
        let failedTask = try await failingFixture.service.createTask(title: "Already failed")
        let failedRequest = ToolRequest(taskID: failedTask.id, name: "read_file", sideEffect: .read,
            target: "/tmp/jarvis-service/anything", payload: "")
        await XCTAssertThrowsErrorAsync(try await failingFixture.service.submit(request: failedRequest))
        XCTAssertEqual(try failingFixture.tasks.fetch(id: failedTask.id)?.status, .failed)
        await XCTAssertThrowsErrorAsync(try await failingFixture.service.complete(taskID: failedTask.id)) {
            XCTAssertEqual($0 as? TaskServiceError, .illegalTransition(from: .failed, to: .completed))
        }
    }

    /// Pins the multi-request behaviour: a single task carries two sequential
    /// tool requests, both run to completion, the task stays in `.running`
    /// throughout, and only the explicit `complete(taskID:)` call moves it
    /// to `.completed`. This is the core contract that the rest of the
    /// multi-request workflow depends on.
    func testMultiRequestWorkflowExecutesSequentially() async throws {
        let fixture = try Fixture()
        let task = try await fixture.service.createTask(title: "Multi-request workflow")

        // First request: .read action, allowed by policy, runs to completion.
        let first = ToolRequest(taskID: task.id, name: "read_file", sideEffect: .read,
            target: "/tmp/jarvis-service/first.txt", payload: "")
        let firstDecision = try await fixture.service.submit(request: first)
        XCTAssertEqual(firstDecision, .allow, "first .read request must be allowed without approval")

        for _ in 0..<50 {
            if try fixture.requests.fetch(id: first.id)?.1 == .completed { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertEqual(try fixture.requests.fetch(id: first.id)?.1, .completed,
            "first request must reach .completed")
        XCTAssertEqual(try fixture.tasks.fetch(id: task.id)?.status, .running,
            "after first request the task stays in .running; submit() can drive another request")

        // Second request on the SAME task: .localWrite requires approval, lands in
        // .awaitingApproval. Without explicit complete() the task must remain
        // .running throughout.
        let second = ToolRequest(taskID: task.id, name: "write_file", sideEffect: .localWrite,
            target: "/tmp/jarvis-service/second.txt", payload: "second-step")
        let secondDecision = try await fixture.service.submit(request: second)
        XCTAssertEqual(secondDecision, .requireApproval(reason: "local write changes local state"),
            "second request must require approval before the executor runs")
        XCTAssertEqual(try fixture.tasks.fetch(id: task.id)?.status, .awaitingApproval,
            "task moves to .awaitingApproval when the second request needs approval")
        XCTAssertEqual(try fixture.requests.fetch(id: second.id)?.1, .pending)

        // Approve the second request and wait for the executor to finish.
        try await fixture.service.approve(requestID: second.id, digest: second.payloadDigest)
        for _ in 0..<50 {
            if try fixture.requests.fetch(id: second.id)?.1 == .completed { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertEqual(try fixture.requests.fetch(id: second.id)?.1, .completed,
            "second request must reach .completed after approval")
        XCTAssertEqual(try fixture.tasks.fetch(id: task.id)?.status, .running,
            "task stays in .running after second executor finishes")

        // Now both requests have run; explicit complete() must move the task to .completed.
        try await fixture.service.complete(taskID: task.id)
        XCTAssertEqual(try fixture.tasks.fetch(id: task.id)?.status, .completed,
            "complete(taskID:) must transition the task to .completed after both requests ran")

        // Audit log must show both tool results and the explicit completion.
        let summaries = try fixture.audit.events(for: task.id).map(\.summary)
        XCTAssertEqual(summaries.filter { $0 == "tool result" }.count, 2,
            "audit must record a 'tool result' event for each of the two executor runs")
        XCTAssertTrue(summaries.contains("task completed"),
            "audit must record the explicit complete(taskID:) call")
    }

    // MARK: - Concurrent pending approvals

    /// Pins the core capability of this change: a single task may hold more than
    /// one `.pending` approval at a time. Submitting a second `.localWrite`
    /// request while the first is still pending must succeed, leave the task in
    /// `.awaitingApproval`, and expose both requests through
    /// `listPendingApprovalRequests(taskID:)`.
    func testTwoPendingApprovalsCoexistOnOneTask() async throws {
        let fixture = try Fixture()
        let (task, first, second) = try await fixture.makeTaskWithTwoPendingApprovals(title: "Two pending approvals")

        XCTAssertEqual(try fixture.tasks.fetch(id: task.id)?.status, .awaitingApproval,
            "the task stays in .awaitingApproval while any request is pending")
        XCTAssertEqual(try fixture.requests.fetch(id: first.id)?.1, .pending)
        XCTAssertEqual(try fixture.requests.fetch(id: second.id)?.1, .pending)

        let pending = try await fixture.service.listPendingApprovalRequests(taskID: task.id)
        XCTAssertEqual(Set(pending.map(\.id)), Set([first.id, second.id]),
            "both pending approvals must be visible to the approver UI")
    }

    /// Approving one of two pending requests must not clear `.awaitingApproval`:
    /// the second request still needs a decision, so the task status is
    /// aggregated from the outstanding requests rather than hard-coded.
    func testApprovingOneOfTwoPendingsKeepsTaskAwaitingApproval() async throws {
        let fixture = try Fixture()
        let (task, first, second) = try await fixture.makeTaskWithTwoPendingApprovals(title: "Approve one of two")

        try await fixture.service.approve(requestID: first.id, digest: first.payloadDigest)
        try await fixture.waitForRequest(id: first.id, status: .completed)

        XCTAssertEqual(try fixture.tasks.fetch(id: task.id)?.status, .awaitingApproval,
            "the second pending request keeps the task in .awaitingApproval after the first is approved")
        XCTAssertEqual(try fixture.requests.fetch(id: second.id)?.1, .pending,
            "the untouched request must remain pending")
    }

    /// Approving the last outstanding pending request runs it and, because no
    /// request is left outstanding, returns the task to `.running` — the same
    /// resting state a single-request approval produces.
    func testApprovingBothPendingsRunsBothAndReturnsToRunning() async throws {
        let fixture = try Fixture()
        let (task, first, second) = try await fixture.makeTaskWithTwoPendingApprovals(title: "Approve both")

        try await fixture.service.approve(requestID: first.id, digest: first.payloadDigest)
        try await fixture.waitForRequest(id: first.id, status: .completed)
        XCTAssertEqual(try fixture.tasks.fetch(id: task.id)?.status, .awaitingApproval,
            "the task waits for the second decision")

        try await fixture.service.approve(requestID: second.id, digest: second.payloadDigest)
        try await fixture.waitForRequest(id: second.id, status: .completed)

        XCTAssertEqual(try fixture.requests.fetch(id: first.id)?.1, .completed)
        XCTAssertEqual(try fixture.requests.fetch(id: second.id)?.1, .completed)
        XCTAssertEqual(try fixture.tasks.fetch(id: task.id)?.status, .running,
            "with nothing outstanding the task returns to .running after the executor finishes")
        XCTAssertEqual(try fixture.audit.events(for: task.id).filter { $0.summary == "tool result" }.count, 2,
            "each approved request must record its own 'tool result' audit event")
    }

    /// Rejecting one of two pendings leaves the task `.awaitingApproval` and
    /// keeps the other request actionable: the surviving request can still be
    /// approved and run to completion.
    func testRejectingOneOfTwoPendingsKeepsOtherActionable() async throws {
        let fixture = try Fixture()
        let (task, first, second) = try await fixture.makeTaskWithTwoPendingApprovals(title: "Reject one of two")

        try await fixture.service.reject(requestID: first.id)

        XCTAssertEqual(try fixture.requests.fetch(id: first.id)?.1, .rejected)
        XCTAssertEqual(try fixture.tasks.fetch(id: task.id)?.status, .awaitingApproval,
            "the surviving pending request keeps the task in .awaitingApproval")
        XCTAssertEqual(try fixture.requests.fetch(id: second.id)?.1, .pending)

        try await fixture.service.approve(requestID: second.id, digest: second.payloadDigest)
        try await fixture.waitForRequest(id: second.id, status: .completed)

        XCTAssertEqual(try fixture.requests.fetch(id: second.id)?.1, .completed,
            "the request that outlived the rejection must still be approvable")
        XCTAssertEqual(try fixture.tasks.fetch(id: task.id)?.status, .running)
    }

    /// Rejecting the *last* outstanding pending request preserves the original
    /// single-request semantics: the task lands in `.blocked`.
    func testRejectingLastPendingBlocksTask() async throws {
        let fixture = try Fixture()
        let (task, first, second) = try await fixture.makeTaskWithTwoPendingApprovals(title: "Reject both")

        try await fixture.service.reject(requestID: first.id)
        XCTAssertEqual(try fixture.tasks.fetch(id: task.id)?.status, .awaitingApproval,
            "one pending request remains after the first rejection")

        try await fixture.service.reject(requestID: second.id)

        XCTAssertEqual(try fixture.requests.fetch(id: first.id)?.1, .rejected)
        XCTAssertEqual(try fixture.requests.fetch(id: second.id)?.1, .rejected)
        XCTAssertEqual(try fixture.tasks.fetch(id: task.id)?.status, .blocked,
            "rejecting the last pending request blocks the task, as before")
    }

    /// A task that is `.awaitingApproval` is still alive, so an `.allow`
    /// request may be submitted and executed without disturbing the pending
    /// approval. Once the executor finishes, the task must fall back to
    /// `.awaitingApproval` because a decision is still owed.
    func testSubmittingWhileAwaitingApprovalIsAllowed() async throws {
        let fixture = try Fixture()
        let task = try await fixture.service.createTask(title: "Submit while awaiting approval")
        let pendingRequest = ToolRequest(taskID: task.id, name: "write_file", sideEffect: .localWrite,
            target: "/tmp/jarvis-service/needs-approval.txt", payload: "gated contents")
        let pendingDecision = try await fixture.service.submit(request: pendingRequest)
        XCTAssertEqual(pendingDecision, .requireApproval(reason: "local write changes local state"))
        XCTAssertEqual(try fixture.tasks.fetch(id: task.id)?.status, .awaitingApproval)

        let readRequest = ToolRequest(taskID: task.id, name: "read_file", sideEffect: .read,
            target: "/tmp/jarvis-service/reads-freely.txt", payload: "")
        let decision = try await fixture.service.submit(request: readRequest)

        XCTAssertEqual(decision, .allow, "a .read request is allowed even while an approval is pending")
        XCTAssertEqual(try fixture.requests.fetch(id: readRequest.id)?.1, .completed,
            "the allowed request executes immediately")
        XCTAssertEqual(try fixture.requests.fetch(id: pendingRequest.id)?.1, .pending,
            "the pending approval is untouched by the allowed request")
        XCTAssertEqual(try fixture.tasks.fetch(id: task.id)?.status, .awaitingApproval,
            "the outstanding pending approval keeps the task in .awaitingApproval")
    }

    /// Cancelling a task must sweep up every outstanding request, not just the
    /// first one, and record the task as `.cancelled`.
    func testCancelWithMultiplePendingsCancelsAll() async throws {
        let fixture = try Fixture()
        let (task, first, second) = try await fixture.makeTaskWithTwoPendingApprovals(title: "Cancel multiple pendings")

        try await fixture.service.cancel(taskID: task.id)

        XCTAssertEqual(try fixture.tasks.fetch(id: task.id)?.status, .cancelled)
        XCTAssertEqual(try fixture.requests.fetch(id: first.id)?.1, .cancelled)
        XCTAssertEqual(try fixture.requests.fetch(id: second.id)?.1, .cancelled,
            "every pending request must be cancelled alongside the task")
    }

    /// Regression guard for the already-working `.allow` path: two concurrent
    /// allowed requests on one task both run to completion — unlike
    /// `testCancellationCancelsMultipleExecutionsForOneTask`, nothing cancels
    /// them. This is the behaviour the approval changes must not disturb.
    func testConcurrentAllowRequestsRunInParallel() async throws {
        let executor = MultiSuspendingExecutor()
        let fixture = try Fixture(executor: executor)
        let task = try await fixture.service.createTask(title: "Parallel allow requests")
        let requests = (0..<2).map { ToolRequest(taskID: task.id, name: "read_file", sideEffect: .read,
            target: "/tmp/jarvis-service/\($0)", payload: "") }
        let submissions = requests.map { request in Task.detached { try? await fixture.service.submit(request: request) } }
        await executor.started(ids: Set(requests.map(\.id)))

        requests.forEach { executor.resume(id: $0.id) }
        for submission in submissions { _ = await submission.result }

        for request in requests {
            XCTAssertEqual(try fixture.requests.fetch(id: request.id)?.1, .completed,
                "both allowed requests must reach .completed when nothing cancels them")
        }
        XCTAssertEqual(try fixture.tasks.fetch(id: task.id)?.status, .running)
        XCTAssertEqual(try fixture.audit.events(for: task.id).filter { $0.summary == "tool result" }.count, 2)
    }

    /// The state machine must tolerate status-preserving writes. Approving or
    /// submitting while the task is already `.running` or `.awaitingApproval`
    /// rewrites the same value, which would otherwise be an illegal transition.
    func testStateMachineAllowsSelfTransitions() throws {
        XCTAssertNoThrow(try TaskStateMachine.validate(from: .running, to: .running))
        XCTAssertNoThrow(try TaskStateMachine.validate(from: .awaitingApproval, to: .awaitingApproval))
        XCTAssertTrue(TaskStateMachine.allowedDestinations(for: .running).contains(.running))
        XCTAssertTrue(TaskStateMachine.allowedDestinations(for: .awaitingApproval).contains(.awaitingApproval))
    }
}

private final class Fixture: @unchecked Sendable {
    let database: Database
    let tasks: SQLiteTaskRepository
    let audit: SQLiteAuditRepository
    let requests: SQLiteToolRequestRepository
    let approvals: SQLiteApprovalRepository
    let service: TaskService

    init(executor: any ToolExecutor = NoOpToolExecutor(), terminal: TerminalToolExecutor? = nil, webFetch: WebFetchToolExecutor? = nil, screenshot: ScreenshotToolExecutor? = nil, accessibility: AccessibilityQueryToolExecutor? = nil) throws {
        database = try Database(path: ":memory:")
        try database.migrate()
        tasks = SQLiteTaskRepository(database: database)
        audit = SQLiteAuditRepository(database: database)
        requests = SQLiteToolRequestRepository(database: database)
        approvals = SQLiteApprovalRepository(database: database)
        let policyConfig = PolicyConfig(
            approvedDirectories: ["/tmp/jarvis-service"],
            commandNames: ["shell", "swift", "xcodebuild"],
            browserProfiles: ["default"],
            sites: ["example.com"],
            applicationBundleIDs: ["com.apple.Safari"]
        )
        service = try TaskService(
            taskRepository: tasks,
            auditRepository: audit,
            policy: Policy(),
            policyConfig: policyConfig, executor: executor, terminal: terminal, webFetch: webFetch, screenshot: screenshot, accessibility: accessibility,
            requestRepository: requests, approvalRepository: approvals, unitOfWork: SQLitePersistenceUnitOfWork(database: database)
        )
    }

    func makeService() throws -> TaskService {
        try TaskService(taskRepository: tasks, auditRepository: audit, policy: Policy(), policyConfig: PolicyConfig(approvedDirectories: ["/tmp/jarvis-service"]), requestRepository: requests, approvalRepository: approvals, unitOfWork: SQLitePersistenceUnitOfWork(database: database))
    }

    /// Creates a task and submits two `.localWrite` requests. The deterministic
    /// policy routes both to `.requireApproval`, so the task ends up in
    /// `.awaitingApproval` holding two `.pending` requests — the concurrent
    /// pending-approval state this suite exercises. Returns the task and both
    /// requests in submission order.
    func makeTaskWithTwoPendingApprovals(title: String) async throws -> (JarvisTask, ToolRequest, ToolRequest) {
        let task = try await service.createTask(title: title)
        let first = ToolRequest(taskID: task.id, name: "write_file", sideEffect: .localWrite,
            target: "/tmp/jarvis-service/first.txt", payload: "first payload")
        let second = ToolRequest(taskID: task.id, name: "write_file", sideEffect: .localWrite,
            target: "/tmp/jarvis-service/second.txt", payload: "second payload")
        let firstDecision = try await service.submit(request: first)
        let secondDecision = try await service.submit(request: second)
        XCTAssertEqual(firstDecision, .requireApproval(reason: "local write changes local state"))
        XCTAssertEqual(secondDecision, .requireApproval(reason: "local write changes local state"))
        XCTAssertEqual(try tasks.fetch(id: task.id)?.status, .awaitingApproval)
        return (task, first, second)
    }

    /// Polls until the request reaches `status`, matching the wait loops the
    /// rest of the suite uses for executor-backed work. A timeout simply
    /// returns, letting the caller's assertion report the mismatch.
    func waitForRequest(id: UUID, status: ToolRequestStatus, iterations: Int = 100) async throws {
        for _ in 0..<iterations {
            if try requests.fetch(id: id)?.1 == status { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
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
