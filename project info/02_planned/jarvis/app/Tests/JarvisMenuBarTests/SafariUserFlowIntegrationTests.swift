import Foundation
import XCTest
import JarvisDomain
import JarvisLLM
import JarvisPersistence
import JarvisPolicy
import ApplicationServices
@testable import JarvisService
@testable import JarvisMenuBar

#if JARVIS_COMBINED_EXPERIMENT || JARVIS_SAFARI_EXPERIMENT_BUILD
private actor IntegrationSafariCapture: SafariTargetCapturing {
    let target = SafariCapturedTarget(url: "https://example.com/private", processID: 7, windowIdentity: UUID())
    private(set) var reads = 0
    func capture() async throws -> SafariCapturedTarget { target }
    func verify(_ target: SafariCapturedTarget) async throws {
        guard target == self.target else { throw SafariAXReadError.targetChanged }
    }
    func read(_ target: SafariCapturedTarget) async throws -> String { reads += 1; return "safari-private-page-unique" }
}

private actor IntegrationModel: LLMProvider {
    let identifier = "scripted"
    private(set) var turns: [[LLMMessage]] = []
    func complete(messages: [LLMMessage], tools: [LLMTool]) async throws -> LLMResponse {
        turns.append(messages)
        if turns.count == 1 {
            return LLMResponse(content: nil, toolCalls: [LLMToolCall(id: "call-1", name: "safari_read", arguments: [:])], usage: nil)
        }
        return LLMResponse(content: "finished", toolCalls: [], usage: nil)
    }
}

