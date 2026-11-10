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
/// the HTTP status plus a bounded body. Redirects may not leave the initial
/// HTTPS origin. The task is cancelled once retained body data reaches
/// `maxResponseBytes`; network buffering may already have read additional bytes.
/// DNS resolution and private-network access are not restricted by this executor.
/// Incomplete trailing UTF-8 bytes are discarded.
/// `TaskService.bounded(_:)` further caps the resulting summary at 512 chars
/// when it lands in the audit log, so the executor's cap should comfortably
/// fit under that envelope.
public struct WebFetchToolExecutor: ToolExecutor, Sendable {
    public let session: URLSession
    public let timeout: TimeInterval
    public let maxResponseBytes: Int

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

        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host, !host.isEmpty, components.user == nil, components.password == nil else {
            throw WebFetchToolExecutorError.invalidURL(request.target)
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.timeoutInterval = timeout
        let transfer = FetchTransfer(original: url, limit: max(0, maxResponseBytes))
        let (data, response) = try await transfer.run(request: urlRequest, configuration: session.configuration)
        guard (200..<300).contains(response.statusCode) else { throw WebFetchToolExecutorError.httpStatus(response.statusCode) }
        var prefix = data
        for _ in 0..<3 where !prefix.isEmpty && String(data: prefix, encoding: .utf8) == nil { prefix.removeLast() }
        return ToolResult(summary: "HTTP \(response.statusCode)\n\(String(data: prefix, encoding: .utf8) ?? "")")
    }

}

/// A redirect cannot expand the initial policy-approved origin.
enum FetchRedirectPolicy {
    static func permits(original: URL, destination: URL) -> Bool {
        guard let a = URLComponents(url: original, resolvingAgainstBaseURL: false),
              let b = URLComponents(url: destination, resolvingAgainstBaseURL: false),
              a.scheme?.lowercased() == "https", b.scheme?.lowercased() == "https",
              let host = a.host?.lowercased(), !host.isEmpty, b.host?.lowercased() == host,
              b.user == nil, b.password == nil else { return false }
        return (a.port ?? 443) == (b.port ?? 443)
    }
}

struct FetchBoundedBuffer {
    private(set) var data = Data()
    let limit: Int
    init(limit: Int) { self.limit = max(0, limit) }
    mutating func append(_ chunk: Data) -> Bool {
        let remaining = max(0, limit - data.count)
        data.append(contentsOf: chunk.prefix(remaining))
        return data.count >= limit
    }
}

/// Each task owns its own session and delegate; data is bounded while arriving.
final class FetchTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let original: URL
    private var buffer: FetchBoundedBuffer
    private var response: HTTPURLResponse?
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    private var task: URLSessionDataTask?
    private var session: URLSession?
    private var reachedLimit = false
    private var cancelled = false
    private var redirectRejected = false
    init(original: URL, limit: Int) { self.original = original; self.buffer = FetchBoundedBuffer(limit: limit) }

    static func isolatedConfiguration(from source: URLSessionConfiguration) -> URLSessionConfiguration {
        let config = (source.copy() as? URLSessionConfiguration) ?? .ephemeral
        config.httpAdditionalHeaders = nil
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return config
    }

    func run(request: URLRequest, configuration: URLSessionConfiguration) async throws -> (Data, HTTPURLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                let session = URLSession(configuration: Self.isolatedConfiguration(from: configuration), delegate: self, delegateQueue: nil)
                self.session = session
                let task = session.dataTask(with: request)
                self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: { self.cancel() }
    }
    private func cancel() {
        lock.lock(); cancelled = true; let task = self.task; lock.unlock(); task?.cancel()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        let allowed = request.url.map { FetchRedirectPolicy.permits(original: original, destination: $0) } ?? false
        if !allowed { lock.lock(); redirectRejected = true; lock.unlock() }
        completionHandler(allowed ? request : nil)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        lock.lock(); self.response = response as? HTTPURLResponse; lock.unlock()
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock(); let full = buffer.append(data); if full { reachedLimit = true }; lock.unlock()
        if full { dataTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = self.continuation; self.continuation = nil
        let response = self.response; let data = buffer.data; let full = reachedLimit; let cancelled = self.cancelled; let rejected = redirectRejected
        self.task = nil; self.session = nil
        lock.unlock()
        session.finishTasksAndInvalidate()
        guard let continuation else { return }
        if cancelled { continuation.resume(throwing: CancellationError()) }
        else if rejected { continuation.resume(throwing: WebFetchToolExecutorError.underlying("redirect outside approved origin")) }
        else if let error, !full { continuation.resume(throwing: WebFetchToolExecutorError.underlying(String(describing: error))) }
        else if let response { continuation.resume(returning: (data, response)) }
        else { continuation.resume(throwing: WebFetchToolExecutorError.underlying("non-HTTP response")) }
    }
}
