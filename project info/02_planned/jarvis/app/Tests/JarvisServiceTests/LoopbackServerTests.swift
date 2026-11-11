import Darwin
import Foundation
import XCTest
import JarvisDomain
import JarvisPersistence
import JarvisPolicy
@testable import JarvisService

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

    func testNetworkRoutesRejectMissingOrIncorrectAuthorization() async throws {
        let (service, _, _, _, _, _) = try makeService()
        let server = LoopbackServer(service: service)
        let port = try await server.start()
        defer { server.stop() }
        let id = UUID().uuidString
        let routes = [("GET", "/tasks"), ("POST", "/tasks"), ("GET", "/tasks/\(id)"), ("GET", "/tasks/\(id)/requests"), ("GET", "/tasks/\(id)/timeline"), ("POST", "/tasks/\(id)/requests"), ("POST", "/tasks/\(id)/demo-approval"), ("POST", "/tasks/\(id)/cancel"), ("POST", "/tasks/\(id)/complete"), ("POST", "/requests/\(id)/approve"), ("POST", "/requests/\(id)/reject")]
        for (method, path) in routes {
            for token in [nil, "Bearer wrong"] as [String?] {
                var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
                request.httpMethod = method
                if let token { request.setValue(token, forHTTPHeaderField: "Authorization") }
                let (_, response) = try await URLSession.shared.data(for: request)
                XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 403, "\(method) \(path)")
            }
        }
    }

    func testEntropyFailurePreventsServerStart() async throws {
        let (service, _, _, _, _, _) = try makeService()
        for token in [nil, "short", String(repeating: "z", count: 64)] as [String?] {
            let server = LoopbackServer(service: service, tokenProvider: { token })
            XCTAssertNil(server.authorizationToken)
            do { _ = try await server.start(); XCTFail("must fail closed") } catch { }
        }
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
            payload: "pwd"
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
private struct SlowListService: TaskServiceAPI {
    let underlying: TaskService
    func createTask(title: String) async throws -> JarvisTask { try await Task.sleep(nanoseconds: 1_000_000_000); return try await underlying.createTask(title: title) }
    func getTask(id: UUID) async throws -> JarvisTask? { try await underlying.getTask(id: id) }
    func listTasks() async throws -> [JarvisTask] { try await Task.sleep(nanoseconds: 6_000_000_000); return try await underlying.listTasks() }
    func submit(request: ToolRequest) async throws -> PolicyDecision { try await underlying.submit(request: request) }
    func approve(requestID: UUID, digest: String) async throws { try await underlying.approve(requestID: requestID, digest: digest) }
    func reject(requestID: UUID) async throws { try await underlying.reject(requestID: requestID) }
    func cancel(taskID: UUID) async throws { try await underlying.cancel(taskID: taskID) }
    func complete(taskID: UUID) async throws { try await underlying.complete(taskID: taskID) }
    func listPendingApprovalRequests(taskID: UUID) async throws -> [PendingApprovalRequest] { try await underlying.listPendingApprovalRequests(taskID: taskID) }
    func listTimelineEvents(taskID: UUID) async throws -> [TimelineEvent] { try await underlying.listTimelineEvents(taskID: taskID) }
}

private func openSlowSocket(port: UInt16, bytes: String) throws -> Int32 {
    let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw NSError(domain: "socket", code: Int(errno)) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr = in_addr(s_addr: in_addr_t(0x0100007f))
    let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    guard result == 0 else { Darwin.close(fd); throw NSError(domain: "connect", code: Int(errno)) }
    var timeout = timeval(tv_sec: 8, tv_usec: 0)
    _ = withUnsafePointer(to: &timeout) { setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, $0, socklen_t(MemoryLayout<timeval>.size)) }
    let data = Array(bytes.utf8)
    guard data.withUnsafeBytes({ Darwin.send(fd, $0.baseAddress, $0.count, 0) }) == data.count else { Darwin.close(fd); throw NSError(domain: "send", code: Int(errno)) }
    return fd
}

private func sendRawLoopback(port: UInt16, request: String) throws -> String {
    let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw NSError(domain: "test socket", code: Int(errno)) }
    defer { Darwin.close(descriptor) }
    var timeout = timeval(tv_sec: 3, tv_usec: 0)
    _ = withUnsafePointer(to: &timeout) { setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, $0, socklen_t(MemoryLayout<timeval>.size)) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr = in_addr(s_addr: in_addr_t(0x0100007f))
    let connected = withUnsafePointer(to: &address) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard connected == 0 else { throw NSError(domain: "test connect", code: Int(errno)) }
    let bytes = Array(request.utf8)
    let sent = bytes.withUnsafeBytes { raw in Darwin.send(descriptor, raw.baseAddress, raw.count, 0) }
    guard sent == bytes.count else { throw NSError(domain: "test send", code: Int(errno)) }
    var buffer = [UInt8](repeating: 0, count: 4096), data = Data()
    while true {
        let count = Darwin.recv(descriptor, &buffer, buffer.count, 0)
        if count <= 0 { break }
        data.append(contentsOf: buffer.prefix(count))
    }
    return String(decoding: data, as: UTF8.self)
}

extension LoopbackServerTests {
    func testUnauthenticatedIncompleteBodyIsRejectedImmediately() async throws {
        let (service, _, _, _, _, _) = try makeService()
        let server = LoopbackServer(service: service)
        let port = try await server.start()
        defer { server.stop() }
        let response = try sendRawLoopback(port: port, request: "POST /tasks HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nContent-Length: 100000\r\n\r\n")
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 403"))
    }

