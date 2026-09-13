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
        let body = try JSONEncoder().encode([Task(id: id, title: "demo")])
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
}
