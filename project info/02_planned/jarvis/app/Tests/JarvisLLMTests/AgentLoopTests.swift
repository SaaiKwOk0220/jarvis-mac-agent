import Foundation
import XCTest
@testable import JarvisLLM

/// Replays a fixed script of responses, one per `complete` call, and records
/// the exact `messages` it was handed each time. The lock makes it safe to
/// read `capturedMessages` after an `await` on the loop, and lets the type
/// satisfy `LLMProvider`'s `Sendable` requirement despite the mutable state.
final class ScriptedProvider: LLMProvider, @unchecked Sendable {
    let identifier = "scripted"
    private let lock = NSLock()
    private var responses: [LLMResponse]
    private(set) var capturedMessages: [[LLMMessage]] = []

    init(responses: [LLMResponse]) { self.responses = responses }

    /// Number of `complete` calls observed, for "provider called exactly N
    /// times" assertions without reaching into `capturedMessages`.
    var callCount: Int { lock.withLock { capturedMessages.count } }

    func complete(messages: [LLMMessage], tools: [LLMTool]) async throws -> LLMResponse {
        lock.withLock {
            capturedMessages.append(messages)
            // Running off the end of the script yields an empty turn so a test
            // that forgets a response fails as "completed" rather than crashing.
            return responses.isEmpty
                ? LLMResponse(content: nil, toolCalls: [], usage: nil)
                : responses.removeFirst()
        }
    }
}

/// Answers each tool call from a name-keyed outcome table and records every
/// call it was asked to perform, so tests can assert the loop routed the
/// model's plan through the runner.
final class ScriptedRunner: AgentToolRunner, @unchecked Sendable {
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
            // A tool with no scripted outcome is a test-authoring mistake, not
            // a loop behaviour under test; fail loudly via the `.denied` path.
            return outcomes[call.name] ?? .denied("no scripted outcome for \(call.name)")
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }; return try body()
    }
}

/// The shell tool used throughout: cheap, and mirrors the real catalog's name.
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

final class AgentLoopTests: XCTestCase {

    /// A provider turn with text and no tool calls ends the run: the loop must
    /// return the model's words verbatim and not ask again.
    func testLoopReturnsCompletedWhenProviderReturnsTextWithoutToolCalls() async throws {
        let provider = ScriptedProvider(responses: [
            LLMResponse(content: "Done", toolCalls: [], usage: nil),
        ])
        let loop = AgentLoop(provider: provider, runner: ScriptedRunner(tools: [], outcomes: [:]))

        let result = try await loop.run(goal: "say done")

        XCTAssertEqual(result, .completed(finalText: "Done"))
        XCTAssertEqual(provider.callCount, 1)
    }

    /// A tool call does not end the run: the loop executes it, feeds the
    /// observation back as a `.tool` message, and the next provider call must
    /// see that observation alongside the original goal.
    func testLoopExecutesToolCallAndFeedsObservationBack() async throws {
        let provider = ScriptedProvider(responses: [
            LLMResponse(content: "", toolCalls: [shellCall()], usage: nil),
            LLMResponse(content: "All set", toolCalls: [], usage: nil),
        ])
        let runner = ScriptedRunner(
            tools: [shellTool()],
            outcomes: ["shell": .executed("a.txt\nb.txt")]
        )
        let loop = AgentLoop(provider: provider, runner: runner)

        let result = try await loop.run(goal: "list files")

        XCTAssertEqual(result, .completed(finalText: "All set"))
        XCTAssertEqual(provider.callCount, 2)
        XCTAssertEqual(runner.performedCalls.map(\.name), ["shell"])

        let secondTurn = try XCTUnwrap(provider.capturedMessages.last)
        XCTAssertTrue(
            secondTurn.contains(LLMMessage(role: .tool, content: "a.txt\nb.txt")),
            "expected the tool observation in the follow-up turn, got \(secondTurn)"
        )
    }