    func testClientDisconnectDoesNotCancelAcceptedMutation() async throws {
        let (service, _, _, _, _, _) = try makeService()
        let server = LoopbackServer(service: SlowListService(underlying: service))
        let port = try await server.start()
        defer { server.stop() }
        let token = try XCTUnwrap(server.authorizationToken)
        let body = "{\"title\":\"disconnect mutation\"}"
        let fd = try openSlowSocket(port: port, bytes: "POST /tasks HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAuthorization: Bearer \(token)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)")
        try await Task.sleep(nanoseconds: 300_000_000)
        Darwin.close(fd)
        try await Task.sleep(nanoseconds: 1_300_000_000)
        let tasks = try await service.listTasks()
        XCTAssertEqual(tasks.filter { $0.title == "disconnect mutation" }.count, 1)
    }

    func testConcurrentStartsPermitOnlyOneListener() async throws {
        let (service, _, _, _, _, _) = try makeService()
        let server = LoopbackServer(service: service)
        defer { server.stop() }
        let outcomes = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for _ in 0..<12 { group.addTask { (try? await server.start()) != nil } }
            var results: [Bool] = []
            for await outcome in group { results.append(outcome) }
            return results
        }
        XCTAssertEqual(outcomes.filter { $0 }.count, 1)
    }

    func testCompletedRequestAllowsSlowHandlerAndRestart() async throws {
        let (service, _, _, _, _, _) = try makeService()
        let server = LoopbackServer(service: SlowListService(underlying: service))
        var port = try await server.start()
        server.stop()
        port = try await server.start()
        defer { server.stop() }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/tasks")!)
        request.timeoutInterval = 10
        request.setValue("Bearer \(try XCTUnwrap(server.authorizationToken))", forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }

    func testSlowConnectionsExpireAndCapacityRecovers() async throws {
        let (service, _, _, _, _, _) = try makeService()
        let server = LoopbackServer(service: service)
        let port = try await server.start()
        defer { server.stop() }
        let token = try XCTUnwrap(server.authorizationToken)
        var sockets: [Int32] = []
        defer { sockets.forEach { Darwin.close($0) } }
        for index in 0..<32 {
            let request = index == 0
                ? "POST /tasks HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAuthorization: Bearer \(token)\r\nContent-Type: application/json\r\nContent-Length: 100\r\n\r\n{"
                : "GET /tasks HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n"
            sockets.append(try openSlowSocket(port: port, bytes: request))
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        let excess = try openSlowSocket(port: port, bytes: "GET / HTTP/1.1\r\n")
        defer { Darwin.close(excess) }
        var buffer = [UInt8](repeating: 0, count: 16)
        let excessRead = Darwin.recv(excess, &buffer, buffer.count, 0)
        XCTAssertTrue(excessRead == 0 || (excessRead == -1 && errno == ECONNRESET))
        for fd in sockets {
            let count = Darwin.recv(fd, &buffer, buffer.count, 0)
            XCTAssertTrue(count == 0 || (count == -1 && errno == ECONNRESET))
        }
        let response = try sendRawLoopback(port: port, request: "GET /tasks HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAuthorization: Bearer \(token)\r\n\r\n")
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 200"))
    }

    func testAuthenticatedNetworkEnforcesHostOriginAndJSON() async throws {
        let (service, _, _, _, _, _) = try makeService()
        let server = LoopbackServer(service: service)
        let port = try await server.start()
        defer { server.stop() }
        let token = try XCTUnwrap(server.authorizationToken)
        XCTAssertEqual(token.utf8.count, 64)
        let another = LoopbackServer(service: service)
        XCTAssertNotEqual(token, another.authorizationToken)
        let normal = "Host: 127.0.0.1:\(port)\r\nAuthorization: Bearer \(token)\r\n"
        let accepted = try sendRawLoopback(port: port, request: "GET /tasks HTTP/1.1\r\n\(normal)\r\n")
        XCTAssertTrue(accepted.hasPrefix("HTTP/1.1 200"))
        XCTAssertFalse(accepted.contains(token))
        let wrongHost = try sendRawLoopback(port: port, request: "GET /tasks HTTP/1.1\r\nHost: attacker.example\r\nAuthorization: Bearer \(token)\r\n\r\n")
        XCTAssertTrue(wrongHost.hasPrefix("HTTP/1.1 403"))
        let origin = try sendRawLoopback(port: port, request: "GET /tasks HTTP/1.1\r\n\(normal)Origin: https://attacker.example\r\n\r\n")
        XCTAssertTrue(origin.hasPrefix("HTTP/1.1 403"))
        let duplicate = try sendRawLoopback(port: port, request: "GET /tasks HTTP/1.1\r\n\(normal)Authorization: Bearer \(token)\r\n\r\n")
        XCTAssertTrue(duplicate.hasPrefix("HTTP/1.1 403"))
        let badType = try sendRawLoopback(port: port, request: "POST /tasks HTTP/1.1\r\n\(normal)Content-Type: text/plain\r\nContent-Length: 2\r\n\r\n{}")
        XCTAssertTrue(badType.hasPrefix("HTTP/1.1 403"))
        let json = "{\"title\":\"local test\"}"
        let allowedPost = try sendRawLoopback(port: port, request: "POST /tasks HTTP/1.1\r\n\(normal)Content-Type: application/json\r\nContent-Length: \(json.utf8.count)\r\n\r\n\(json)")
        XCTAssertTrue(allowedPost.hasPrefix("HTTP/1.1 201"))
    }
}
