import Foundation
import XCTest
import JarvisDomain
@testable import JarvisService

/// Verifies `AccessibilityQueryToolExecutor`'s read-side contract: it parses
/// the request into an `AXQuery`, hands it to the injected query closure, and
/// embeds the returned tree in the `ToolResult.summary`. The query closure is
/// injected (default = real `AXUIElement` walk) so the tests stay CI-friendly
/// without invoking the Accessibility permission flow or reading any real
/// app's element tree.
final class AccessibilityQueryToolExecutorTests: XCTestCase {
    /// Pins the happy path: the canned tree the closure returns is embedded in
    /// `ToolResult.summary` alongside the target so the task timeline shows
    /// both what was inspected and the resulting role/title rendering.
    func testAXQueryFormatsTreeWithRoleAndTitle() async throws {
        let executor = AccessibilityQueryToolExecutor(query: { _ in
            "AXWindow \"Safari\"\n  AXButton \"Reload\""
        })
        let request = ToolRequest(
            taskID: UUID(),
            name: "ax_query",
            sideEffect: .read,
            target: "com.apple.Safari",
            payload: ""
        )

        let result = try await executor.execute(request)

        XCTAssertTrue(result.summary.contains("com.apple.Safari"),
            "summary must name the inspected target; got: \(result.summary)")
        XCTAssertTrue(result.summary.contains("AXWindow \"Safari\""),
            "summary must carry the role + title line; got: \(result.summary)")
        XCTAssertTrue(result.summary.contains("AXButton \"Reload\""),
            "summary must carry nested child lines; got: \(result.summary)")
    }

    /// The executor is read-only: a request carrying `sideEffect == .localWrite`
    /// (or any other non-read side effect) must be rejected before the query
    /// closure is invoked. We use `.localWrite` as a representative non-read
    /// side effect and verify the typed error surfaces.
    func testAXQueryRejectsWrongSideEffect() async throws {
        let executor = AccessibilityQueryToolExecutor(query: { _ in "should-not-run" })
        let request = ToolRequest(
            taskID: UUID(),
            name: "ax_query",
            sideEffect: .localWrite,
            target: "com.apple.Safari",
            payload: ""
        )

        do {
            _ = try await executor.execute(request)
            XCTFail("Expected executor to reject .localWrite")
        } catch let AccessibilityQueryToolExecutorError.incompatibleSideEffect(sideEffect) {
            XCTAssertEqual(sideEffect, .localWrite)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    /// The payload carries the walk bounds as JSON. This pins that a
    /// `{"maxDepth": 6}` payload reaches the query closure as `maxDepth == 6`
    /// rather than being silently ignored in favour of the default.
    func testAXQueryParsesMaxDepthFromPayload() async throws {
        let recorder = AXQueryRecorder()
        let executor = AccessibilityQueryToolExecutor(query: { axQuery in
            recorder.record(axQuery)
            return "tree"
        })
        let request = ToolRequest(
            taskID: UUID(),
            name: "ax_query",
            sideEffect: .read,
            target: "com.apple.Safari",
            payload: "{\"maxDepth\": 6}"
        )

        _ = try await executor.execute(request)

        XCTAssertEqual(recorder.last?.maxDepth, 6,
            "payload maxDepth must be forwarded to the query closure")
    }

    /// An empty payload means "use the defaults" — the executor must not throw
    /// and must hand the closure `maxDepth == 4` so the UI can submit an
    /// inspection without filling in a payload.
    func testAXQueryDefaultsMaxDepthWhenPayloadEmpty() async throws {
        let recorder = AXQueryRecorder()
        let executor = AccessibilityQueryToolExecutor(query: { axQuery in
            recorder.record(axQuery)
            return "tree"
        })
        let request = ToolRequest(
            taskID: UUID(),
            name: "ax_query",
            sideEffect: .read,
            target: "com.apple.Safari",
            payload: ""
        )

        _ = try await executor.execute(request)

        XCTAssertEqual(recorder.last?.maxDepth, 4,
            "empty payload must fall back to the default maxDepth")
    }
}

/// Thread-safe capture of the `AXQuery` the executor hands to the query
/// closure. The closure is `@Sendable`, so the recorder must be safe to call
/// from any executor context.
private final class AXQueryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [AXQuery] = []

    func record(_ axQuery: AXQuery) {
        lock.lock()
        recorded.append(axQuery)
        lock.unlock()
    }

    var last: AXQuery? {
        lock.lock()
        defer { lock.unlock() }
        return recorded.last
    }
}
