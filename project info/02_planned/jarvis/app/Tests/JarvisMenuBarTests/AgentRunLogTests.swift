import XCTest
import JarvisLLM
@testable import JarvisMenuBar

@MainActor
final class AgentRunLogTests: XCTestCase {
    func testBrowserToolLogContainsOnlyOrigin() {
        let call = LLMToolCall(id: "1", name: "browser_open", arguments: ["url": "https://example.com/private-path?secret=abc"])
        let line = AgentLogEntry(event: .toolCallRequested(call))
        XCTAssertTrue(line.text.contains("https://example.com"))
        XCTAssertFalse(line.text.contains("private-path"))
        XCTAssertFalse(line.text.contains("secret"))
    }

    func testSafariResultDoesNotRenderPrivatePageText() {
        let entry = AgentLogEntry(event: .toolCallSucceeded(name: "safari_read", observation: "private-page-text"))
        XCTAssertFalse(entry.text.contains("private-page-text"))
        XCTAssertTrue(entry.text.contains("provided to the model"))
    }

    func testSafariCaptureTellsUserToSwitchWindows() {
        let call = LLMToolCall(id: "s", name: "safari_read", arguments: [:])
        let entry = AgentLogEntry(event: .toolCallRequested(call))
        XCTAssertTrue(entry.text.contains("Switch to the intended Safari window"))
        XCTAssertTrue(entry.text.contains("before approval"))
    }

    func testCompletedAssistantEventIsShownOnce() {
        let log = AgentRunLog()
        log.append(AgentLogEntry(event: .assistantText("Hello")))
        log.recordOutcome(.completed(finalText: "Hello"))
        XCTAssertEqual(log.entries.filter { $0.kind == .assistant }.map(\.text), ["Assistant: Hello"])
        XCTAssertTrue(log.entries.contains { $0.text == "Run complete." })
    }

    func testApprovalFailureCancellationAndTimeoutShowDistinctOutcomes() {
        let cases: [(AgentLoopResult, String)] = [(.failed(reason: "shell exited 1"), "shell exited 1"), (.cancelled, "cancelled"), (.approvalTimedOut, "timed out")]
        for (outcome, expected) in cases {
            let log = AgentRunLog()
            log.recordOutcome(outcome)
            XCTAssertTrue(log.entries.contains { $0.text.contains(expected) })
            XCTAssertFalse(log.entries.contains { $0.text.contains("iteration limit") })
        }
    }

    func testIterationLimitRemainsVisibleWithoutRepeatingLastText() {
        let log = AgentRunLog()
        log.append(AgentLogEntry(event: .assistantText("Working")))
        log.recordOutcome(.exceededIterations(lastText: "Working"))
        XCTAssertEqual(log.entries.filter { $0.kind == .assistant }.count, 1)
        XCTAssertTrue(log.entries.contains { $0.kind == .error && $0.text.contains("iteration limit") })
    }
}

private struct ReplyProvider: LLMProvider {
    let identifier = "test"
    func complete(messages: [LLMMessage], tools: [LLMTool]) async throws -> LLMResponse {
        LLMResponse(content: "真实回复", toolCalls: [], usage: nil)
    }
}
private struct EmptyRunner: AgentToolRunner {
    func tools() -> [LLMTool] { [] }
    func perform(_ call: LLMToolCall) async throws -> AgentToolOutcome { .denied("unexpected") }
}
private struct EmptyWaiter: ApprovalWaiter {
    func waitForResolution(requestID: UUID, payloadDigest: String, taskID: UUID) async throws -> ToolResolution { .timedOut }
}

extension AgentRunLogTests {
    func testRealSessionEventAndOutcomeRenderOneAssistantReply() async throws {
        let session = AgentSession(provider: ReplyProvider(), runner: EmptyRunner(), approvalWaiter: EmptyWaiter(), taskID: UUID())
        let log = AgentRunLog()
        let (stream, continuation) = AsyncStream<AgentLoopEvent>.makeStream()
        let collector = Task { @MainActor in
            for await event in stream { log.append(AgentLogEntry(event: event)) }
        }
        let result = try await session.run(goal: "hello") { continuation.yield($0) }
        continuation.finish()
        await collector.value
        log.recordOutcome(result)
        XCTAssertEqual(log.entries.filter { $0.kind == .assistant }.map(\.text), ["Assistant: 真实回复"])
        XCTAssertTrue(log.entries.contains { $0.text == "Run complete." })
    }
}
