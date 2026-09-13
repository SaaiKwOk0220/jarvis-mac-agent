import XCTest
import JarvisDomain
import JarvisPersistence
import JarvisPolicy
@testable import JarvisService

final class FoundationAcceptanceTests: XCTestCase {
    func testEndToEndApprovalDigestCancellationAndAuditTrail() async throws {
        let database = try Database(path: ":memory:"); try database.migrate()
        let tasks = SQLiteTaskRepository(database: database)
        let audits = SQLiteAuditRepository(database: database)
        let requests = SQLiteToolRequestRepository(database: database)
        let approvals = SQLiteApprovalRepository(database: database)
        let service = try TaskService(taskRepository: tasks, auditRepository: audits, policy: Policy(),
            policyConfig: PolicyConfig(approvedDirectories: ["/tmp/jarvis-service"]),
            executor: NoOpToolExecutor(), requestRepository: requests, approvalRepository: approvals,
            unitOfWork: SQLitePersistenceUnitOfWork(database: database))
        let task = try await service.createTask(title: "Foundation acceptance")

        let read = ToolRequest(taskID: task.id, name: "read_file", sideEffect: .read,
            target: "/tmp/jarvis-service/input.txt", payload: "")
        let readDecision = try await service.submit(request: read)
        XCTAssertEqual(readDecision, .allow)

        let write = ToolRequest(taskID: task.id, name: "write_file", sideEffect: .localWrite,
            target: "/tmp/jarvis-service/output.txt", payload: "secret=should-redact")
        let writeDecision = try await service.submit(request: write)
        XCTAssertEqual(writeDecision, .requireApproval(reason: "local write changes local state"))
        let awaitingStatus = try await service.getTask(id: task.id)?.status
        XCTAssertEqual(awaitingStatus, .awaitingApproval)
        do { try await service.approve(requestID: write.id, digest: ToolRequest.actionDigest(name: write.name, sideEffect: write.sideEffect, target: write.target, payload: "changed")); XCTFail("changed digest must fail") }
        catch { XCTAssertEqual(error as? TaskServiceError, .approvalDigestMismatch) }
        try await service.approve(requestID: write.id, digest: write.payloadDigest)
        for _ in 0..<50 { if try requests.fetch(id: write.id)?.1 == .completed { break }; try await Swift.Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertEqual(try requests.fetch(id: write.id)?.1, .completed)

        let slowService = try TaskService(taskRepository: tasks, auditRepository: audits, policy: Policy(),
            policyConfig: PolicyConfig(approvedDirectories: ["/tmp/jarvis-service"]), executor: SlowExecutor(),
            requestRepository: requests, approvalRepository: approvals, unitOfWork: SQLitePersistenceUnitOfWork(database: database))
        let runningTask = try await slowService.createTask(title: "Cancellation")
        let running = ToolRequest(taskID: runningTask.id, name: "read_file", sideEffect: .read,
            target: "/tmp/jarvis-service/slow", payload: "")
        let submission = Swift.Task { try? await slowService.submit(request: running) }
        try await Swift.Task.sleep(nanoseconds: 10_000_000)
        try await slowService.cancel(taskID: runningTask.id); _ = await submission.value
        let cancelledStatus = try await slowService.getTask(id: runningTask.id)?.status
        XCTAssertEqual(cancelledStatus, .cancelled)

        let events = try audits.events(for: task.id)
        XCTAssertTrue(events.contains { $0.summary == "approval accepted" })
        XCTAssertFalse(events.contains { $0.result.contains("should-redact") })
    }
}

private struct SlowExecutor: ToolExecutor {
    func execute(_ request: ToolRequest) async throws -> ToolResult {
        try await Swift.Task.sleep(nanoseconds: 500_000_000)
        return ToolResult(summary: "slow complete")
    }
}
