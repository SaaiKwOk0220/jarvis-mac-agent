import SwiftUI
import AppKit
import Darwin
import JarvisLLM

/// Reads only a user-selected regular PNG or JPEG; it never captures a screen.
enum VisionImageSelection {
    static func validate(_ data: Data) throws {
        let png = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
        let jpeg = Data([0xff, 0xd8, 0xff])
        guard data.count <= VisionRequest.maximumImageBytes,
              data.starts(with: png) || data.starts(with: jpeg) else { throw VisionError.invalidRequest }
    }
    static func read(_ url: URL) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
        guard descriptor >= 0 else { throw VisionError.invalidRequest }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw VisionError.invalidRequest }
        let data = try file.read(upToCount: VisionRequest.maximumImageBytes + 1) ?? Data()
        try validate(data)
        return data
    }
}

/// Explicit single-image request. No network action occurs until the user submits.
struct VisionImageView: View {
    @State private var selected: URL?
    @State private var endpoint = "http://127.0.0.1:11434"
    @State private var model = "qwen2.5vl:3b"
    @State private var question = "请描述这张图片。"
    @State private var result = ""
    @State private var running = false
    @State private var generation = UUID()
    @State private var requestTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("图片理解实验").font(.title2.bold())
            Text("仅在点击分析后发送你选择的图片和问题。请确认本机服务与模型可信；服务可能将数据转发到其他地方。")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("选择图片…") { chooseImage() }.disabled(running)
                Text(selected?.lastPathComponent ?? "尚未选择图片").lineLimit(1)
            }
            Text("支持 PNG 或 JPEG，最大 5 MiB。不会自动读取屏幕或浏览器。")
                .font(.caption).foregroundStyle(.secondary)
            TextField("本机服务地址", text: $endpoint).disabled(running)
            TextField("视觉模型名称", text: $model).disabled(running)
            TextField("关于图片的问题", text: $question, axis: .vertical).lineLimit(2...4).disabled(running)
            HStack {
                Button("分析图片") { submit() }.disabled(running || selected == nil || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if running { Button("取消") { cancel() } }
            }
            ScrollView { Text(result.isEmpty ? "结果会显示在这里。" : result).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(24)
        .onDisappear { cancel() }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { selected = panel.url; result = "" }
    }
    private func submit() {
        guard let selected, let url = URL(string: endpoint) else { result = "请检查本机服务地址。"; return }
        let prompt = question
        let selectedModel = model
        let current = UUID(); generation = current; running = true; result = "正在分析…"
        requestTask = Task {
            do {
                let service = try OllamaVisionService(baseURL: url, model: selectedModel)
                let data = try await Task.detached { try VisionImageSelection.read(selected) }.value
                try Task.checkCancellation()
                let answer = try await service.describe(VisionRequest(prompt: prompt, image: data))
                guard generation == current, !Task.isCancelled else { return }
                result = answer
            } catch {
                guard generation == current, !Task.isCancelled else { return }
                result = (error as? VisionError)?.localizedDescription ?? "图片读取或分析失败，请检查图片和本机服务。"
            }
            if generation == current { running = false; requestTask = nil }
        }
    }
    private func cancel() {
        generation = UUID(); requestTask?.cancel(); requestTask = nil
        if running { result = "已取消。" }
        running = false
    }
}
