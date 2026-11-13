import SwiftUI
import AppKit
import Darwin
import JarvisLLM
import ImageIO
import UniformTypeIdentifiers

/// Reads only a user-selected regular PNG or JPEG; it never captures a screen.
enum VisionImageSelection {
    struct Snapshot: Sendable {
        let name: String
        let data: Data
        let thumbnail: Data
    }
    static func snapshot(_ url: URL) throws -> Snapshot {
        let data = try readFile(url)
        return Snapshot(name: url.lastPathComponent, data: data, thumbnail: try thumbnail(data))
    }
    static func validate(_ data: Data) throws {
        _ = try thumbnail(data)
    }
    private static func thumbnail(_ data: Data) throws -> Data {
        let png = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
        let jpeg = Data([0xff, 0xd8, 0xff])
        guard data.count <= VisionRequest.maximumImageBytes,
              data.starts(with: png) || data.starts(with: jpeg) else { throw VisionError.invalidRequest }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              CGImageSourceGetStatus(source) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 8192, height <= 8192,
              width * height <= 24_000_000 else { throw VisionError.invalidRequest }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 480,
            kCGImageSourceShouldCacheImmediately: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else { throw VisionError.invalidRequest }
        let result = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(result, UTType.png.identifier as CFString, 1, nil) else { throw VisionError.invalidRequest }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw VisionError.invalidRequest }
        return result as Data
    }
    static func read(_ url: URL) throws -> Data {
        let data = try readFile(url)
        try validate(data)
        return data
    }
    private static func readFile(_ url: URL) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
        guard descriptor >= 0 else { throw VisionError.invalidRequest }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw VisionError.invalidRequest }
        let data = try file.read(upToCount: VisionRequest.maximumImageBytes + 1) ?? Data()
        return data
    }
}

/// Explicit single-image request. No network action occurs until the user submits.
struct VisionImageView: View {
    @State private var selected: VisionImageSelection.Snapshot?
    @State private var preview: NSImage?
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
                Text(selected?.name ?? "尚未选择图片").lineLimit(1)
            }
            if let preview {
                Image(nsImage: preview).resizable().scaledToFit().frame(maxWidth: 240, maxHeight: 140)
                    .accessibilityLabel("已选择图片的预览")
            }
            Text("支持单帧 PNG 或 JPEG，最大 5 MiB、边长不超过 8192 像素且总计不超过 2400 万像素。不会自动读取屏幕或浏览器。")
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
        guard panel.runModal() == .OK, let url = panel.url else { return }
        selected = nil; preview = nil
        let current = UUID(); generation = current; running = true; result = "正在读取所选图片…"
        requestTask = Task {
            do {
                let snapshot = try await Task.detached { try VisionImageSelection.snapshot(url) }.value
                guard generation == current, !Task.isCancelled else { return }
                guard let image = NSImage(data: snapshot.thumbnail), image.isValid, !image.representations.isEmpty else { throw VisionError.invalidRequest }
                selected = snapshot; preview = image; result = ""
            } catch {
                guard generation == current, !Task.isCancelled else { return }
                result = "无法读取或预览图片，请检查文件格式、大小和像素尺寸。"
            }
            if generation == current { running = false; requestTask = nil }
        }
    }
    private func submit() {
        guard let selected, let url = URL(string: endpoint) else { result = "请检查本机服务地址。"; return }
        let prompt = question
        let selectedModel = model
        let current = UUID(); generation = current; running = true; result = "正在分析…"
        requestTask = Task {
            do {
                let service = try OllamaVisionService(baseURL: url, model: selectedModel)
                try Task.checkCancellation()
                let answer = try await service.describe(VisionRequest(prompt: prompt, image: selected.data))
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
