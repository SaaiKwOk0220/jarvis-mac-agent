import Foundation
import JarvisLLM

private final class RejectRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum OllamaDiagnostic: Equatable {
    case ready, modelMissing, unavailable, unexpectedResponse, cancelled

    static func classify(status: Int, data: Data, model: String) -> Self {
        struct ModelList: Decodable { struct Item: Decodable { let name: String }; let models: [Item] }
        guard status == 200, let list = try? JSONDecoder().decode(ModelList.self, from: data) else { return .unexpectedResponse }
        return list.models.contains { $0.name == model } ? .ready : .modelMissing
    }

    static func localSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 4
        configuration.connectionProxyDictionary = [:]
        return URLSession(configuration: configuration, delegate: RejectRedirects(), delegateQueue: nil)
    }

    static func check() async -> Self {
        let session = localSession()
        defer { session.invalidateAndCancel() }
        let provider = OllamaProvider()
        return await check(url: provider.baseURL.appendingPathComponent("api/tags"), session: session, model: provider.model)
    }

    static func check(url: URL, session: URLSession, timeout: Duration = .seconds(4), limit: Int = 262_144, model: String = "qwen3:4b-instruct") async -> Self {
        guard limit > 0 else { return .unexpectedResponse }
        // This is a cooperative deadline: task-group teardown waits for URLSession
        // cancellation to complete, so scheduler/transport delays can extend it.
        return await withTaskGroup(of: Self.self) { group in
            group.addTask {
                do {
                    let (bytes, response) = try await session.bytes(from: url)
                    guard let http = response as? HTTPURLResponse else { return .unexpectedResponse }
                    var data = Data()
                    for try await byte in bytes {
                        guard data.count < limit else { return .unexpectedResponse }
                        data.append(byte)
                    }
                    return classify(status: http.statusCode, data: data, model: model)
                } catch { return Task.isCancelled ? .cancelled : .unavailable }
            }
            group.addTask {
                do { try await Task.sleep(for: timeout); return .unavailable }
                catch { return .cancelled }
            }
            let result = await group.next() ?? .cancelled
            group.cancelAll()
            return Task.isCancelled ? .cancelled : result
        }
    }

    var message: String {
        switch self {
        case .cancelled: return "检查已取消。"
        case .ready: return "默认本机模型服务可连接，已找到 qwen3:4b-instruct。若仍无法回答，请查看任务错误。"
        case .modelMissing: return "默认服务可连接，但未找到 qwen3:4b-instruct。可在终端运行 ollama pull qwen3:4b-instruct，完成后重新检查。"
        case .unavailable: return "无法连接默认本机 Ollama（127.0.0.1:11434）。请打开 Ollama 应用；若使用终端，可运行 ollama serve，再点击重新检查。"
        case .unexpectedResponse: return "默认本机模型服务返回无法识别的结果。请检查 Ollama 是否正常运行后重试。"
        }
    }
}
