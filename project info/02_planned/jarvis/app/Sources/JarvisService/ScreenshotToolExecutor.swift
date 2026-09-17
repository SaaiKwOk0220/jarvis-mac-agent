import Foundation
import ScreenCaptureKit
import AppKit
import JarvisDomain

/// Errors surfaced by `ScreenshotToolExecutor`.
public enum ScreenshotToolExecutorError: Error, Equatable, Sendable {
    case incompatibleSideEffect(SideEffect)
    case unavailableOS
    case noDisplay
    case encodingFailed
    case underlying(String)
}

/// `ToolExecutor` that captures the main display via `ScreenCaptureKit`
/// (macOS 14+) and writes the resulting PNG bytes to `request.target`.
///
/// Read-only by design: only `sideEffect == .read` is accepted, and the
/// executor writes to an existing directory chosen by the caller (typically
/// `~/Library/Application Support/Jarvis/screenshots/`). The capture step is
/// abstracted behind a `() async throws -> Data` closure so the default can
/// drive real `SCScreenshotManager` while tests substitute a mock that
/// returns canned PNG bytes without ever invoking the Screen Recording
/// permission flow.
public struct ScreenshotToolExecutor: ToolExecutor, Sendable {
    public let capture: @Sendable () async throws -> Data

    public init(capture: @escaping @Sendable () async throws -> Data = Self.defaultCapture) {
        self.capture = capture
    }

    public func execute(_ request: ToolRequest) async throws -> ToolResult {
        guard request.sideEffect == .read else {
            throw ScreenshotToolExecutorError.incompatibleSideEffect(request.sideEffect)
        }
        let data: Data
        do {
            data = try await capture()
        } catch let error as ScreenshotToolExecutorError {
            throw error
        } catch {
            throw ScreenshotToolExecutorError.underlying(String(describing: error))
        }
        let url = URL(fileURLWithPath: request.target)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
        return ToolResult(
            summary: "Screenshot saved to \(request.target) (\(data.count) bytes)"
        )
    }

    /// Default capture that drives `SCScreenshotManager` for the main display
    /// and returns a PNG `Data`. Requires macOS 14+; older systems throw
    /// `.unavailableOS`. Real failures (no display, encoding step not
    /// producing PNG bytes, or Screen Recording permission being denied)
    /// are surfaced as `.underlying(String)` so the menu bar can show the
    /// message and link the user into System Settings.
    public static func defaultCapture() async throws -> Data {
        guard #available(macOS 14.0, *) else {
            throw ScreenshotToolExecutorError.unavailableOS
        }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch {
            throw ScreenshotToolExecutorError.underlying(String(describing: error))
        }
        guard let display = content.displays.first else {
            throw ScreenshotToolExecutorError.noDisplay
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = display.width
        config.height = display.height
        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
        } catch {
            throw ScreenshotToolExecutorError.underlying(String(describing: error))
        }
        guard let tiff = NSBitmapImageRep(cgImage: image).tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else {
            throw ScreenshotToolExecutorError.encodingFailed
        }
        return png
    }
}
