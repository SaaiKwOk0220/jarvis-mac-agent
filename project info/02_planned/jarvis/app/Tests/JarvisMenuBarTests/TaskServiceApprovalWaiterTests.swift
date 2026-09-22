import Foundation
import XCTest
@testable import JarvisMenuBar
import JarvisDomain
import JarvisLLM

/// Minimal `TaskServiceAPI` mock that hands back a settable timeline.
final class StaticTimelineService: TaskServiceAPI, @unchecked Sendable {
    private let lock = NSLock()
    private var timeline: [TimelineEvent]
    private var listCallCount = 0

    init(timeline: [TimelineEvent] = []) { self.timeline = timeline }

    func setTimeline(_ events: [TimelineEvent]) { lock.withLock { timeline = events } }
    var listCalls: Int { lock.withLock { listCallCount } }

    func listTimelineEvents(taskID: UUID) async throws -> [TimelineEvent] {
        lock.withLock {
            listCallCount += 1
            return timeline
        }
    }

    // The waiter only touches `listTimelineEvents`; everything below exists
    // solely to satisfy `TaskServiceAPI`.
    func createTask(title: String) async throws -> JarvisTask { JarvisTask(title: title) }
    func getTask(id: UUID) async throws -> JarvisTask? { nil }
    func listTasks() async throws -> [JarvisTask] { [] }
    func submit(request: ToolRequest) async throws -> PolicyDecision { .allow }
    func approve(requestID: UUID, digest: String) async throws {}
    func reject(requestID: UUID) async throws {}
    func cancel(taskID: UUID) async throws {}
    func complete(taskID: UUID) async throws {}
    func listPendingApprovalRequests(taskID: UUID) async throws -> [PendingApprovalRequest] { [] }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }; return try body()
    }
}

/// Builds a timeline event for one terminal outcome so each test only spells
/// out the bits it actually cares about.
private func terminalEvent(
    actionDigest: String,
    summary: String,
    result: String,
    timestamp: Date = Date()
) -> TimelineEvent {
    TimelineEvent(
        id: UUID(),
        timestamp: timestamp,
        worker: "task-service",
        target: "shell",
        sideEffect: .localExecute,
        actionDigest: actionDigest,
        summary: summary,
        result: result,
        approvalID: UUID()
    )
}

final class TaskServiceApprovalWaiterTests: XCTestCase {

    /// A "tool result" audit event whose `actionDigest` matches the request
    /// the waiter was told to follow is the approval-then-success case.
    func testWaiterReturnsApprovedOnToolResultEvent() async throws {
        let payloadDigest = "digest-approved"
        let service = StaticTimelineService(timeline: [
            terminalEvent(actionDigest: "unrelated", summary: "tool result", result: "wrong"),
            terminalEvent(actionDigest: payloadDigest, summary: "tool result", result: "exit=0"),
        ])
        let waiter = TaskServiceApprovalWaiter(
            service: service,
            pollInterval: 0.01,
            timeout: 1
        )

        let resolution = try await waiter.waitForResolution(
            requestID: UUID(),
            payloadDigest: payloadDigest,
            taskID: UUID()
        )

        XCTAssertEqual(resolution, .approved(observation: "exit=0"))
    }

    /// A "tool failure" event means the user approved the request but the
    /// tool itself blew up — the waiter surfaces this as `.failed` with the
    /// error string verbatim.
    func testWaiterReturnsFailedOnToolFailureEvent() async throws {
        let payloadDigest = "digest-failed"
        let service = StaticTimelineService(timeline: [
            terminalEvent(actionDigest: payloadDigest, summary: "tool failure", result: "exit=1"),
        ])
        let waiter = TaskServiceApprovalWaiter(
            service: service,
            pollInterval: 0.01,
            timeout: 1
        )

        let resolution = try await waiter.waitForResolution(
            requestID: UUID(),
            payloadDigest: payloadDigest,
            taskID: UUID()
        )

        XCTAssertEqual(resolution, .failed(reason: "exit=1"))
    }

    /// An "approval rejected" event means the user said no — the waiter
    /// surfaces the user's reason so the session can feed it back to the
    /// model.
    func testWaiterReturnsRejectedOnApprovalRejectedEvent() async throws {
        let payloadDigest = "digest-rejected"
        let service = StaticTimelineService(timeline: [
            terminalEvent(actionDigest: payloadDigest, summary: "approval rejected", result: "nope"),
        ])
        let waiter = TaskServiceApprovalWaiter(
            service: service,
            pollInterval: 0.01,
            timeout: 1
        )

        let resolution = try await waiter.waitForResolution(
            requestID: UUID(),
            payloadDigest: payloadDigest,
            taskID: UUID()
        )

        XCTAssertEqual(resolution, .rejected(reason: "nope"))
    }

    /// An empty timeline that never produces a terminal event must end in
    /// `.timedOut`, never block forever, and must have polled the timeline
    /// at least once so the failure mode is "saw nothing for N seconds",
    /// not "forgot to check".
    func testWaiterReturnsTimedOutAfterDeadline() async throws {
        let service = StaticTimelineService(timeline: [])
        let waiter = TaskServiceApprovalWaiter(
            service: service,
            pollInterval: 0.05,
            timeout: 0.1
        )

        let resolution = try await waiter.waitForResolution(
            requestID: UUID(),
            payloadDigest: "digest-missing",
            taskID: UUID()
        )

        XCTAssertEqual(resolution, .timedOut)
        XCTAssertGreaterThanOrEqual(service.listCalls, 1, "poller must consult the timeline at least once")
    }
}
