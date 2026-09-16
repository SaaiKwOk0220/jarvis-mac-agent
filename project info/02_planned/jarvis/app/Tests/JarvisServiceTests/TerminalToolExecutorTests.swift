import Foundation
import XCTest
import JarvisDomain
@testable import JarvisService

final class TerminalToolExecutorTests: XCTestCase {
    func testRunShellCommandReturnsZeroExitCodeAndCapturesStdout() async throws {
        let executor = TerminalToolExecutor()
        let request = ToolRequest(
            taskID: UUID(),
            name: "shell",
            sideEffect: .localExecute,
            target: "/tmp",
            payload: "echo hello"
        )

        let result = try await executor.execute(request)

        XCTAssertTrue(result.summary.contains("exit=0"), result.summary)
        XCTAssertTrue(result.summary.contains("hello"), result.summary)
    }

    func testRunShellCommandReturnsNonZeroExitCodeAsFailure() async throws {
        let executor = TerminalToolExecutor()
        let request = ToolRequest(
            taskID: UUID(),
            name: "shell",
            sideEffect: .localExecute,
            target: "/tmp",
            payload: "false"
        )

        do {
            _ = try await executor.execute(request)
            XCTFail("expected non-zero exit code to throw")
        } catch let TerminalToolExecutorError.nonZeroExit(code, _) {
            XCTAssertNotEqual(code, 0)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testRunShellCommandRespectsTimeout() async throws {
        let executor = TerminalToolExecutor(timeout: .milliseconds(500))
        let request = ToolRequest(
            taskID: UUID(),
            name: "shell",
            sideEffect: .localExecute,
            target: "/tmp",
            payload: "sleep 60"
        )

        let start = ContinuousClock.now
        do {
            _ = try await executor.execute(request)
            XCTFail("expected timeout to throw")
        } catch TerminalToolExecutorError.timeout {
            let elapsed = ContinuousClock.now - start
            XCTAssertLessThan(elapsed, .seconds(3), "timeout must not wait the full sleep duration")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testRunShellCommandSetsWorkingDirectoryFromScope() async throws {
        let executor = TerminalToolExecutor()
        let request = ToolRequest(
            taskID: UUID(),
            name: "shell",
            sideEffect: .localExecute,
            target: "/tmp",
            payload: "pwd",
            scope: ToolScope(workingDirectory: "/tmp")
        )

        let result = try await executor.execute(request)

        XCTAssertTrue(result.summary.contains("exit=0"), result.summary)
        let resolved = URL(fileURLWithPath: "/private/tmp").standardizedFileURL.path
        XCTAssertTrue(
            result.summary.contains(resolved) || result.summary.contains("/tmp"),
            "expected summary to report pwd, got: \(result.summary)"
        )
    }
}
