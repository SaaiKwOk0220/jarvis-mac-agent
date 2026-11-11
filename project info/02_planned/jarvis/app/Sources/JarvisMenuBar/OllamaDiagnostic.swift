import Foundation

enum OllamaDiagnostic: Equatable {
    case ready, modelMissing, unavailable, unexpectedResponse

    static func classify(status: Int, data: Data, model: String) -> Self {
        struct ModelList: Decodable { struct Item: Decodable { let name: String }; let models: [Item] }
        guard status == 200, let list = try? JSONDecoder().decode(ModelList.self, from: data) else { return .unexpectedResponse }
        return list.models.contains { $0.name == model } ? .ready : .modelMissing
    }

    static func check() async -> Self {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        guard let url = URL(string: "http://127.0.0.1:11434/api/tags") else { return .unexpectedResponse }
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse else { return .unexpectedResponse }
            return classify(status: http.statusCode, data: data, model: "qwen3:4b-instruct")
        } catch { return .unavailable }
    }

    var message: String {
        switch self {
        case .ready: return "本机模型服务可连接，已找到 qwen3:4b-instruct。若仍无法回答，请查看任务错误。"
        case .modelMissing: return "服务可连接，但未找到 qwen3:4b-instruct。可在终端运行 ollama pull qwen3:4b-instruct，完成后重新检查。"
        case .unavailable: return "无法连接本机 Ollama（127.0.0.1:11434）。请打开 Ollama 应用；若使用终端，可运行 ollama serve，再点击重新检查。"
        case .unexpectedResponse: return "本机模型服务返回无法识别的结果。请检查 Ollama 是否正常运行后重试。"
        }
    }
}
