import Darwin
import Foundation
import JarvisDomain

/// Errors surfaced by `TerminalToolExecutor`.
public enum TerminalToolExecutorError: Error, Equatable, Sendable {
    case incompatibleSideEffect(SideEffect)
    case launchFailed(underlying: String)
    case timeout
    case nonZeroExit(code: Int32, summary: String)
}

/// ToolExecutor that runs a shell command via `/bin/sh -c <payload>` as a `Foundation.Process`.
///
/// The executor enforces a hard timeout. When the timeout elapses, the process receives `SIGTERM`;
/// if it has not exited one second later, the executor escalates to `SIGKILL`. The captured stdout
/// and stderr are truncated to 200 characters each so the resulting summary comfortably fits inside
/// `TaskService.bounded(_:)`'s 512-character audit envelope.
public struct TerminalToolExecutor: ToolExecutor, Sendable {
    public let timeout: Duration
    private static let outputPreviewLimit = 200
    private static let gracePeriod: Duration = .seconds(1)

    public init(timeout: Duration = .seconds(30)) {
        self.timeout = timeout
    }

    public func execute(_ request: ToolRequest) async throws -> ToolResult {
        guard request.sideEffect == .localExecute else {
            throw TerminalToolExecutorError.incompatibleSideEffect(request.sideEffect)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", request.payload]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        if let workingDirectory = request.scope?.workingDirectory, !workingDirectory.isEmpty {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        }

        do {
            try process.run()
        } catch {
            throw TerminalToolExecutorError.launchFailed(underlying: String(describing: error))
        }

        defer {
            if process.isRunning {
                process.terminate()
            }
        }

        try await Self.waitForExit(process, timeout: timeout)

        let stdout = Self.readPipe(stdoutPipe)
        let stderr = Self.readPipe(stderrPipe)
        let exitCode = process.terminationStatus
        let summary = Self.formatSummary(exitCode: exitCode, stdout: stdout, stderr: stderr)

        guard exitCode == 0 else {
            throw TerminalToolExecutorError.nonZeroExit(code: exitCode, summary: summary)
        }

        return ToolResult(summary: summary)
    }

    private static func waitForExit(_ process: Process, timeout: Duration) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        let pollInterval = Duration.milliseconds(50)
        while process.isRunning {
            try await Task.sleep(for: pollInterval)
            if ContinuousClock.now >= deadline {
                process.terminate()
                let graceDeadline = ContinuousClock.now.advanced(by: gracePeriod)
                while process.isRunning && ContinuousClock.now < graceDeadline {
                    try await Task.sleep(for: pollInterval)
                }
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
                throw TerminalToolExecutorError.timeout
            }
        }
    }

    private static func readPipe(_ pipe: Pipe) -> String {
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func formatSummary(exitCode: Int32, stdout: String, stderr: String) -> String {
        """
        exit=\(exitCode)
        stdout=\(String(stdout.prefix(outputPreviewLimit)))
        stderr=\(String(stderr.prefix(outputPreviewLimit)))
        """
    }
}
