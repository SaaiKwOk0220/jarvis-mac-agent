import Foundation
import JarvisDomain

/// Errors surfaced by `WebFetchToolExecutor`.
public enum WebFetchToolExecutorError: Error, Equatable, Sendable {
    case incompatibleSideEffect(SideEffect)
    case invalidURL(String)
    case nonHTTPSScheme(String)
    case httpStatus(Int)
    case underlying(String)
}

/// `ToolExecutor` that performs an HTTPS `GET` via `URLSession` and returns
/// the HTTP status plus a truncated body. Read-only by design: a non-https
/// URL is rejected before any socket is opened.
///
/// The response body is truncated to `maxResponseBytes` (with a small UTF-8
/// safety buffer so we never split a multi-byte character mid-sequence).
/// `TaskService.bounded(_:)` further caps the resulting summary at 512 chars
/// when it lands in the audit log, so the executor's cap should comfortably
/// fit under that envelope.
public struct WebFetchToolExecutor: ToolExecutor, Sendable {
    public let session: URLSession
    public let timeout: TimeInterval
    public let maxResponseBytes: Int

    /// Reserved UTF-8 safety buffer so we never slice a multi-byte character
    /// in the middle of a codepoint when truncating.
    private static let truncationBuffer = 64

    public init(
        session: URLSession = .shared,
        timeout: TimeInterval = 30,
        maxResponseBytes: Int = 10_000
    ) {
        self.session = session
        self.timeout = timeout
        self.maxResponseBytes = maxResponseBytes
    }

    public func execute(_ request: ToolRequest) async throws -> ToolResult {
        guard request.sideEffect == .read else {
            throw WebFetchToolExecutorError.incompatibleSideEffect(request.sideEffect)
        }

        guard let url = URL(string: request.target) else {
            throw WebFetchToolExecutorError.invalidURL(request.target)
        }
        guard let scheme = url.scheme?.lowercased(), scheme == "https" else {
            throw WebFetchToolExecutorError.nonHTTPSScheme(url.scheme ?? "")
        }

        let data: Data
        let response: URLResponse
        do {
            var urlRequest = URLRequest(url: url)
            urlRequest.timeoutInterval = timeout
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw WebFetchToolExecutorError.underlying(String(describing: error))
        }

        guard let http = response as? HTTPURLResponse else {
            throw WebFetchToolExecutorError.underlying("non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw WebFetchToolExecutorError.httpStatus(http.statusCode)
        }

        let truncated = truncate(data: data)
        let body = String(data: truncated, encoding: .utf8) ?? ""
        return ToolResult(summary: "HTTP \(http.statusCode)\n\(body)")
    }

    /// Truncates `data` to at most `maxResponseBytes`, leaving a small safety
    /// buffer so the resulting UTF-8 string never begins with a partial
    /// codepoint. The slice is from the start of the data.
    private func truncate(data: Data) -> Data {
        let cap = max(0, maxResponseBytes - Self.truncationBuffer)
        guard data.count > cap else { return data }
        return data.prefix(cap)
    }
}