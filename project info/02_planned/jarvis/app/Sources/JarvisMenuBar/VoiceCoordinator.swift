import Foundation

/// Preserves the editable draft while a new recording produces partial text.
struct VoiceDraftPrefix {
    private let draft: String
    init(draft: String) { self.draft = draft }
    var originalDraft: String { draft }
    func render(transcript: String) -> String? {
        guard !transcript.isEmpty else { return nil }
        guard !draft.isEmpty else { return transcript }
        let separator = draft.last?.isWhitespace == true ? "" : " "
        return draft + separator + transcript
    }
    static func canRun(draft: String, serviceAvailable: Bool, isRunning: Bool, voiceBusy: Bool) -> Bool {
        serviceAvailable && !isRunning && !voiceBusy && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    static func idleStatus(draft: String, serviceAvailable: Bool, isRunning: Bool) -> String {
        if isRunning { return "正在创建任务…" }
        if !serviceAvailable { return "Jarvis 服务不可用，无法运行任务。" }
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "请输入或录入任务内容。" }
        return "Ready."
    }
}

@MainActor protocol VoiceBackend: AnyObject {
    var isOnDeviceSupported: Bool { get }
    func requestSpeechPermission() async -> Bool
    func requestMicrophonePermission() async -> Bool
    func start(onText: @escaping @MainActor @Sendable (String) -> Void, onFailure: @escaping @MainActor @Sendable (String) -> Void, onFinish: @escaping @MainActor @Sendable (Bool) -> Void, onSilence: @escaping @MainActor @Sendable () -> Void) throws
    func finish()
    func stop()
}

@MainActor protocol VoiceSpeaker: AnyObject {
    func speak(_ text: String, onFinish: @escaping @MainActor @Sendable () -> Void)
    func stop()
}

@MainActor final class VoiceCoordinator: ObservableObject {
    @Published private(set) var isSpeaking = false
    @Published private(set) var isRecording = false
    @Published private(set) var isStarting = false
    @Published private(set) var isFinishing = false
    @Published private(set) var transcript = ""
    @Published private(set) var errorMessage: String?
    @Published private(set) var needsConfirmation = false
    private let backend: any VoiceBackend
    private let speaker: (any VoiceSpeaker)?
    private let recordingLimit: Duration
    private var speakerGeneration = 0
    private var generation = 0
    private var finishTimeout: Task<Void, Never>?
    private var recordingTimeout: Task<Void, Never>?
    private var automaticFinish = false
    private var autoSubmit: (@MainActor @Sendable (String) -> Void)?

    init(backend: any VoiceBackend, speaker: (any VoiceSpeaker)? = nil, recordingLimit: Duration = .seconds(30)) {
        self.backend = backend; self.speaker = speaker; self.recordingLimit = recordingLimit
    }

    func start(onTranscript: (@MainActor @Sendable (String) -> Void)? = nil,
               autoSubmit: (@MainActor @Sendable (String) -> Void)? = nil) async {
        guard !isRecording && !isStarting && !isFinishing && !needsConfirmation else { return }
        stopSpeaking()
        isStarting = true
        defer { isStarting = false }
        generation += 1
        let current = generation
        self.autoSubmit = autoSubmit
        automaticFinish = false
        errorMessage = nil
        guard backend.isOnDeviceSupported else { errorMessage = "本机不支持离线中文语音识别。"; return }
        guard await backend.requestSpeechPermission() else { if current == generation { errorMessage = "需要麦克风和语音识别权限。" }; return }
        guard current == generation else { return }
        guard await backend.requestMicrophonePermission() else { if current == generation { errorMessage = "需要麦克风和语音识别权限。" }; return }
        guard current == generation else { return }
        guard backend.isOnDeviceSupported else { errorMessage = "本机不支持离线中文语音识别。"; return }
        do {
            transcript = ""
            try backend.start { [weak self] text in
                guard let self, self.generation == current else { return }
                // Some recognizers may produce an empty final hypothesis after
                // a useful partial. Do not erase the user's only transcript.
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                self.transcript = text
                onTranscript?(text)
            } onFailure: { [weak self] message in
                guard let self, self.generation == current else { return }
                self.needsConfirmation = !self.transcript.isEmpty
                self.stop()
                self.errorMessage = message
            } onFinish: { [weak self] finalHasText in
                guard let self, self.generation == current else { return }
                let output = self.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                let submit = self.automaticFinish && finalHasText && !output.isEmpty ? self.autoSubmit : nil
                self.needsConfirmation = !finalHasText && !self.transcript.isEmpty
                self.stop()
                submit?(output)
            } onSilence: { [weak self] in
                guard let self, self.generation == current, self.isRecording else { return }
                self.automaticFinish = true
                self.finishRecording()
            }
            isRecording = true
            let limit = recordingLimit
            recordingTimeout = Task { [weak self] in
                try? await Task.sleep(for: limit)
                guard !Task.isCancelled, let self, self.generation == current, self.isRecording else { return }
                self.automaticFinish = false
                self.errorMessage = "未检测到可靠停顿，请检查转写并手动运行。"
                self.finishRecording()
            }
        } catch {
            backend.stop()
            errorMessage = "无法启动离线语音识别：\(error.localizedDescription)"
        }
    }

    func speak(_ text: String) {
        guard !isStarting && !isRecording && !isFinishing && !text.isEmpty else { return }
        guard let speaker else { return }
        stopSpeaking()
        speakerGeneration += 1
        let current = speakerGeneration
        isSpeaking = true
        speaker.speak(text) { [weak self] in
            guard let self, self.speakerGeneration == current else { return }
            self.isSpeaking = false
        }
    }

    func stopSpeaking() { speakerGeneration += 1; speaker?.stop(); isSpeaking = false }

    func confirmTranscript() { needsConfirmation = false }

    func discardTranscript() { needsConfirmation = false; transcript = "" }

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
            self.needsConfirmation = !self.transcript.isEmpty
            self.stop()
            self.errorMessage = "等待最终转写超时，已保留当前文字。"
        }
    }

    func stop() {
        generation += 1
        recordingTimeout?.cancel(); recordingTimeout = nil
        automaticFinish = false
        autoSubmit = nil
        finishTimeout?.cancel(); finishTimeout = nil
        backend.stop()
        isRecording = false
        isFinishing = false
    }
}
