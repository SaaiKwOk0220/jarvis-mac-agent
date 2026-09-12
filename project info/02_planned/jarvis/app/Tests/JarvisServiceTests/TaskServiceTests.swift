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
}

private final class Fixture {
    let database: Database
    let tasks: SQLiteTaskRepository
    let audit: SQLiteAuditRepository
    let service: TaskService

    init() throws {
        database = try Database(path: ":memory:")
        try database.migrate()
        tasks = SQLiteTaskRepository(database: database)
        audit = SQLiteAuditRepository(database: database)
        service = TaskService(
            taskRepository: tasks,
            auditRepository: audit,
            policy: Policy(),
            policyConfig: PolicyConfig(approvedDirectories: ["/tmp/jarvis-service"])
        )
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
