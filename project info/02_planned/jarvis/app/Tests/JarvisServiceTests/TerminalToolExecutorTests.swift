import Foundation
import XCTest
import JarvisDomain
@testable import JarvisService

final class TerminalToolExecutorTests: XCTestCase {
    func testRejectsShellCompositionBeforeExecution() async throws {
        let request = ToolRequest(taskID: UUID(), name: "shell", sideEffect: .localExecute, target: "/tmp", payload: "pwd; echo unsafe")
        do {
            _ = try await TerminalToolExecutor().execute(request)
            XCTFail("shell composition must be rejected")
        } catch TerminalToolExecutorError.unsupportedCommand { }
    }

    func testRejectsArgumentsAndOtherCommands() async throws {
        for command in ["pwd /tmp", "/bin/pwd", "swift test", "echo hello"] {
            let request = ToolRequest(taskID: UUID(), name: "shell", sideEffect: .localExecute, target: "/tmp", payload: command)
            do {
                _ = try await TerminalToolExecutor().execute(request)
                XCTFail("expected rejection for \(command)")
            } catch TerminalToolExecutorError.unsupportedCommand { }
        }
    }

    func testPwdRunsInRequestedWorkingDirectory() async throws {
        let request = ToolRequest(taskID: UUID(), name: "shell", sideEffect: .localExecute, target: "/tmp", payload: "pwd", scope: ToolScope(workingDirectory: "/tmp"))
        let result = try await TerminalToolExecutor().execute(request)
        XCTAssertTrue(result.summary.contains("/tmp"), result.summary)
    }
}
