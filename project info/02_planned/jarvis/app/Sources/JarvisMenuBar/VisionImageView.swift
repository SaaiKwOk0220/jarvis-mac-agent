import SwiftUI
import AppKit
import Darwin
import JarvisLLM
import ImageIO
import UniformTypeIdentifiers
import zlib

private final class VisionSnapshotGate: @unchecked Sendable {
    private let lock = NSLock()
    private var busy = false
    func begin() -> Bool { lock.lock(); defer { lock.unlock() }; guard !busy else { return false }; busy = true; return true }
    func end() { lock.lock(); defer { lock.unlock() }; busy = false }
}

/// Reads only a user-selected regular PNG; it never captures a screen.
enum VisionImageSelection {
    private static let gate = VisionSnapshotGate()
    struct Snapshot: Sendable {
        let name: String
        let data: Data
        let thumbnail: Data
    }
    static func withExclusiveSnapshot<T>(_ work: () throws -> T) throws -> T {
        guard gate.begin() else { throw VisionError.busy }
        defer { gate.end() }
        return try work()
    }
    static func snapshot(_ url: URL) throws -> Snapshot {
        try withExclusiveSnapshot {
            let image = try prepare(readFile(url))
            return Snapshot(name: url.lastPathComponent, data: image.safe, thumbnail: image.thumbnail)
        }
    }
    static func validate(_ data: Data) throws {
        _ = try prepare(data)
    }
    private static func prepare(_ data: Data) throws -> (safe: Data, thumbnail: Data) {
        let png = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
        guard data.count <= VisionRequest.maximumImageBytes,
              data.starts(with: png) else { throw VisionError.invalidRequest }
        let safe = try sanitizePNGChunks(data)
        guard let source = CGImageSourceCreateWithData(safe as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
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
        return (safe, result as Data)
    }
    /// Preserve only chunks needed for pixels/transparency; never decompress metadata.
    private static func sanitizePNGChunks(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        var safe = Data(bytes.prefix(8))
        var offset = 8
        var sawHeader = false, sawData = false, endedData = false, sawPalette = false
        var compressed = Data()
        var rowLength = 0, expectedBytes = 0, colorType: UInt8 = 0, paletteEntries = 0
        var sawTransparency = false
        func integer(_ position: Int) -> UInt32 {
            (UInt32(bytes[position]) << 24) | (UInt32(bytes[position + 1]) << 16) |
                (UInt32(bytes[position + 2]) << 8) | UInt32(bytes[position + 3])
        }
        while offset <= bytes.count - 12 {
            let length = Int(integer(offset))
            guard length <= bytes.count - offset - 12 else { throw VisionError.invalidRequest }
            let typeStart = offset + 4, bodyStart = offset + 8, crcOffset = bodyStart + length
            let type = Array(bytes[typeStart..<bodyStart])
            guard type.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) }), type[2] & 0x20 == 0 else { throw VisionError.invalidRequest }
            var crc: UInt32 = 0xffffffff
            for byte in bytes[typeStart..<crcOffset] {
                crc ^= UInt32(byte)
                for _ in 0..<8 { crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xedb88320 : crc >> 1 }
            }
            guard crc ^ 0xffffffff == integer(crcOffset) else { throw VisionError.invalidRequest }
            let name = String(decoding: type, as: UTF8.self)
            guard !["acTL", "fcTL", "fdAT"].contains(name) else { throw VisionError.invalidRequest }
            guard type[0] & 0x20 != 0 || ["IHDR", "PLTE", "IDAT", "IEND"].contains(name) else { throw VisionError.invalidRequest }
            if !sawHeader {
                guard name == "IHDR", length == 13 else { throw VisionError.invalidRequest }
                let width = Int(integer(bodyStart)), height = Int(integer(bodyStart + 4))
                let bitDepth = bytes[bodyStart + 8], color = bytes[bodyStart + 9]
                colorType = color
                let channels: Int
                switch color { case 0, 3: channels = 1; case 2: channels = 3; case 4: channels = 2; case 6: channels = 4; default: throw VisionError.invalidRequest }
                guard width > 0, height > 0, width <= 8192, height <= 8192, width * height <= 24_000_000,
                      bitDepth == 8, bytes[bodyStart + 10] == 0, bytes[bodyStart + 11] == 0,
                      bytes[bodyStart + 12] == 0 else { throw VisionError.invalidRequest }
                rowLength = width * channels + 1
                expectedBytes = height * rowLength
                sawHeader = true
            } else if name == "IHDR" { throw VisionError.invalidRequest }
            if name == "PLTE" {
                guard !sawPalette, !sawData, !sawTransparency, colorType != 0, colorType != 4,
                      length > 0, length <= 768, length % 3 == 0 else { throw VisionError.invalidRequest }
                sawPalette = true
                paletteEntries = length / 3
            }
            if name == "tRNS" {
                guard !sawData, !sawTransparency,
                      (colorType == 0 && length == 2) || (colorType == 2 && length == 6) ||
                      (colorType == 3 && sawPalette && length > 0 && length <= paletteEntries) else { throw VisionError.invalidRequest }
                sawTransparency = true
            }
            if name == "IDAT" {
                guard !endedData, colorType != 3 || sawPalette else { throw VisionError.invalidRequest }
                sawData = true
                compressed.append(contentsOf: bytes[bodyStart..<crcOffset])
            } else if sawData { endedData = true }
            let chunkStart = offset
            offset = crcOffset + 4
            if ["IHDR", "PLTE", "tRNS", "IDAT", "IEND"].contains(name) { safe.append(contentsOf: bytes[chunkStart..<offset]) }
            if name == "IEND" {
                guard length == 0, sawData, offset == bytes.count else { throw VisionError.invalidRequest }
                try validateInflate(compressed, rowLength: rowLength, expectedBytes: expectedBytes,
                                    indexedPaletteEntries: colorType == 3 ? paletteEntries : nil)
                return safe
            }
        }
        throw VisionError.invalidRequest
    }
    /// Decode through zlib into a bounded scratch buffer; require the whole stream,
    /// checksum, exact scanline length, and valid per-row filter bytes.
    private static func validateInflate(_ compressed: Data, rowLength: Int, expectedBytes: Int,
                                        indexedPaletteEntries: Int?) throws {
        var stream = z_stream()
        guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw VisionError.invalidRequest }
        defer { inflateEnd(&stream) }
        var output = [UInt8](repeating: 0, count: 65_536)
        try compressed.withUnsafeBytes { input in
            guard let base = input.bindMemory(to: UInt8.self).baseAddress else { throw VisionError.invalidRequest }
            stream.next_in = UnsafeMutablePointer(mutating: base)
            stream.avail_in = uInt(input.count)
            var total = 0
            var previous = [UInt8](repeating: 0, count: indexedPaletteEntries == nil ? 0 : rowLength - 1)
            var current = previous
            var rowFilter: UInt8 = 0
            while true {
                let beforeInput = stream.avail_in
                let status: Int32 = output.withUnsafeMutableBufferPointer { buffer in
                    stream.next_out = buffer.baseAddress
                    stream.avail_out = uInt(buffer.count)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                let produced = output.count - Int(stream.avail_out)
                guard produced <= expectedBytes - total else { throw VisionError.invalidRequest }
                var filter = (rowLength - total % rowLength) % rowLength
                while filter < produced {
                    guard output[filter] <= 4 else { throw VisionError.invalidRequest }
                    filter += rowLength
                }
                if let paletteEntries = indexedPaletteEntries {
                    for index in 0..<produced {
                        let column = (total + index) % rowLength
                        if column == 0 { rowFilter = output[index]; continue }
                        let pixel = column - 1
                        let left = pixel == 0 ? 0 : Int(current[pixel - 1])
                        let up = Int(previous[pixel])
                        let upperLeft = pixel == 0 ? 0 : Int(previous[pixel - 1])
                        let predictor: Int
                        switch rowFilter {
                        case 0: predictor = 0
                        case 1: predictor = left
                        case 2: predictor = up
                        case 3: predictor = (left + up) / 2
                        case 4:
                            let p = left + up - upperLeft
                            let a = abs(p - left), b = abs(p - up), c = abs(p - upperLeft)
                            predictor = a <= b && a <= c ? left : (b <= c ? up : upperLeft)
                        default: throw VisionError.invalidRequest
                        }
                        let value = UInt8(truncatingIfNeeded: Int(output[index]) + predictor)
                        guard Int(value) < paletteEntries else { throw VisionError.invalidRequest }
                        current[pixel] = value
                        if column == rowLength - 1 { swap(&previous, &current) }
                    }
                }
                total += produced
                if status == Z_STREAM_END {
                    guard total == expectedBytes, stream.avail_in == 0 else { throw VisionError.invalidRequest }
                    return
                }
                guard status == Z_OK, produced > 0 || stream.avail_in < beforeInput else { throw VisionError.invalidRequest }
            }
        }
    }
    static func read(_ url: URL) throws -> Data {
        try prepare(readFile(url)).safe
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
            Text("支持非交错 8 位单帧 PNG，最大 5 MiB、边长不超过 8192 像素且总计不超过 2400 万像素。会移除元数据与色彩配置，颜色可能改变；预览与发送使用同一图片。不会自动读取屏幕或浏览器。")
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
        panel.allowedContentTypes = [.png]
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
                if let error = error as? VisionError, case .busy = error {
                    result = "上一张图片仍在处理，请稍后重试。"
                } else {
                    result = "无法读取或预览图片，请检查文件格式、大小和像素尺寸。"
                }
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
