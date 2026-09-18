import Foundation
import XCTest
import JarvisDomain
import JarvisPersistence
import JarvisPolicy
import JarvisService

final class LoopbackServerTests: XCTestCase {
    private func makeService() throws -> (TaskService, Database, SQLiteTaskRepository, SQLiteAuditRepository, SQLiteToolRequestRepository, SQLiteApprovalRepository) {
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
                approvedDirectories: ["/tmp/jarvis-loopback"],
                commandNames: ["shell", "swift", "xcodebuild"]
            ),
            requestRepository: requests,
            approvalRepository: approvals,
            unitOfWork: SQLitePersistenceUnitOfWork(database: database)
        )
        return (service, database, tasks, audit, requests, approvals)
    }

    func testLoopbackServerAcceptsPOSTTaskRequests() async throws {
        let (service, _, _, _, _, _) = try makeService()
        let task = try await service.createTask(title: "POST /requests happy path")
        let server = LoopbackServer(service: service)

        let request = ToolRequest(
            taskID: task.id,
            name: "shell",
            sideEffect: .localExecute,
            target: "/tmp/jarvis-loopback",
            payload: "echo posted"
        )
        let body = try JSONEncoder().encode(request)

        let response = await server.handle(
            method: "POST",
            path: "/tasks/\(task.id.uuidString)/requests",
            body: body,
            peerHost: "127.0.0.1"
        )

        XCTAssertEqual(response.status, 200)
        let json = try JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        let decision = try XCTUnwrap(json?["decision"] as? [String: Any])
        // requireApproval encodes as {"requireApproval":{"_0":"..."}} for the
        // associated value in Foundation's default Codable representation.
        XCTAssertNotNil(decision["requireApproval"],
                        "decision must be requireApproval for a shell request; got: \(decision)")
    }

    func testLoopbackServerRejectsRequestForUnknownTask() async throws {
        let (service, _, _, _, _, _) = try makeService()
        let server = LoopbackServer(service: service)
        let ghostTaskID = UUID()

        let request = ToolRequest(
            taskID: ghostTaskID,
            name: "shell",
            sideEffect: .localExecute,
            target: "/tmp/jarvis-loopback",
            payload: "echo ghost"
        )
        let body = try JSONEncoder().encode(request)

        let response = await server.handle(
            method: "POST",
            path: "/tasks/\(ghostTaskID.uuidString)/requests",
            body: body,
            peerHost: "127.0.0.1"
        )

        XCTAssertEqual(response.status, 404,
                       "POST /tasks/{unknown}/requests must return 404; got \(response.status)")
    }

    /// POST `/tasks/{id}/complete` must return 204 and drive the task to
    /// `.completed`. The endpoint also surfaces `illegalTransition` as a 409
    /// when the task is already terminal — matching the pattern other
    /// task-mutation endpoints use.
    func testLoopbackServerAcceptsPOSTTaskComplete() async throws {
        let (service, _, _, _, requests, _) = try makeService()
        let server = LoopbackServer(service: service)
        let task = try await service.createTask(title: "POST /complete happy path")
        let request = ToolRequest(
            taskID: task.id,
            name: "read_file",
            sideEffect: .read,
            target: "/tmp/jarvis-loopback/anything",
            payload: ""
        )
        _ = try await service.submit(request: request)
        // Wait for the executor to finish; the task stays in .running.
        for _ in 0..<50 {
            if try requests.fetch(id: request.id)?.1 == .completed { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }

        let response = await server.handle(
            method: "POST",
            path: "/tasks/\(task.id.uuidString)/complete",
            body: Data(),
            peerHost: "127.0.0.1"
        )
        XCTAssertEqual(response.status, 204,
                       "POST /tasks/{id}/complete must return 204; got \(response.status)")
        let completedStatus = try await service.getTask(id: task.id)?.status
        XCTAssertEqual(completedStatus, .completed,
                       "complete(taskID:) must move the task to .completed")

        // Calling complete again must surface 409 (illegalTransition) — same
        // shape as the cancel endpoint's terminal-state guard.
        let second = await server.handle(
            method: "POST",
            path: "/tasks/\(task.id.uuidString)/complete",
            body: Data(),
            peerHost: "127.0.0.1"
        )
        XCTAssertEqual(second.status, 409,
                       "POST /tasks/{id}/complete on a terminal task must return 409; got \(second.status)")
    }
}