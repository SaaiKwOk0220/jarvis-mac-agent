import Foundation

@MainActor protocol VoiceBackend: AnyObject {
    var isOnDeviceSupported: Bool { get }
    func requestPermission() async -> Bool
    func start(onText: @escaping (String) -> Void, onFailure: @escaping (String) -> Void, onFinish: @escaping () -> Void) throws
    func finish()
    func stop()
}

@MainActor protocol VoiceSpeaker: AnyObject {
    func speak(_ text: String)
    func stop()
}

@MainActor final class VoiceCoordinator: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var isStarting = false
    @Published private(set) var isFinishing = false
    @Published private(set) var transcript = ""
    @Published private(set) var errorMessage: String?
    private let backend: any VoiceBackend
    private let speaker: (any VoiceSpeaker)?
    private var generation = 0
    private var finishTimeout: Task<Void, Never>?

    init(backend: any VoiceBackend, speaker: (any VoiceSpeaker)? = nil) { self.backend = backend; self.speaker = speaker }

    func start() async {
        guard !isRecording && !isStarting && !isFinishing else { return }
        speaker?.stop()
        isStarting = true
        defer { isStarting = false }
        generation += 1
        let current = generation
        errorMessage = nil
        guard backend.isOnDeviceSupported else { errorMessage = "本机不支持离线中文语音识别。"; return }
        guard await backend.requestPermission() else { if current == generation { errorMessage = "需要麦克风和语音识别权限。" }; return }
        guard current == generation else { return }
        guard backend.isOnDeviceSupported else { errorMessage = "本机不支持离线中文语音识别。"; return }
        do {
            transcript = ""
            try backend.start { [weak self] text in
                guard let self, self.generation == current else { return }
                self.transcript = text
            } onFailure: { [weak self] message in
                guard let self, self.generation == current else { return }
                self.stop()
                self.errorMessage = message
            } onFinish: { [weak self] in
                guard let self, self.generation == current else { return }
                self.stop()
            }
            isRecording = true
        } catch {
            backend.stop()
            errorMessage = "无法启动离线语音识别：\(error.localizedDescription)"
        }
    }

    func speak(_ text: String) {
        guard !isStarting && !isRecording && !isFinishing && !text.isEmpty else { return }
        speaker?.stop()
        speaker?.speak(text)
    }

    func stopSpeaking() { speaker?.stop() }

    func finishRecording() {
        guard isRecording else { return }
        isRecording = false
        isFinishing = true
        let current = generation
        backend.finish()
        guard isFinishing && generation == current else { return }
        finishTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self, self.generation == current else { return }
            self.stop()
            self.errorMessage = "等待最终转写超时，已保留当前文字。"
        }
    }

    func stop() {
        generation += 1
        finishTimeout?.cancel(); finishTimeout = nil
        backend.stop()
        isRecording = false
        isFinishing = false
    }
}
