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

        // A successful read-only request auto-completes its task once the executor finishes.
        let readTask = try await service.createTask(title: "Foundation read")
        let read = ToolRequest(taskID: readTask.id, name: "read_file", sideEffect: .read,
            target: "/tmp/jarvis-service/input.txt", payload: "")
        let readDecision = try await service.submit(request: read)
        XCTAssertEqual(readDecision, .allow)
        for _ in 0..<50 {
            if try await service.getTask(id: readTask.id)?.status == .completed { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        let readStatus = try await service.getTask(id: readTask.id)?.status
        XCTAssertEqual(readStatus, .completed)
        let readEvents = try audits.events(for: readTask.id)
        XCTAssertEqual(readEvents.map(\.summary), [
            "task created", "task transitioned", "task transitioned", "tool request received",
            "policy allowed", "tool result"
        ])

        // The approval flow (digest mismatch, correct approval, executor completion) lives on its own task
        // because a finished executor transitions the task to .completed, blocking further submissions.
        let writeTask = try await service.createTask(title: "Foundation approval")
        let write = ToolRequest(taskID: writeTask.id, name: "write_file", sideEffect: .localWrite,
            target: "/tmp/jarvis-service/output.txt", payload: "secret=should-redact")
        let writeDecision = try await service.submit(request: write)
        XCTAssertEqual(writeDecision, .requireApproval(reason: "local write changes local state"))
        let awaitingStatus = try await service.getTask(id: writeTask.id)?.status
        XCTAssertEqual(awaitingStatus, .awaitingApproval)
        do { try await service.approve(requestID: write.id, digest: ToolRequest.actionDigest(name: write.name, sideEffect: write.sideEffect, target: write.target, payload: "changed")); XCTFail("changed digest must fail") }
        catch { XCTAssertEqual(error as? TaskServiceError, .approvalDigestMismatch) }
        try await service.approve(requestID: write.id, digest: write.payloadDigest)
        for _ in 0..<50 { if try requests.fetch(id: write.id)?.1 == .completed { break }; try await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertEqual(try requests.fetch(id: write.id)?.1, .completed)
        let writeStatus = try await service.getTask(id: writeTask.id)?.status
        XCTAssertEqual(writeStatus, .completed)
        let writeEvents = try audits.events(for: writeTask.id)
        XCTAssertEqual(writeEvents.map(\.summary), [
            "task created", "task transitioned", "task transitioned", "tool request received",
            "policy requires approval", "approval rejected", "approval accepted", "tool result"
        ])
        XCTAssertEqual(writeEvents.map(\.result), [
            "created", "draft -> planning", "planning -> running", "received",
            "local write changes local state", "digest mismatch", "approved", "demo executor completed"
        ])
        XCTAssertFalse(writeEvents.contains { $0.result.contains("should-redact") })

        let slowService = try TaskService(taskRepository: tasks, auditRepository: audits, policy: Policy(),
            policyConfig: PolicyConfig(approvedDirectories: ["/tmp/jarvis-service"]), executor: SlowExecutor(),
            requestRepository: requests, approvalRepository: approvals, unitOfWork: SQLitePersistenceUnitOfWork(database: database))
        let runningTask = try await slowService.createTask(title: "Cancellation")
        let running = ToolRequest(taskID: runningTask.id, name: "read_file", sideEffect: .read,
            target: "/tmp/jarvis-service/slow", payload: "")
        let submission = Task { try? await slowService.submit(request: running) }
        try await Task.sleep(nanoseconds: 10_000_000)
        try await slowService.cancel(taskID: runningTask.id); _ = await submission.value
        let cancelledStatus = try await slowService.getTask(id: runningTask.id)?.status
        XCTAssertEqual(cancelledStatus, .cancelled)
    }
}

private struct SlowExecutor: ToolExecutor {
    func execute(_ request: ToolRequest) async throws -> ToolResult {
        try await Task.sleep(nanoseconds: 500_000_000)
        return ToolResult(summary: "slow complete")
    }
}
