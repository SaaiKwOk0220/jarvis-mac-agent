import Foundation
import JarvisLLM

/// If creation finishes after cancellation, cancel the created task before
/// returning, using a fresh task so cancellation cannot suppress cleanup.
enum CancellableTaskCreation {
    static func run<T: Sendable>(create: @escaping @Sendable () async throws -> T,
                                 cancel: @escaping @Sendable (T) async -> Void) async throws -> T {
        try Task.checkCancellation()
        let created = try await create()
        if Task.isCancelled {
            await Task.detached { await cancel(created) }.value
            throw CancellationError()
        }
        return created
    }
}

/// Invalidates delayed task callbacks when a run is cancelled or its window closes.
@MainActor final class VoiceRunLifecycle: ObservableObject {
    private var generation = 0
    func begin() -> Int { generation += 1; return generation }
    func invalidate() { generation += 1 }
    func isCurrent(_ token: Int) -> Bool { generation == token }
    func mayRestore(token: Int, visible: Bool, currentDraft: String) -> Bool {
        generation == token && visible && currentDraft.isEmpty
    }
}

/// Holds unsuccessful voice turns separately from the next editable message.
struct VoiceFailedDrafts {
    private(set) var items: [String] = []
    mutating func save(_ text: String) { if !text.isEmpty { items.append(text) } }
    mutating func takeIfDraftEmpty(_ draft: String) -> String? {
        guard draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !items.isEmpty else { return nil }
        return items.removeFirst()
    }
}

/// Tracks a user-started conversation; stale callbacks cannot restart it.
@MainActor final class VoiceConversationSession: ObservableObject {
    @Published private(set) var isActive = false
    private(set) var generation = 0
    private(set) var history: [LLMMessage] = []
    var manualRunToken: Int? { isActive ? generation : nil }

    @discardableResult func begin() -> Int { generation += 1; history = []; isActive = true; return generation }
    func stop() { generation += 1; isActive = false; history = [] }
    func isCurrent(_ token: Int) -> Bool { isActive && generation == token }
    func record(user: String, answer: String, token: Int) {
        guard isCurrent(token), !user.isEmpty, !answer.isEmpty,
              user.count + answer.count <= 12_000 else { return }
        history.append(.init(role: .user, content: user))
        history.append(.init(role: .assistant, content: answer))
        while history.count > 10 || history.reduce(0, { $0 + $1.content.count }) > 12_000 {
            history.removeFirst(2)
        }
    }
    func mayResume(token: Int, visible: Bool, serviceAvailable: Bool, isRunning: Bool, draft: String, voiceBusy: Bool) -> Bool {
        isCurrent(token) && visible && serviceAvailable && !isRunning && !voiceBusy
            && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    func playbackFinished(completed: Bool, token: Int, visible: Bool, serviceAvailable: Bool,
                          isRunning: Bool, draft: String, voiceBusy: Bool, resume: () -> Void) {
        guard isCurrent(token) else { return }
        guard completed else { stop(); return }
        guard mayResume(token: token, visible: visible, serviceAvailable: serviceAvailable,
                        isRunning: isRunning, draft: draft, voiceBusy: voiceBusy) else { return }
        resume()
    }
}

/// A cancelable review window between local transcription and task creation.
@MainActor final class VoiceAutoSubmitGate: ObservableObject {
    @Published private(set) var pendingText: String?
    @Published private(set) var secondsRemaining = 0
    private let tick: Duration
    private var generation = 0
    private var timer: Task<Void, Never>?

    init(tick: Duration = .seconds(1)) { self.tick = tick }

    func schedule(_ text: String, submit: @escaping @MainActor @Sendable (String) -> Void) {
        cancel()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        generation += 1
        let current = generation
        pendingText = text
        secondsRemaining = 3
        let interval = tick
        timer = Task { [weak self] in
            for remaining in stride(from: 2, through: 0, by: -1) {
                do { try await Task.sleep(for: interval) } catch { return }
                guard !Task.isCancelled, let self, self.generation == current else { return }
                self.secondsRemaining = remaining
            }
            guard !Task.isCancelled, let self, self.generation == current,
                  self.pendingText == text else { return }
            self.pendingText = nil
            self.timer = nil
            submit(text)
        }
    }