    /// A tool that needs a human decision is a first-class stop condition: the
    /// loop hands the request id back and must not keep looping (no further
    /// provider call) while approval is outstanding.
    func testLoopStopsAtAwaitingApproval() async throws {
        let requestID = UUID()
        let provider = ScriptedProvider(responses: [
            LLMResponse(content: "", toolCalls: [shellCall()], usage: nil),
            LLMResponse(content: "should not be reached", toolCalls: [], usage: nil),
        ])
        let runner = ScriptedRunner(
            tools: [shellTool()],
            outcomes: ["shell": .awaitingApproval(requestID: requestID, description: "rm -rf needs approval")]
        )
        let loop = AgentLoop(provider: provider, runner: runner)

        let result = try await loop.run(goal: "clean up")

        XCTAssertEqual(result, .awaitingApproval(requestID: requestID, description: "rm -rf needs approval"))
        XCTAssertEqual(provider.callCount, 1)
    }

    /// A denial does not abort the run: the reason is surfaced to the model as
    /// a tool message so it can choose a different plan, and the loop asks again.
    func testLoopFeedsDenialBackToProvider() async throws {
        let provider = ScriptedProvider(responses: [
            LLMResponse(content: "", toolCalls: [shellCall()], usage: nil),
            LLMResponse(content: "Trying another way", toolCalls: [], usage: nil),
        ])
        let runner = ScriptedRunner(
            tools: [shellTool()],
            outcomes: ["shell": .denied("policy says no")]
        )
        let loop = AgentLoop(provider: provider, runner: runner)

        let result = try await loop.run(goal: "do the thing")

        XCTAssertEqual(result, .completed(finalText: "Trying another way"))
        XCTAssertEqual(provider.callCount, 2)

        let secondTurn = try XCTUnwrap(provider.capturedMessages.last)
        XCTAssertTrue(
            secondTurn.contains(LLMMessage(role: .tool, content: "denied: policy says no")),
            "expected the denial in the follow-up turn, got \(secondTurn)"
        )
    }

    /// A model stuck on tool calls is bounded by the iteration budget: with
    /// `maxIterations: 3` the provider is asked exactly three times and the
    /// run ends as `.exceededIterations` rather than looping forever.
    func testLoopExceedsMaxIterations() async throws {
        let provider = ScriptedProvider(responses: [
            LLMResponse(content: "step", toolCalls: [shellCall(id: "call_0")], usage: nil),
            LLMResponse(content: "step", toolCalls: [shellCall(id: "call_1")], usage: nil),
            LLMResponse(content: "step", toolCalls: [shellCall(id: "call_2")], usage: nil),
        ])
        let runner = ScriptedRunner(tools: [shellTool()], outcomes: ["shell": .executed("ok")])
        let loop = AgentLoop(provider: provider, runner: runner, maxIterations: 3)

        let result = try await loop.run(goal: "loop forever")

        XCTAssertEqual(result, .exceededIterations(lastText: "step"))
        XCTAssertEqual(provider.callCount, 3)
    }

    /// The very first provider call is seeded with the system prompt followed
    /// by the goal as a user turn — the loop's only contract with the model
    /// before any tool has run.
    func testLoopSeedsSystemPromptAndGoalAsFirstTwoMessages() async throws {
        let provider = ScriptedProvider(responses: [
            LLMResponse(content: "ok", toolCalls: [], usage: nil),
        ])
        let loop = AgentLoop(provider: provider, runner: ScriptedRunner(tools: [], outcomes: [:]))

        _ = try await loop.run(goal: "summarise my day")

        let firstTurn = try XCTUnwrap(provider.capturedMessages.first)
        XCTAssertEqual(firstTurn.count, 2)
        XCTAssertEqual(firstTurn[0], LLMMessage(role: .system, content: AgentLoop.defaultSystemPrompt))
        XCTAssertEqual(firstTurn[1], LLMMessage(role: .user, content: "summarise my day"))
    }
}
