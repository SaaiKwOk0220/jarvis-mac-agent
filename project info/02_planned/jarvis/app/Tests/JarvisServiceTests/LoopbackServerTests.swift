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
