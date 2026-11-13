import JarvisDomain

import XCTest
@testable import JarvisService

final class SafariVisiblePageTests: XCTestCase {
    func testPermissionDenialExplainsSettingsAndRetry() {
        let text = SafariAXReadError.permissionDenied.localizedDescription
        XCTAssertTrue(text.contains("隐私与安全性"))
        XCTAssertTrue(text.contains("辅助功能"))
        XCTAssertTrue(text.contains("local.jarvis.safari-experiment"))
        XCTAssertTrue(text.contains("重新提交"))
    }

    func testRejectsChangedTargetBeforeReturningPage() async throws {
        let reader = SafariVisiblePageReader { _ in SafariPageSnapshot(bundleID: "com.apple.Safari", url: "https://other.example/", text: "private") }
        do {
            _ = try await reader.read(expectedURL: "https://example.com/")
            XCTFail("Mismatched page must be rejected")
        } catch SafariVisiblePageError.targetChanged {}
    }
    func testReturnsOnlyMatchingSafariSnapshot() async throws {
        let reader = SafariVisiblePageReader { _ in SafariPageSnapshot(bundleID: "com.apple.Safari", url: "https://example.com/", text: "visible") }
        let text = try await reader.read(expectedURL: "https://example.com/")
        XCTAssertEqual(text, "visible")
    }
}

private actor PageSequence {
    var count = 0
    func next(_ expectedURL: String) -> SafariPageSnapshot {
        count += 1
        return SafariPageSnapshot(bundleID: "com.apple.Safari", url: expectedURL, text: "version \(count)")
    }
}

extension SafariVisiblePageTests {
    func testReaderDoesNotCachePageTextAcrossCalls() async throws {
        let pages = PageSequence()
        let reader = SafariVisiblePageReader { expected in await pages.next(expected) }
        let first = try await reader.read(expectedURL: "https://example.com/")
        let second = try await reader.read(expectedURL: "https://example.com/")
        XCTAssertEqual(first, "version 1")
        XCTAssertEqual(second, "version 2")
    }

    func testExecutorRejectsUnapprovedTargetShape() async throws {
        let reader = SafariVisiblePageReader { _ in XCTFail("invalid input must not read"); return SafariPageSnapshot(bundleID: "com.apple.Safari", url: "", text: "") }
        let executor = SafariPageReadExecutor(reader: reader)
        let request = ToolRequest(taskID: UUID(), name: "safari_read", sideEffect: .read, target: "https://example.com/private?token=secret", payload: "Read Safari accessibility text")
        do { _ = try await executor.execute(request); XCTFail("expected rejection") }
        catch SafariAXReadError.unavailable { }
    }
}

private actor FocusScript {
    private(set) var calls = 0
    func next(_ expected: String) throws -> SafariPageSnapshot {
        calls += 1
        if calls < 3 { throw SafariAXReadError.notFocused }
        return SafariPageSnapshot(bundleID: "com.apple.Safari", url: expected, text: "visible")
    }
}

extension SafariVisiblePageTests {
    func testWaitsForSafariWithoutBlockingUntilItIsFocused() async throws {
        let script = FocusScript()
        let reader = SafariVisiblePageReader { try await script.next($0) }
        let executor = SafariPageReadExecutor(reader: reader, focusTimeout: .seconds(1), focusPollInterval: .milliseconds(10))
        let request = ToolRequest(taskID: UUID(), name: "safari_read", sideEffect: .read, target: "https://example.com/", payload: "Read Safari accessibility text")
        let result = try await executor.execute(request)
        XCTAssertEqual(result.summary, "visible")
        let count = await script.calls
        XCTAssertEqual(count, 3)
    }

    func testPermissionAndTargetChangesFailImmediately() async throws {
        let request = ToolRequest(taskID: UUID(), name: "safari_read", sideEffect: .read, target: "https://example.com/", payload: "Read Safari accessibility text")
        for error in [SafariAXReadError.permissionDenied, .targetChanged] {
            let reader = SafariVisiblePageReader { _ in throw error }
            let executor = SafariPageReadExecutor(reader: reader, focusTimeout: .seconds(1), focusPollInterval: .milliseconds(10))
            let start = ContinuousClock.now
            do { _ = try await executor.execute(request); XCTFail("expected failure") }
            catch let actual as SafariAXReadError { XCTAssertEqual(String(describing: actual), String(describing: error)) }
            XCTAssertLessThan(start.duration(to: .now), .milliseconds(500))
        }
    }

    func testFocusWaitIsBoundedAndCancellable() async throws {
        let reader = SafariVisiblePageReader { _ in throw SafariAXReadError.notFocused }
        let request = ToolRequest(taskID: UUID(), name: "safari_read", sideEffect: .read, target: "https://example.com/", payload: "Read Safari accessibility text")
        let short = SafariPageReadExecutor(reader: reader, focusTimeout: .milliseconds(30), focusPollInterval: .milliseconds(10))
        do { _ = try await short.execute(request); XCTFail("expected timeout") } catch SafariAXReadError.focusTimedOut { }
        let long = SafariPageReadExecutor(reader: reader, focusTimeout: .seconds(5), focusPollInterval: .milliseconds(10))
        let task = Task { try await long.execute(request) }
        try await Task.sleep(for: .milliseconds(30))
        task.cancel()
        do { _ = try await task.value; XCTFail("expected cancellation") } catch is CancellationError { }
    }
}