    func cancel() {
        generation += 1
        timer?.cancel(); timer = nil
        pendingText = nil
        secondsRemaining = 0
    }
}

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
    static func allowsAutomaticSubmission(draft: String, serviceAvailable: Bool) -> Bool {
        serviceAvailable && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
    func speak(_ text: String, onFinish: @escaping @MainActor @Sendable (Bool) -> Void)
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
    private let recordingLimit: Duration?
    private var speakerGeneration = 0
    private var generation = 0
    private var finishTimeout: Task<Void, Never>?
    private var recordingTimeout: Task<Void, Never>?
    private var automaticFinish = false
    private(set) var diagnosticReason: String?
    func setDiagnosticsEnabled(_ enabled: Bool) { (backend as? OnDeviceSpeechBackend)?.setDiagnosticsEnabled(enabled); if !enabled { diagnosticReason = nil } }
    func diagnosticSnapshot() -> VoiceDiagnosticSnapshot? { (backend as? OnDeviceSpeechBackend)?.diagnosticSnapshot() }
    func clearDiagnostics() { (backend as? OnDeviceSpeechBackend)?.clearDiagnostics(); diagnosticReason = nil }
    private var autoSubmit: (@MainActor @Sendable (String) -> Void)?

    init(backend: any VoiceBackend, speaker: (any VoiceSpeaker)? = nil, recordingLimit: Duration? = nil) {
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
        diagnosticReason = nil
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
                self.diagnosticReason = "识别失败"
                self.stop()
                self.errorMessage = message
            } onFinish: { [weak self] finalHasText in
                guard let self, self.generation == current else { return }
                if self.diagnosticReason == nil { self.diagnosticReason = "识别完成" }
                let output = self.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                let submit = self.automaticFinish && finalHasText && !output.isEmpty ? self.autoSubmit : nil
                self.needsConfirmation = !finalHasText && !self.transcript.isEmpty
                self.stop()
                submit?(output)
            } onSilence: { [weak self] in
                guard let self, self.generation == current, self.isRecording else { return }
                self.automaticFinish = true
                self.diagnosticReason = "检测到停顿"
                self.finishRecording()
            }
            isRecording = true
            let limit = recordingLimit ?? .seconds(VoiceEndpointSettings.maxRecordingSeconds())
            recordingTimeout = Task { [weak self] in
                try? await Task.sleep(for: limit)
                guard !Task.isCancelled, let self, self.generation == current, self.isRecording else { return }
                self.automaticFinish = false
                self.diagnosticReason = "录音达到上限"
                self.errorMessage = "未检测到可靠停顿，请检查转写并手动运行。"
                self.finishRecording()
            }
        } catch {
            backend.stop()
            errorMessage = SpeechFailure.safeMessage(error)
        }
    }

    func speak(_ text: String, onFinish: (@MainActor @Sendable (Bool) -> Void)? = nil) {
        guard !isStarting && !isRecording && !isFinishing && !text.isEmpty else { return }
        guard let speaker else { return }
        stopSpeaking()
        speakerGeneration += 1
        let current = speakerGeneration
        isSpeaking = true
        speaker.speak(text) { [weak self] completed in
            guard let self, self.speakerGeneration == current else { return }
            self.speakerGeneration += 1
            self.isSpeaking = false
            onFinish?(completed)
        }
    }

    func previewVoice(conversationActive: Bool, isRunning: Bool) {
        guard !conversationActive && !isRunning && !isSpeaking else { return }
        speak(VoicePlaybackSettings.previewText)
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
            self.diagnosticReason = "等待最终识别超时"
            self.stop()
            self.errorMessage = "等待最终转写超时，已保留当前文字。"
        }
    }

    func stop() {
        if diagnosticReason == nil && (isRecording || isStarting || isFinishing) { diagnosticReason = "手动停止或完成" }
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

/// Tracks provenance when the user clears and replaces an editable message.
struct VoiceInputOrigin {
    var containsVoice: Bool
    var restoredID: String?
    mutating func applyEdit(_ value: String) {
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            containsVoice = false
            restoredID = nil
        }
    }
}
