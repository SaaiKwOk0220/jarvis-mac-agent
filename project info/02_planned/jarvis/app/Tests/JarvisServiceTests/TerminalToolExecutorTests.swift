import Darwin
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

    func testCancellationTerminatesChildProcess() async throws {
        // Capture the shell pid via `echo $$` so we can verify the executor's
        // SIGTERM/SIGKILL cleanup actually reaped the child it spawned.
        let pidFile = "/tmp/jarvis-cancel-pid-\(UUID().uuidString).txt"
        defer { try? FileManager.default.removeItem(atPath: pidFile) }

        let payload = "echo $$ > \(pidFile); sleep 60"
        let request = ToolRequest(
            taskID: UUID(),
            name: "shell",
            sideEffect: .localExecute,
            target: "/tmp",
            payload: payload
        )

        let executor = TerminalToolExecutor()
        let task = Task<Void, Error> {
            do {
                _ = try await executor.execute(request)
                XCTFail("expected execute to be cancelled")
            } catch is CancellationError {
                // expected
            } catch TerminalToolExecutorError.timeout {
                // also acceptable: timeout fires before cancel propagates
            }
        }

        // Give the child time to spawn and write its pid file.
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(FileManager.default.fileExists(atPath: pidFile),
                      "expected child to have written \(pidFile) before cancellation")

        let pidString = try String(contentsOfFile: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = pid_t(pidString) ?? 0
        XCTAssertGreaterThan(pid, 0, "expected a positive pid, got: \(pidString)")

        // Sanity: the child should be alive right now.
        XCTAssertEqual(kill(pid, 0), 0, "expected pid \(pid) to be alive pre-cancel")

        task.cancel()

        // The defer must SIGTERM, wait up to 1s, then SIGKILL. Give it 1.5s to settle.
        try await Task.sleep(for: .milliseconds(1500))

        // pid should now be ESRCH (process gone).
        let result = kill(pid, 0)
        XCTAssertEqual(result, -1, "expected pid \(pid) to be reaped after cancel, kill returned \(result)")
        XCTAssertEqual(errno, ESRCH, "expected ESRCH after cancel, got errno \(errno)")
    }

    func testLargeOutputDoesNotDeadlock() async throws {
        // Pipe buffer is 64KB. 100KB output would deadlock the old synchronous
        // read because the child would block on write() and never exit. The
        // concurrent drain via Task.detached must let it finish within the
        // configured timeout.
        let executor = TerminalToolExecutor(timeout: .seconds(5))
        let request = ToolRequest(
            taskID: UUID(),
            name: "shell",
            sideEffect: .localExecute,
            target: "/tmp",
            payload: "yes hello | head -c 100000"
        )

        let result = try await executor.execute(request)

        XCTAssertTrue(result.summary.contains("exit=0"),
                      "expected chatty child to exit normally, got: \(result.summary)")
    }
}
