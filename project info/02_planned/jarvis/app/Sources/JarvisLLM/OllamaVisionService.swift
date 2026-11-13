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
    case invalidRequest, invalidEndpoint, unavailable, invalidResponse
    public var errorDescription: String? {
        switch self {
        case .invalidRequest: "图片或提示词为空或超出大小限制。"
        case .invalidEndpoint: "图片理解仅支持本机回环地址。"
        case .unavailable: "本机图片理解服务不可用。"
        case .invalidResponse: "本机图片理解服务返回无效结果。"
        }
    }
}

private final class VisionRedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// An explicit local request; the loopback server must be trusted and may itself forward data.
/// No image is read or sent until `describe` is called with a user-supplied request.
public final class OllamaVisionService: @unchecked Sendable {
    private let endpoint: URL
    private let model: String
    private let session: URLSession
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
        configuration.connectionProxyDictionary = [:]
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        session = URLSession(configuration: configuration, delegate: VisionRedirectBlocker(), delegateQueue: nil)
    }
    public func describe(_ input: VisionRequest) async throws -> String {
        struct Message: Encodable { let role: String; let content: String; let images: [String] }
        struct Request: Encodable { let model: String; let messages: [Message]; let stream = false }
        struct Response: Decodable { struct Message: Decodable { let content: String }; let message: Message }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Request(model: model, messages: [Message(role: "user", content: input.prompt, images: [input.image.base64EncodedString()])]))
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }; throw VisionError.unavailable }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw VisionError.unavailable }
        guard let result = try? JSONDecoder().decode(Response.self, from: data),
              !result.message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw VisionError.invalidResponse }
        return result.message.content
    }
}
