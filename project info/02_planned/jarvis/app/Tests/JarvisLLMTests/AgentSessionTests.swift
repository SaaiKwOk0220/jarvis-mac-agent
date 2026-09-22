import Foundation
import XCTest
@testable import JarvisLLM

/// Answers each call from a name-keyed outcome table, mirroring
/// `AgentLoopTests.ScriptedRunner` so the session and loop tests share the
/// same runner shape.
final class SessionScriptedRunner: AgentToolRunner, @unchecked Sendable {
    let toolList: [LLMTool]
    private let outcomes: [String: AgentToolOutcome]
    private let lock = NSLock()
    private var recordedCalls: [LLMToolCall] = []

    init(tools: [LLMTool], outcomes: [String: AgentToolOutcome]) {
        self.toolList = tools
        self.outcomes = outcomes
    }

    var performedCalls: [LLMToolCall] { lock.withLock { recordedCalls } }

    func tools() -> [LLMTool] { toolList }

    func perform(_ call: LLMToolCall) async throws -> AgentToolOutcome {
        lock.withLock {
            recordedCalls.append(call)
            return outcomes[call.name] ?? .denied("no scripted outcome for \(call.name)")
        }
    }
}

/// Returns a canned `ToolResolution` for every `waitForResolution` call,
/// recording the (requestID, payloadDigest) pair so tests can assert what
/// the session forwarded to the waiter.
final class ScriptedApprovalWaiter: ApprovalWaiter, @unchecked Sendable {
    private let lock = NSLock()
    private var resolutions: [ToolResolution]
    private var recordedCalls: [(UUID, String)] = []

    init(resolutions: [ToolResolution]) { self.resolutions = resolutions }

    var calls: [(UUID, String)] { lock.withLock { recordedCalls } }

    func waitForResolution(requestID: UUID, payloadDigest: String, taskID: UUID) async throws -> ToolResolution {
        lock.withLock {
            recordedCalls.append((requestID, payloadDigest))
            return resolutions.isEmpty
                ? .timedOut
                : resolutions.removeFirst()
        }
    }
}

private func shellTool() -> LLMTool {
    LLMTool(
        name: "shell",
        description: "Run a shell command on the local machine.",
        parameters: ["command": LLMToolParameter(type: "string", description: "The command to run.")]
    )
}

private func shellCall(id: String = "call_0", command: String = "ls") -> LLMToolCall {
    LLMToolCall(id: id, name: "shell", arguments: ["command": command])
}

final class AgentSessionTests: XCTestCase {

    /// A provider turn with text and no tool calls ends the run on the very
    /// first iteration — the session must skip the runner and waiter
    /// entirely and return the model's text verbatim.
    func testSessionRunsLoopToCompletion() async throws {
        let provider = ScriptedProvider(responses: [
            LLMResponse(content: "Done", toolCalls: [], usage: nil),
        ])
        let runner = SessionScriptedRunner(tools: [], outcomes: [:])
        let waiter = ScriptedApprovalWaiter(resolutions: [])
        let session = AgentSession(
            provider: provider,
            runner: runner,
            approvalWaiter: waiter,
            taskID: UUID()
        )

        let result = try await session.run(goal: "say done")

        XCTAssertEqual(result, .completed(finalText: "Done"))
        XCTAssertEqual(provider.callCount, 1)
        XCTAssertTrue(runner.performedCalls.isEmpty)
        XCTAssertTrue(waiter.calls.isEmpty, "no approval should be requested when the run completes on the first turn")
    }

    /// When the runner says `.awaitingApproval`, the session must call the
    /// waiter with the same `(requestID, payloadDigest)` the runner emitted,
    /// feed the approved observation back as a `.tool` message, and ask the
    /// provider for a second turn.
    func testSessionWaitsForApprovalAndContinuesOnApprove() async throws {
        let requestID = UUID()
        let payloadDigest = "digest-123"
        let provider = ScriptedProvider(responses: [
            LLMResponse(content: "", toolCalls: [shellCall()], usage: nil),
            LLMResponse(content: "All set", toolCalls: [], usage: nil),
        ])
        let runner = SessionScriptedRunner(
            tools: [shellTool()],
            outcomes: [
                "shell": .awaitingApproval(
                    requestID: requestID,
                    payloadDigest: payloadDigest,
                    description: "shell command requires explicit approval"
                )
            ]
        )
        let waiter = ScriptedApprovalWaiter(resolutions: [.approved(observation: "ok")])
        let session = AgentSession(
            provider: provider,
            runner: runner,
            approvalWaiter: waiter,
            taskID: UUID()
        )

        let result = try await session.run(goal: "run shell")

        XCTAssertEqual(result, .completed(finalText: "All set"))
        XCTAssertEqual(provider.callCount, 2)
        let waiterCall = try XCTUnwrap(waiter.calls.first)
        XCTAssertEqual(waiterCall.0, requestID)
        XCTAssertEqual(waiterCall.1, payloadDigest)

        let secondTurn = try XCTUnwrap(provider.capturedMessages.last)
        XCTAssertTrue(
            secondTurn.contains(LLMMessage(role: .tool, content: "ok")),
            "approved observation should be in the follow-up turn, got \(secondTurn)"
        )
    }

