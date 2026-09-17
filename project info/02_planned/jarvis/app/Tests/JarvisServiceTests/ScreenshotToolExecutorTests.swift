import Foundation
import XCTest
import JarvisDomain
@testable import JarvisService

/// Verifies `ScreenshotToolExecutor`'s read-side path: it writes the data
/// returned by the injected capture closure to the request target, creates
/// any missing parent directory, and surfaces typed errors when the request
/// shape is wrong or the capture closure throws. The capture closure is
/// injected (default = real ScreenCaptureKit) so the tests stay
/// CI-friendly without invoking any actual screen recording permission flow.
final class ScreenshotToolExecutorTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("jarvis-screenshot-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        try super.tearDownWithError()
    }

    /// Pins the happy path: the closure's bytes are written verbatim to
    /// `request.target` and the summary includes the path + byte count.
    /// The byte count is the contract a user would rely on when checking
    /// that a capture actually produced a non-empty PNG.
    func testScreenshotWritesImageDataToTarget() async throws {
        let bytes = Data(repeating: 0xAB, count: 100)
        let executor = ScreenshotToolExecutor(capture: { bytes })
        let target = tempRoot.appendingPathComponent("screen.png").path
        let request = ToolRequest(
            taskID: UUID(),
            name: "screenshot",
            sideEffect: .read,
            target: target,
            payload: "screen"
        )

        let result = try await executor.execute(request)

        XCTAssertEqual(result.summary, "Screenshot saved to \(target) (100 bytes)")
        let written = try Data(contentsOf: URL(fileURLWithPath: target))
        XCTAssertEqual(written, bytes, "executor must persist the bytes returned by the capture closure")
    }

    /// Confirms the executor is responsible for making the parent directory —
    /// the request arrives with a target whose parent does not exist and we
    /// expect it to be created via `createDirectory(withIntermediateDirectories: true)`.
    /// Without this, callers would have to pre-create the screenshots folder
    /// out of band on every cold launch.
    func testScreenshotCreatesMissingDirectory() async throws {
        let bytes = Data([0x89, 0x50, 0x4E, 0x47])
        let executor = ScreenshotToolExecutor(capture: { bytes })
        let nested = tempRoot
            .appendingPathComponent("nested")
            .appendingPathComponent("deeper")
            .appendingPathComponent("capture.png")
        XCTAssertFalse(FileManager.default.fileExists(atPath: nested.deletingLastPathComponent().path),
            "precondition: parent directory must not exist")
        let request = ToolRequest(
            taskID: UUID(),
            name: "screenshot",
            sideEffect: .read,
            target: nested.path,
            payload: "screen"
        )

        _ = try await executor.execute(request)

        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.path),
            "executor must create the missing parent directory and write the file")
        XCTAssertEqual(try Data(contentsOf: nested), bytes)
    }

    /// The executor is read-only: a request carrying `sideEffect == .localWrite`
    /// (or any other non-read side effect) must be rejected before the capture
    /// closure is invoked. We use `.localWrite` as a representative non-read
    /// side effect and verify the typed error surfaces.
    func testScreenshotRejectsWrongSideEffect() async throws {
        let executor = ScreenshotToolExecutor(capture: { Data() })
        let request = ToolRequest(
            taskID: UUID(),
            name: "screenshot",
            sideEffect: .localWrite,
            target: tempRoot.appendingPathComponent("not-allowed.png").path,
            payload: "screen"
        )

        do {
            _ = try await executor.execute(request)
            XCTFail("Expected executor to reject .localWrite")
        } catch let ScreenshotToolExecutorError.incompatibleSideEffect(sideEffect) {
            XCTAssertEqual(sideEffect, .localWrite)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    /// When the injected capture closure throws, the executor must surface
    /// the failure as a typed `underlying(String)` rather than leaking the
    /// raw error type. The wrapping lets the menu bar present a friendly
    /// error message (e.g. "Screen Recording permission denied") instead of
    /// the raw Swift error description.
    func testScreenshotPropagatesCaptureError() async throws {
        struct CaptureFailed: Error {}
        let executor = ScreenshotToolExecutor(capture: { throw CaptureFailed() })
        let request = ToolRequest(
            taskID: UUID(),
            name: "screenshot",
            sideEffect: .read,
            target: tempRoot.appendingPathComponent("never-written.png").path,
            payload: "screen"
        )

        do {
            _ = try await executor.execute(request)
            XCTFail("Expected executor to surface the capture failure")
        } catch let ScreenshotToolExecutorError.underlying(message) {
            XCTAssertFalse(message.isEmpty,
                "underlying message should carry the source error description; got empty string")
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: request.target),
            "no file should be written when the capture closure throws"
        )
    }
}
