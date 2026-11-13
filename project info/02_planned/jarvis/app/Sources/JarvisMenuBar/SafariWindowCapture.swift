import Foundation
import ScreenCaptureKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import SwiftUI
import AppKit
import JarvisLLM

/// Window identity uses system identifiers, not its changeable title or geometry.
struct SafariWindowIdentity: Identifiable, Sendable {
    let bundleID: String
    let windowID: UInt32
    let pid: Int32
    let launched: Date
    let title: String
    var id: UInt32 { windowID }
}

enum SafariCaptureSelection {
    static func matches(_ selected: SafariWindowIdentity, in windows: [SafariWindowIdentity]) -> Bool {
        guard selected.bundleID == "com.apple.Safari", selected.windowID != 0, selected.pid > 0 else { return false }
        let candidates = windows.filter { $0.windowID == selected.windowID }
        guard candidates.count == 1, let actual = candidates.first else { return false }
        return actual.bundleID == selected.bundleID && actual.pid == selected.pid && actual.launched == selected.launched
    }
}

enum SafariWindowLabel {
    static func text(at index: Int, window: SafariWindowIdentity) -> String {
        "窗口 \(index + 1)：\(window.title)"
    }
}

enum SafariWindowMessages {
    static let enumerationBusy = "上一次窗口读取尚未结束。请等待系统恢复，或重启 Jarvis 后重试。"
}

struct SafariCaptureState {
    private var generation = UUID()
    private var frame: Data?
    mutating func beginSelection() -> UUID { frame = nil; generation = UUID(); return generation }
    mutating func setPreview(_ data: Data, token: UUID) -> Bool {
        guard generation == token, !data.isEmpty, data.count <= 5 * 1024 * 1024 else { return false }
        frame = data; return true
    }
    func snapshotForSubmission() -> Data? { frame }
    func isCurrent(_ token: UUID) -> Bool { token == generation }
    mutating func cancel() { generation = UUID(); frame = nil }
}

enum SafariWindowCaptureError: Error { case unavailable, invalidSelection, invalidFrame, busy }

final class SafariCaptureWorkGate: @unchecked Sendable {
    static let shared = SafariCaptureWorkGate()
    private let lock = NSLock()
    private var active = false
    func begin() -> Bool { lock.lock(); defer { lock.unlock() }; guard !active else { return false }; active = true; return true }
    func end() { lock.lock(); active = false; lock.unlock() }
}

/// Keeps enumeration single-flight until the underlying OS completion callback.
final class SafariEnumerationGate: @unchecked Sendable {
    static let shared = SafariEnumerationGate()
    private let gate = SafariCaptureWorkGate()

    func run<T: Sendable>(_ start: @Sendable (@escaping @Sendable (Result<T, Error>) -> Void) -> Void) async throws -> T {
        try Task.checkCancellation()
        guard gate.begin() else { throw SafariWindowCaptureError.busy }
        do { try Task.checkCancellation() } catch { gate.end(); throw error }
        let value: T = try await withCheckedThrowingContinuation { continuation in
            let completion = SafariEnumerationCompletion(gate: gate, continuation: continuation)
            start { result in completion.finish(result) }
        }
        try Task.checkCancellation()
        return value
    }
}

private final class SafariEnumerationCompletion<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private let gate: SafariCaptureWorkGate
    init(gate: SafariCaptureWorkGate, continuation: CheckedContinuation<T, Error>) {
        self.gate = gate; self.continuation = continuation
    }
    func finish(_ result: Result<T, Error>) {
        lock.lock(); let current = continuation; continuation = nil; lock.unlock()
        guard let current else { return }
        gate.end()
        current.resume(with: result)
    }
}

/// Injectable boundary: tests never enumerate or capture a real screen.
@MainActor
protocol SafariWindowProviding {
    func windows() async throws -> [SafariWindowIdentity]
    func capture(_ identity: SafariWindowIdentity) async throws -> Data
}