    /// A rejection is not a stop condition: the session feeds
    /// `"denied: <reason>"` back to the model so it can re-plan, and asks
    /// again.
    func testSessionReturnsToolResolutionOnReject() async throws {
        let requestID = UUID()
        let payloadDigest = "digest-456"
        let provider = ScriptedProvider(responses: [
            LLMResponse(content: "", toolCalls: [shellCall()], usage: nil),
            LLMResponse(content: "Trying another way", toolCalls: [], usage: nil),
        ])
        let runner = SessionScriptedRunner(
            tools: [shellTool()],
            outcomes: [
                "shell": .awaitingApproval(
                    requestID: requestID,
                    payloadDigest: payloadDigest,
                    description: "shell command requires explicit approval"
                )
            ]
        )
        let waiter = ScriptedApprovalWaiter(resolutions: [.rejected(reason: "no policy")])
        let session = AgentSession(
            provider: provider,
            runner: runner,
            approvalWaiter: waiter,
            taskID: UUID()
        )

        let result = try await session.run(goal: "do the thing")

        XCTAssertEqual(result, .completed(finalText: "Trying another way"))
        XCTAssertEqual(provider.callCount, 2)

        let secondTurn = try XCTUnwrap(provider.capturedMessages.last)
        XCTAssertTrue(
            secondTurn.contains(LLMMessage(role: .tool, content: "denied: no policy")),
            "rejection reason should reach the model as 'denied: <reason>', got \(secondTurn)"
        )
    }

    /// An approval that the tool then fails to execute is a hard stop: the
    /// session surfaces it as `.exceededIterations` carrying the failure
    /// reason, because the tool itself is no longer recoverable.
    func testSessionReturnsExceededIterationsOnFailure() async throws {
        let requestID = UUID()
        let payloadDigest = "digest-fail"
        let provider = ScriptedProvider(responses: [
            LLMResponse(content: "", toolCalls: [shellCall()], usage: nil),
        ])
        let runner = SessionScriptedRunner(
            tools: [shellTool()],
            outcomes: [
                "shell": .awaitingApproval(
                    requestID: requestID,
                    payloadDigest: payloadDigest,
                    description: "shell command requires explicit approval"
                )
            ]
        )
        let waiter = ScriptedApprovalWaiter(resolutions: [.failed(reason: "shell exited 1")])
        let session = AgentSession(
            provider: provider,
            runner: runner,
            approvalWaiter: waiter,
            taskID: UUID()
        )

        let result = try await session.run(goal: "try shell")

        XCTAssertEqual(result, .exceededIterations(lastText: "shell exited 1"))
        XCTAssertEqual(provider.callCount, 1, "must not call the provider again after a tool failure")
    }

    /// A whole-task cancellation surfaces as `.exceededIterations` so the UI
    /// can distinguish "stopped because the user cancelled" from a normal
    /// budget exhaustion.
    func testSessionStopsOnCancelled() async throws {
        let requestID = UUID()
        let payloadDigest = "digest-cancel"
        let provider = ScriptedProvider(responses: [
            LLMResponse(content: "", toolCalls: [shellCall()], usage: nil),
        ])
        let runner = SessionScriptedRunner(
            tools: [shellTool()],
            outcomes: [
                "shell": .awaitingApproval(
                    requestID: requestID,
                    payloadDigest: payloadDigest,
                    description: "shell command requires explicit approval"
                )
            ]
        )
        let waiter = ScriptedApprovalWaiter(resolutions: [.cancelled])
        let session = AgentSession(
            provider: provider,
            runner: runner,
            approvalWaiter: waiter,
            taskID: UUID()
        )

        let result = try await session.run(goal: "try shell")

        XCTAssertEqual(result, .exceededIterations(lastText: "cancelled by user"))
        XCTAssertEqual(provider.callCount, 1)
    }

    /// A waiter timeout stops the run cleanly with a distinct message.
    func testSessionStopsOnTimedOut() async throws {
        let requestID = UUID()
        let payloadDigest = "digest-timeout"
        let provider = ScriptedProvider(responses: [
            LLMResponse(content: "", toolCalls: [shellCall()], usage: nil),
        ])
        let runner = SessionScriptedRunner(
            tools: [shellTool()],
            outcomes: [
                "shell": .awaitingApproval(
                    requestID: requestID,
                    payloadDigest: payloadDigest,
                    description: "shell command requires explicit approval"
                )
            ]
        )
        let waiter = ScriptedApprovalWaiter(resolutions: [.timedOut])
        let session = AgentSession(
            provider: provider,
            runner: runner,
            approvalWaiter: waiter,
            taskID: UUID()
        )

        let result = try await session.run(goal: "try shell")

        XCTAssertEqual(result, .exceededIterations(lastText: "approval timed out"))
        XCTAssertEqual(provider.callCount, 1)
    }
}
