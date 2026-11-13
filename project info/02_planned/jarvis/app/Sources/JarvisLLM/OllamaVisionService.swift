import Foundation

/// Explicit user-provided image and instruction; this type never captures a screen.
public struct VisionRequest: Sendable {
    public static let maximumImageBytes = 5 * 1024 * 1024
    public static let maximumPromptBytes = 16 * 1024
    let prompt: String
    let image: Data
    public init(prompt: String, image: Data) throws {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              prompt.utf8.count <= Self.maximumPromptBytes,
              !image.isEmpty, image.count <= Self.maximumImageBytes else { throw VisionError.invalidRequest }
        self.prompt = prompt; self.image = image
    }
}

/// Errors intentionally omit input, server responses, and network diagnostics.
public enum VisionError: Error, LocalizedError {
    case invalidRequest, invalidEndpoint, unavailable, invalidResponse, busy
    public var errorDescription: String? {
        switch self {
        case .invalidRequest: "图片或提示词为空或超出大小限制。"
        case .invalidEndpoint: "图片理解仅支持本机回环地址。"
        case .unavailable: "本机图片理解服务不可用。"
        case .invalidResponse: "本机图片理解服务返回无效结果。"
        case .busy: "图片理解服务已有请求正在处理。"
        }
    }
}

/// Keeps only bounded application-owned response data. URLSession and the OS
/// may maintain their own transient network buffers outside this limit.
private final class VisionTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var data = Data()
    private var finished = false
    private var cancelled = false

    func start(request: URLRequest, configuration: URLSessionConfiguration,
               continuation: CheckedContinuation<Data, Error>) {
        lock.lock()
        if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
        self.continuation = continuation
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        let task = session.dataTask(with: request)
        self.session = session; self.task = task
        lock.unlock()
        task.resume()
    }
    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        finish(.failure(CancellationError()))
    }
    private func finish(_ result: Result<Data, Error>) {
        lock.lock()
        guard !finished, let continuation else { lock.unlock(); return }
        finished = true; self.continuation = nil
        let task = self.task, session = self.session
        self.task = nil; self.session = nil; data.removeAll()
        lock.unlock()
        task?.cancel(); session?.invalidateAndCancel()
        continuation.resume(with: result)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            completionHandler(.cancel); finish(.failure(VisionError.unavailable)); return
        }
        if response.expectedContentLength > Int64(OllamaVisionService.maximumResponseBytes) {
            completionHandler(.cancel); finish(.failure(VisionError.invalidResponse)); return
        }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        guard chunk.count <= OllamaVisionService.maximumResponseBytes - data.count else {
            lock.unlock(); finish(.failure(VisionError.invalidResponse)); return
        }
        data.append(chunk); lock.unlock()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if error != nil { finish(.failure(VisionError.unavailable)); return }
        lock.lock(); let result = data; lock.unlock()
        finish(.success(result))
    }
}

private final class VisionRequestGate: @unchecked Sendable {
    static let shared = VisionRequestGate()
    private let lock = NSLock()
    private var inFlight = false
    func begin() -> Bool { lock.lock(); defer { lock.unlock() }; guard !inFlight else { return false }; inFlight = true; return true }
    func end() { lock.lock(); defer { lock.unlock() }; inFlight = false }
}

/// An explicit local request; the loopback server must be trusted and may itself forward data.
/// No image is read or sent until `describe` is called with a user-supplied request.
public final class OllamaVisionService: @unchecked Sendable {
    private let endpoint: URL
    private let model: String
    private let configuration: URLSessionConfiguration
    static let maximumResponseBytes = 1024 * 1024
    public convenience init(baseURL: URL = URL(string: "http://127.0.0.1:11434")!, model: String) throws {
        try self.init(baseURL: baseURL, model: model, configuration: .ephemeral)
    }
    init(baseURL: URL, model: String, configuration: URLSessionConfiguration) throws {
        guard let components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "http",
              ["127.0.0.1", "[::1]", "::1"].contains(components.host?.lowercased() ?? ""),
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/",
              !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              model.utf8.count <= 256 else { throw VisionError.invalidEndpoint }
        endpoint = baseURL.appendingPathComponent("api/chat")
        self.model = model
        configuration.connectionProxyDictionary = ["HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0]
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        self.configuration = configuration
    }
    public func describe(_ input: VisionRequest) async throws -> String {
        guard VisionRequestGate.shared.begin() else { throw VisionError.busy }
        defer { VisionRequestGate.shared.end() }
        struct Message: Encodable { let role: String; let content: String; let images: [String] }
        struct Request: Encodable { let model: String; let messages: [Message]; let stream = false }
        struct Response: Decodable { struct Message: Decodable { let content: String }; let message: Message; let done: Bool }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Request(model: model, messages: [Message(role: "user", content: input.prompt, images: [input.image.base64EncodedString()])]))
        let transfer = VisionTransfer()
        let data = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                transfer.start(request: request, configuration: configuration, continuation: continuation)
            }
        } onCancel: { transfer.cancel() }
        guard let result = try? JSONDecoder().decode(Response.self, from: data), result.done,
              !result.message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw VisionError.invalidResponse }
        try Task.checkCancellation()
        return result.message.content
    }
}