@MainActor
enum SafariWindowCapture {
    /// Rejects a changed target before capture and discards a frame if it changes afterward.
    static func validatedFrame(_ identity: SafariWindowIdentity, provider: any SafariWindowProviding) async throws -> Data {
        guard SafariCaptureWorkGate.shared.begin() else { throw SafariWindowCaptureError.unavailable }
        defer { SafariCaptureWorkGate.shared.end() }
        try Task.checkCancellation()
        guard SafariCaptureSelection.matches(identity, in: try await provider.windows()) else { throw SafariWindowCaptureError.invalidSelection }
        try Task.checkCancellation()
        let data = try await provider.capture(identity)
        try Task.checkCancellation()
        guard SafariCaptureSelection.matches(identity, in: try await provider.windows()) else { throw SafariWindowCaptureError.invalidSelection }
        try Task.checkCancellation()
        guard !data.isEmpty, data.count <= 5 * 1024 * 1024 else { throw SafariWindowCaptureError.invalidFrame }
        return data
    }
}

/// Uses only an explicit, currently visible Safari window and never falls back to the display.
@MainActor
final class SystemSafariWindowProvider: SafariWindowProviding {
    private struct ShareableContent: @unchecked Sendable { let value: SCShareableContent }

    private func availableWindows() async throws -> [(SCWindow, SafariWindowIdentity)] {
        // Preflight never requests authorization. The user enables it in System Settings.
        guard CGPreflightScreenCaptureAccess() else { throw SafariWindowCaptureError.unavailable }
        let boxed: ShareableContent = try await SafariEnumerationGate.shared.run { completion in
            SCShareableContent.getWithCompletionHandler { content, error in
                if let content { completion(.success(ShareableContent(value: content))) }
                else { completion(.failure(error ?? SafariWindowCaptureError.unavailable)) }
            }
        }
        let content = boxed.value
        return content.windows.compactMap { window in
            guard window.isOnScreen, let owner = window.owningApplication,
                  owner.bundleIdentifier == "com.apple.Safari", owner.processID > 0, window.windowID != 0,
                  let process = NSRunningApplication(processIdentifier: owner.processID), !process.isTerminated,
                  process.bundleIdentifier == owner.bundleIdentifier, let launched = process.launchDate else { return nil }
            return (window, SafariWindowIdentity(bundleID: owner.bundleIdentifier, windowID: window.windowID,
                                                 pid: owner.processID, launched: launched, title: window.title ?? "Safari 窗口"))
        }
    }

    func windows() async throws -> [SafariWindowIdentity] { try await availableWindows().map(\.1) }

    func capture(_ identity: SafariWindowIdentity) async throws -> Data {
        let choices = try await availableWindows()
        guard SafariCaptureSelection.matches(identity, in: choices.map(\.1)),
              let window = choices.first(where: { SafariCaptureSelection.matches(identity, in: [$0.1]) })?.0 else {
            throw SafariWindowCaptureError.invalidSelection
        }
        let bounds = window.frame
        guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else { throw SafariWindowCaptureError.invalidFrame }
        let scale = min(1, 1280 / max(bounds.width, bounds.height))
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(bounds.width * scale))
        configuration.height = max(1, Int(bounds.height * scale))
        configuration.showsCursor = false
        configuration.capturesAudio = false
        try Task.checkCancellation()
        let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration)
        try Task.checkCancellation()
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { throw SafariWindowCaptureError.invalidFrame }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), output.length > 0, output.length <= 5 * 1024 * 1024 else { throw SafariWindowCaptureError.invalidFrame }
        return output as Data
    }
}

