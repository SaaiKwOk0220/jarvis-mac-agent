import Foundation
@preconcurrency import ScreenCaptureKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import SwiftUI
import AppKit
import JarvisLLM

/// Validates the system picker result without relying on window title or position.
enum SafariCaptureSelection {
    struct Window { let bundleID: String; let windowID: UInt32; let pid: Int32 }
    static func isAllowed(styleIsWindow: Bool, windows: [Window]) -> Bool {
        styleIsWindow && windows.count == 1 && windows[0].bundleID == "com.apple.Safari" && windows[0].windowID != 0 && windows[0].pid > 0
    }
}

/// Keeps one bounded frame and invalidates late capture completions after cancellation.
struct SafariCaptureState {
    private var generation = UUID()
    private var frame: Data?
    mutating func beginSelection() -> UUID { frame = nil; generation = UUID(); return generation }
    mutating func setPreview(_ data: Data, token: UUID) -> Bool {
        guard generation == token, !data.isEmpty, data.count <= 5 * 1024 * 1024 else { return false }
        frame = data
        return true
    }
    func snapshotForSubmission() -> Data? { frame }
    func isCurrent(_ token: UUID) -> Bool { token == generation }
    mutating func cancel() { generation = UUID(); frame = nil }
}

enum SafariWindowCaptureError: Error { case unavailable, invalidSelection, invalidFrame }

final class SafariCaptureWorkGate: @unchecked Sendable {
    static let shared = SafariCaptureWorkGate()
    private let lock = NSLock()
    private var active = false
    func begin() -> Bool { lock.lock(); defer { lock.unlock() }; guard !active else { return false }; active = true; return true }
    func end() { lock.lock(); active = false; lock.unlock() }
}

/// Captures only the exact system-selected window, without writing it to disk.
@available(macOS 15.2, *)
enum SafariWindowCapture {
    static func frame(filter: SCContentFilter) async throws -> Data {
        guard SafariCaptureWorkGate.shared.begin() else { throw SafariWindowCaptureError.unavailable }
        defer { SafariCaptureWorkGate.shared.end() }
        try Task.checkCancellation()
        let windows = filter.includedWindows
        let descriptors = windows.map { SafariCaptureSelection.Window(bundleID: $0.owningApplication?.bundleIdentifier ?? "", windowID: $0.windowID, pid: $0.owningApplication?.processID ?? 0) }
        guard SafariCaptureSelection.isAllowed(styleIsWindow: filter.style == .window, windows: descriptors), let window = windows.first else {
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
        let exactWindowFilter = SCContentFilter(desktopIndependentWindow: window)
        let image = try await SCScreenshotManager.captureImage(contentFilter: exactWindowFilter, configuration: configuration)
        try Task.checkCancellation()
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { throw SafariWindowCaptureError.invalidFrame }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), output.length > 0, output.length <= 5 * 1024 * 1024 else { throw SafariWindowCaptureError.invalidFrame }
        return output as Data
    }
}

/// Presents the macOS single-window picker only after an explicit user action.
@available(macOS 15.2, *)
@MainActor
final class SafariWindowPicker: NSObject, ObservableObject, SCContentSharingPickerObserver {
    private struct FilterBox: @unchecked Sendable { let value: SCContentFilter }
    private var completion: ((SCContentFilter?) -> Void)?
    private let picker = SCContentSharingPicker.shared

    func present(completion: @escaping (SCContentFilter?) -> Void) {
        cancel()
        self.completion = completion
        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = .singleWindow
        configuration.allowsChangingSelectedContent = false
        picker.defaultConfiguration = configuration
        picker.add(self)
        picker.isActive = true
        picker.present()
    }

    func cancel() {
        completion = nil
        picker.remove(self)
        picker.isActive = false
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        guard stream == nil else { return }
        Task { @MainActor [weak self] in self?.finish(nil) }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        guard stream == nil else { return }
        let box = FilterBox(value: filter)
        Task { @MainActor [weak self] in self?.finish(box.value) }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        Task { @MainActor [weak self] in self?.finish(nil) }
    }

    private func finish(_ filter: SCContentFilter?) {
        guard let callback = completion else { return }
        cancel()
        callback(filter)
    }
}

@available(macOS 15.2, *)
struct SafariWindowVisionView: View {
    @StateObject private var picker = SafariWindowPicker()
    @State private var state = SafariCaptureState()
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
            Text("选择 Safari 窗口后会截取一帧供预览；只有点击分析才发送。请确认本机服务可信，服务可能将图片转发到其他地方。")
                .font(.callout).foregroundStyle(.secondary)
            Button("选择 Safari 窗口…") { selectWindow() }.disabled(busy)
            if let preview {
                Image(nsImage: preview).resizable().scaledToFit().frame(maxWidth: 480, maxHeight: 240).accessibilityLabel("将要发送的 Safari 窗口预览")
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

    private func selectWindow() {
        cancel()
        let token = state.beginSelection()
        busy = true; result = "请选择一个 Safari 窗口。"
        picker.present { filter in
            guard state.isCurrent(token) else { return }
            guard let filter else { busy = false; result = "未选择窗口。"; return }
            result = "正在截取所选窗口…"
            running = Task { @MainActor in
                do {
                    let data = try await SafariWindowCapture.frame(filter: filter)
                    guard !Task.isCancelled else { return }
                    guard let image = NSImage(data: data), image.isValid, !image.representations.isEmpty else { throw SafariWindowCaptureError.invalidFrame }
                    guard state.setPreview(data, token: token) else { return }
                    preview = image; result = "请检查预览，再决定是否分析。"
                } catch {
                    guard !Task.isCancelled else { return }
                    result = "无法截取所选窗口。请选择 Safari 窗口并检查屏幕录制权限。"
                }
                if !Task.isCancelled { busy = false; running = nil }
            }
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
        picker.cancel(); running?.cancel(); running = nil
        state.cancel(); preview = nil; busy = false; result = ""
    }
}
