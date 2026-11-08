import Darwin
import Foundation
import XCTest
import JarvisDomain
@testable import JarvisService

final class TerminalToolExecutorTests: XCTestCase {
    func testSandboxDeniesRealFileWrite() throws {
        let path = "/private/tmp/jarvis-sandbox-test-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = ["-p", TerminalToolExecutor.sandboxProfile, "/usr/bin/touch", path]
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        XCTAssertNotEqual(process.terminationStatus, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testSandboxDeniesLoopbackNetwork() throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(listener, 0)
        defer { close(listener) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: in_addr_t(0x0100007f))
        let bindResult = withUnsafePointer(to: &address) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        XCTAssertEqual(bindResult, 0)
        XCTAssertEqual(listen(listener, 1), 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &address) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) }
        }
        XCTAssertEqual(nameResult, 0)
        let port = UInt16(bigEndian: address.sin_port)
        func run(_ sandboxed: Bool) throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: sandboxed ? "/usr/bin/sandbox-exec" : "/usr/bin/nc")
            let args = ["-z", "-w", "2", "127.0.0.1", String(port)]
            process.arguments = sandboxed ? ["-p", TerminalToolExecutor.sandboxProfile, "/usr/bin/nc"] + args : args
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }
        XCTAssertEqual(try run(false), 0, "test listener must be reachable")
        XCTAssertNotEqual(try run(true), 0, "sandbox must deny loopback")
    }

    func testSandboxLaunchFailureDoesNotFallBack() async throws {
        let executor = TerminalToolExecutor(sandboxExecutableURL: URL(fileURLWithPath: "/nonexistent/jarvis-sandbox"))
        let request = ToolRequest(taskID: UUID(), name: "shell", sideEffect: .localExecute, target: "/tmp", payload: "pwd")
        do {
            _ = try await executor.execute(request)
            XCTFail("missing sandbox must fail closed")
        } catch TerminalToolExecutorError.launchFailed { }
    }

    func testRejectsWrongSideEffect() async throws {
        let request = ToolRequest(taskID: UUID(), name: "shell", sideEffect: .read, target: "/tmp", payload: "pwd")
        do { _ = try await TerminalToolExecutor().execute(request); XCTFail("expected rejection") }
        catch TerminalToolExecutorError.incompatibleSideEffect(.read) { }
    }

    func testInvalidWorkingDirectoryFailsClosed() async throws {
        let path = "/private/tmp/missing-\(UUID().uuidString)"
        let request = ToolRequest(taskID: UUID(), name: "shell", sideEffect: .localExecute, target: path, payload: "pwd", scope: ToolScope(workingDirectory: path))
        do { _ = try await TerminalToolExecutor().execute(request); XCTFail("expected launch failure") }
        catch TerminalToolExecutorError.launchFailed { }
    }

    func testTimeoutStopsLaunchedProcess() async throws {
        let executable = try slowExecutable()
        defer { try? FileManager.default.removeItem(at: executable) }
        let executor = TerminalToolExecutor(timeout: .milliseconds(100), sandboxExecutableURL: executable)
        let request = ToolRequest(taskID: UUID(), name: "shell", sideEffect: .localExecute, target: "/tmp", payload: "pwd")
        do { _ = try await executor.execute(request); XCTFail("expected timeout") }
        catch TerminalToolExecutorError.timeout { }
    }

    func testCancellationStopsLaunchedProcess() async throws {
        let executable = try slowExecutable()
        defer { try? FileManager.default.removeItem(at: executable) }
        let executor = TerminalToolExecutor(sandboxExecutableURL: executable)
        let request = ToolRequest(taskID: UUID(), name: "shell", sideEffect: .localExecute, target: "/tmp", payload: "pwd")
        let task = Task { try await executor.execute(request) }
        try await Task.sleep(for: .milliseconds(150))
        task.cancel()
        do { _ = try await task.value; XCTFail("expected cancellation") }
        catch is CancellationError { }
    }

    private func slowExecutable() throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp/jarvis-slow-\(UUID().uuidString)")
        try Data("#!/bin/sh\nexec /bin/sleep 10\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

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