struct SafariWindowVisionView: View {
    @State private var provider = SystemSafariWindowProvider()
    @State private var state = SafariCaptureState()
    @State private var windows: [SafariWindowIdentity] = []
    @State private var preview: NSImage?
    @State private var endpoint = "http://127.0.0.1:11434"
    @State private var model = "qwen2.5vl:3b"
    @State private var question = "请描述这个 Safari 窗口中的内容。"
    @State private var result = ""
    @State private var busy = false
    @State private var running: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Safari 窗口理解实验").font(.title2.bold())
            Text("先列出并选择 Safari 窗口，截取一帧供预览；只有点击分析才发送。请确认本机服务可信，服务可能将图片转发到其他地方。")
                .font(.callout).foregroundStyle(.secondary)
            Text("需要先在系统设置中允许屏幕录制；取消无法撤回已经发送的数据。")
                .font(.caption).foregroundStyle(.secondary)
            Text("列出窗口会在此处显示 Safari 页面标题，可能包含敏感信息。页面或窗口可能变化；请确认预览，发送时使用的就是这张快照。")
                .font(.caption).foregroundStyle(.secondary)
            Button("列出 Safari 窗口") { listWindows() }.disabled(busy)
            if !windows.isEmpty {
                ScrollView { VStack(alignment: .leading) {
                    ForEach(Array(windows.enumerated()), id: \.element.id) { index, window in
                        Button(SafariWindowLabel.text(at: index, window: window)) { capture(window) }.disabled(busy).lineLimit(1)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 110)
            }
            if let preview {
                Image(nsImage: preview).resizable().scaledToFit().frame(maxWidth: 480, maxHeight: 200).accessibilityLabel("将要发送的 Safari 窗口预览")
            }
            TextField("本机服务地址", text: $endpoint).disabled(busy)
            TextField("视觉模型名称", text: $model).disabled(busy)
            TextField("关于窗口的问题", text: $question, axis: .vertical).lineLimit(2...4).disabled(busy)
            HStack {
                Button("分析这张预览") { submit() }
                    .disabled(busy || state.snapshotForSubmission() == nil || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("取消并清除") { cancel() }
            }
            ScrollView { Text(result.isEmpty ? "结果会显示在这里。" : result).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
        }
        .padding(24)
        .onDisappear { cancel() }
    }

    private func listWindows() {
        cancel()
        let token = state.beginSelection()
        busy = true; result = "正在列出 Safari 窗口…"
        running = Task { @MainActor in
            do {
                let list = try await provider.windows()
                guard !Task.isCancelled, state.isCurrent(token) else { return }
                windows = list; result = list.isEmpty ? "没有找到可见的 Safari 窗口。" : "请选择要截取的窗口。"
            } catch {
                guard !Task.isCancelled, state.isCurrent(token) else { return }
                if case SafariWindowCaptureError.busy = error {
                    result = SafariWindowMessages.enumerationBusy
                } else {
                    result = "无法列出窗口，请检查屏幕录制权限。"
                }
            }
            if state.isCurrent(token) { busy = false; running = nil }
        }
    }

    private func capture(_ window: SafariWindowIdentity) {
        running?.cancel(); preview = nil
        let token = state.beginSelection()
        busy = true; result = "正在截取所选窗口…"
        running = Task { @MainActor in
            do {
                let data = try await SafariWindowCapture.validatedFrame(window, provider: provider)
                guard !Task.isCancelled, state.isCurrent(token) else { return }
                guard let image = NSImage(data: data), image.isValid, !image.representations.isEmpty else { throw SafariWindowCaptureError.invalidFrame }
                guard state.setPreview(data, token: token) else { throw SafariWindowCaptureError.invalidFrame }
                preview = image; result = "请检查预览，再决定是否分析。"
            } catch {
                guard !Task.isCancelled, state.isCurrent(token) else { return }
                if case SafariWindowCaptureError.busy = error {
                    result = SafariWindowMessages.enumerationBusy
                } else {
                    result = "无法截取所选窗口。窗口可能已变化，请重新列出并选择。"
                }
            }
            if state.isCurrent(token) { busy = false; running = nil }
        }
    }

    private func submit() {
        guard let frame = state.snapshotForSubmission(), let url = URL(string: endpoint) else { result = "请检查本机服务地址。"; return }
        let prompt = question, selectedModel = model
        busy = true; result = "正在分析…"
        running = Task { @MainActor in
            do {
                let service = try OllamaVisionService(baseURL: url, model: selectedModel)
                try Task.checkCancellation()
                let answer = try await service.describe(VisionRequest(prompt: prompt, image: frame))
                guard !Task.isCancelled else { return }
                result = answer
            } catch {
                guard !Task.isCancelled else { return }
                result = (error as? VisionError)?.localizedDescription ?? "无法分析窗口预览。"
            }
            if !Task.isCancelled { busy = false; running = nil }
        }
    }

    private func cancel() {
        running?.cancel(); running = nil
        state.cancel(); windows = []; preview = nil; busy = false; result = ""
    }
}
