import Foundation
import XCTest
@testable import JarvisMenuBar
import JarvisDomain
import JarvisLLM

/// Stands in for the real `TaskService` so each test can script the policy
/// decision and the audit timeline, and inspect exactly what the runner
/// submitted. Records every request in submission order and answers
/// `listTimelineEvents` from a settable timeline, mirroring the real
/// service's post-execution audit read.
final class ScriptedTaskService: TaskServiceAPI, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedRequests: [ToolRequest] = []
    private var scriptedDecision: PolicyDecision
    private var scriptedTimeline: [TimelineEvent]

    init(decision: PolicyDecision = .allow, timeline: [TimelineEvent] = []) {
        self.scriptedDecision = decision
        self.scriptedTimeline = timeline
    }

    /// Requests handed to `submit(request:)`, in order.
    var submittedRequests: [ToolRequest] { lock.withLock { recordedRequests } }

    func setDecision(_ decision: PolicyDecision) { lock.withLock { scriptedDecision = decision } }
    func setTimeline(_ timeline: [TimelineEvent]) { lock.withLock { scriptedTimeline = timeline } }

    func submit(request: ToolRequest) async throws -> PolicyDecision {
        lock.withLock {
            recordedRequests.append(request)
            return scriptedDecision
        }
    }

    func listTimelineEvents(taskID: UUID) async throws -> [TimelineEvent] {
        lock.withLock { scriptedTimeline }
    }

    // The runner only drives `submit` and `listTimelineEvents`; the remaining
    // protocol surface exists so the mock satisfies `TaskServiceAPI` and is
    // deliberately inert.
    func createTask(title: String) async throws -> JarvisTask { JarvisTask(title: title) }
    func getTask(id: UUID) async throws -> JarvisTask? { nil }
    func listTasks() async throws -> [JarvisTask] { [] }
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

/// The shell invocation used across the mapping tests: an explicit working
/// directory keeps the request's target deterministic without depending on
/// the process's Application Support path.
private let approvedDirectory = "/tmp/jarvis-approved"

private func shellCall() -> LLMToolCall {
    LLMToolCall(
        id: "call_0",
        name: "shell",
        arguments: ["command": "ls", "workingDirectory": approvedDirectory]
    )
}

final class TaskServiceToolRunnerTests: XCTestCase {

    /// The catalog advertised to the model is exactly Jarvis's four workers,
    /// so the LLM can only plan against capabilities the policy gate knows.
    func testToolsAdvertiseFourWorkers() {
        let runner = TaskServiceToolRunner(service: ScriptedTaskService(), taskID: UUID())

        XCTAssertEqual(runner.tools().map(\.name), ["shell", "fetch", "screenshot", "ax_query"])
    }

    /// A shell call becomes a `.localExecute` request carrying the command as
    /// its payload, with the working directory as both target and approved
    /// scope — the two fields the policy gate checks.
    func testShellCallMapsToLocalExecuteRequest() async throws {
        let service = ScriptedTaskService()
        let taskID = UUID()
        let runner = TaskServiceToolRunner(service: service, taskID: taskID)

        _ = try await runner.perform(shellCall())

        let request = try XCTUnwrap(service.submittedRequests.first)
        XCTAssertEqual(service.submittedRequests.count, 1)
        XCTAssertEqual(request.taskID, taskID)
        XCTAssertEqual(request.name, "shell")
        XCTAssertEqual(request.sideEffect, .localExecute)
        XCTAssertEqual(request.target, approvedDirectory)
        XCTAssertEqual(request.payload, "ls")
        XCTAssertEqual(request.scope, ToolScope(workingDirectory: approvedDirectory))
    }

    /// A fetch call becomes a `.read` request whose target is the URL itself.
    /// The scope always carries the default browser profile because the read
    /// gate rejects a URL target that has no profile to audit against.
    func testFetchCallMapsToReadRequest() async throws {
        let service = ScriptedTaskService()
        let taskID = UUID()
        let runner = TaskServiceToolRunner(service: service, taskID: taskID)

        _ = try await runner.perform(
            LLMToolCall(id: "call_0", name: "fetch", arguments: ["url": "https://example.com/index.html"])
        )

        let request = try XCTUnwrap(service.submittedRequests.first)
        XCTAssertEqual(request.taskID, taskID)
        XCTAssertEqual(request.name, "fetch")
        XCTAssertEqual(request.sideEffect, .read)
        XCTAssertEqual(request.target, "https://example.com/index.html")
        XCTAssertEqual(request.payload, "https://example.com/index.html")
        XCTAssertEqual(request.scope?.browserProfile, "default")
    }