final class SafariUserFlowIntegrationTests: XCTestCase {
    private func performFlow(approve: Bool, disable: Bool = false) async throws {
        let db = try Database(path: ":memory:")
        try db.migrate()
        let service = try TaskService(taskRepository: SQLiteTaskRepository(database: db), auditRepository: SQLiteAuditRepository(database: db), policy: Policy(allowSafariRead: true), allowSafariReadToggle: true)
        let capture = IntegrationSafariCapture()
        service.safariCaptureFactory = { capture }
        try service.setSafariReadEnabled(true)
        let task = try await service.createTask(title: "read current page")
        let provider = IntegrationModel()
        let runner = TaskServiceToolRunner(service: service, taskID: task.id, enableSafariRead: true)
        let waiter = TaskServiceApprovalWaiter(service: service, pollInterval: 0.01, timeout: 2)
        let session = AgentSession(provider: provider, runner: runner, approvalWaiter: waiter, taskID: task.id)
        let job = Task { try await session.run(goal: "read page") }
        var pending: [PendingApprovalRequest] = []
        for _ in 0..<200 {
            pending = try await service.listPendingApprovalRequests(taskID: task.id)
            if !pending.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let item = try XCTUnwrap(pending.first)
        XCTAssertEqual(item.target, "https://example.com/private")
        if disable { try service.setSafariReadEnabled(false) }
        if approve && !disable { try await service.approve(requestID: item.id, digest: item.digest) }
        else if disable {
            do { try await service.approve(requestID: item.id, digest: item.digest); XCTFail("revoked request approved") } catch { }
            try await service.reject(requestID: item.id)
        } else { try await service.reject(requestID: item.id) }
        let outcome = try await job.value
        guard case .completed(let finalText) = outcome else { return XCTFail("Expected a final model response, got \(outcome)") }
        XCTAssertEqual(finalText, "finished")
        let turns = await provider.turns
        let toolText = turns.flatMap { $0 }.filter { $0.role == .tool }.map(\.content)
        let reads = await capture.reads
        if approve && !disable {
            XCTAssertEqual(toolText, ["safari-private-page-unique"])
            XCTAssertEqual(reads, 1)
        } else {
            XCTAssertFalse(toolText.contains("safari-private-page-unique"))
            XCTAssertEqual(reads, 0)
        }
        let events = try await service.listTimelineEvents(taskID: task.id)
        XCTAssertFalse(events.contains { $0.result.contains("safari-private-page-unique") || $0.target.contains("/private") })
        let secondTake = try await service.takeEphemeralToolResult(taskID: task.id, requestID: item.id, digest: item.digest)
        XCTAssertNil(secondTake)
    }
    func testApprovedReadFlowsExactlyOnceToModelWithoutAuditLeak() async throws { try await performFlow(approve: true) }
    func testRejectedReadNeverReachesModel() async throws { try await performFlow(approve: false) }
    func testDisabledBeforeApprovalNeverReads() async throws { try await performFlow(approve: false, disable: true) }
}
#endif

#if JARVIS_SAFARI_CLICK_EXPERIMENT && JARVIS_SAFARI_CLICK_TESTING && JARVIS_COMBINED_EXPERIMENT
private actor IntegrationClickModel: LLMProvider {
    let identifier = "click-scripted"
    private(set) var turns = 0
    func complete(messages: [LLMMessage], tools: [LLMTool]) async throws -> LLMResponse {
        turns += 1
        if turns == 1 { return LLMResponse(content: nil, toolCalls: [LLMToolCall(id: "click-1", name: "safari_click", arguments: ["role": "AXButton", "title": "Play"])], usage: nil) }
        return LLMResponse(content: "finished", toolCalls: [], usage: nil)
    }
}
private final class IntegrationClickCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
final class SafariAgentClickIntegrationTests: XCTestCase {
    private func runClick(approve: Bool, result: AXError) async throws {
        let db = try Database(path: ":memory:")
        try db.migrate()
        let service = try TaskService(taskRepository: SQLiteTaskRepository(database: db), auditRepository: SQLiteAuditRepository(database: db), policy: Policy())
        let counter = IntegrationClickCounter()
        try service.enableExperimentalClickModeForTesting(allowed: true) { _, _ in counter.increment(); return result }
        let ref = AXUIElementCreateSystemWide()
        let identity = SafariClickIdentity(pid: 42, window: "window", url: "https://example.com/private", role: "AXButton", title: "Play", enabled: true, requestDigest: "")
        let candidate = SafariClickCandidate(element: ref, window: ref, launchDate: Date(timeIntervalSince1970: 1), identity: identity)
        service.installExperimentalClickTargetSelectorForTesting { role, title in
            guard role == identity.role, title == identity.title else { throw TaskServiceCapabilityError.unavailable }
            return (identity, SafariClickCapture { [candidate] })
        }
        let task = try await service.createTask(title: "click target")
        let provider = IntegrationClickModel()
        let session = AgentSession(provider: provider, runner: TaskServiceToolRunner(service: service, taskID: task.id), approvalWaiter: TaskServiceApprovalWaiter(service: service, pollInterval: 0.01, timeout: 2), taskID: task.id)
        let job = Task { try await session.run(goal: "Click play") }
        var pending: [PendingApprovalRequest] = []
        for _ in 0..<200 {
            pending = try await service.listPendingApprovalRequests(taskID: task.id)
            if !pending.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let item = try XCTUnwrap(pending.first)
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(item.target, identity.url)
        XCTAssertTrue(item.payload.contains("Play"))
        XCTAssertEqual(counter.value, 0)
        if approve {
            if result == .success { try await service.approveExperimentalClick(requestID: item.id, digest: item.digest) }
            else { do { try await service.approveExperimentalClick(requestID: item.id, digest: item.digest); XCTFail("expected failure") } catch {} }
        } else { try await service.reject(requestID: item.id) }
        let outcome = try await job.value
        if approve && result != .success {
            guard case .failed(let reason) = outcome else { return XCTFail("failed action must terminate the session") }
            XCTAssertTrue(reason.contains("unknown"))
            XCTAssertTrue(service.isExperimentalClickBarrierBlocking)
            XCTAssertFalse(service.isExperimentalSafariClickEnabled())
            let turns = await provider.turns
            XCTAssertEqual(turns, 1, "failure must not trigger another model turn")
        } else { guard case .completed = outcome else { return XCTFail("expected completion: \(outcome)") } }
        XCTAssertEqual(counter.value, approve ? 1 : 0)
    }
    func testApprovalExecutesOnce() async throws { try await runClick(approve: true, result: .success) }
    func testRejectionNeverClicks() async throws { try await runClick(approve: false, result: .success) }
    func testFailedClickTerminatesWithoutRetry() async throws { try await runClick(approve: true, result: .failure) }
}
#endif