    /// A name outside the catalog never reaches the service: the runner
    /// refuses it itself so the model gets a reason it can re-plan around
    /// instead of a malformed request hitting the policy gate.
    func testUnknownToolReturnsDenied() async throws {
        let service = ScriptedTaskService()
        let runner = TaskServiceToolRunner(service: service, taskID: UUID())

        let outcome = try await runner.perform(
            LLMToolCall(id: "call_0", name: "nope", arguments: [:])
        )

        XCTAssertEqual(outcome, .denied("unknown tool"))
        XCTAssertTrue(service.submittedRequests.isEmpty, "an unknown tool must not reach the service")
    }

    /// The policy's approval verdict is handed back verbatim, bound to the id
    /// of the request the user will see in the task-detail window and to the
    /// request's payload digest, which a waiter uses to locate the terminal
    /// audit event once the human decides.
    func testAwaitingApprovalPropagatesPayloadDigest() async throws {
        let reason = "shell command requires explicit approval"
        let service = ScriptedTaskService(decision: .requireApproval(reason: reason))
        let runner = TaskServiceToolRunner(service: service, taskID: UUID())

        let outcome = try await runner.perform(shellCall())

        let request = try XCTUnwrap(service.submittedRequests.first)
        XCTAssertEqual(
            outcome,
            .awaitingApproval(requestID: request.id, payloadDigest: request.payloadDigest, description: reason)
        )
    }

    /// A policy denial is surfaced with the policy's own reason so the loop
    /// can feed it back to the model and pick a different plan.
    func testDeniedDecisionPropagatesReason() async throws {
        let service = ScriptedTaskService(decision: .deny(reason: "command is not allowlisted"))
        let runner = TaskServiceToolRunner(service: service, taskID: UUID())

        let outcome = try await runner.perform(shellCall())

        XCTAssertEqual(outcome, .denied("command is not allowlisted"))
    }

    /// An allowed call has already executed by the time `submit` returns, so
    /// the runner reads the observation back out of the audit timeline — the
    /// "tool result" event for this exact action digest, ignoring unrelated
    /// events on the same task.
    func testAllowedCallReadsObservationFromTimeline() async throws {
        let service = ScriptedTaskService(decision: .allow)
        let taskID = UUID()
        let runner = TaskServiceToolRunner(service: service, taskID: taskID)
        let digest = ToolRequest.actionDigest(
            name: "shell",
            sideEffect: .localExecute,
            target: approvedDirectory,
            payload: "ls",
            scope: ToolScope(workingDirectory: approvedDirectory)
        )
        service.setTimeline([
            TimelineEvent(id: UUID(), timestamp: Date(), worker: "task-service", target: "elsewhere",
                          sideEffect: .localExecute, actionDigest: "some-other-digest",
                          summary: "tool result", result: "wrong request", approvalID: nil),
            TimelineEvent(id: UUID(), timestamp: Date(), worker: "task-service", target: approvedDirectory,
                          sideEffect: .localExecute, actionDigest: digest,
                          summary: "tool result", result: "exit=0\nstdout=a.txt", approvalID: nil),
        ])

        let outcome = try await runner.perform(shellCall())

        XCTAssertEqual(outcome, .executed("exit=0\nstdout=a.txt"))
    }

    /// When the audit write is not visible yet the run must still make
    /// progress: the runner falls back to a non-empty observation rather than
    /// stalling or reporting an empty result to the model.
    func testMissingObservationFallsBackGracefully() async throws {
        let service = ScriptedTaskService(decision: .allow)
        let runner = TaskServiceToolRunner(service: service, taskID: UUID())

        let outcome = try await runner.perform(shellCall())

        guard case .executed(let observation) = outcome else {
            return XCTFail("expected .executed, got \(outcome)")
        }
        XCTAssertFalse(observation.isEmpty, "the fallback observation must carry something for the model")
    }
}
