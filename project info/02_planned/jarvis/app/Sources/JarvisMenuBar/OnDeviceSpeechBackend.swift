@preconcurrency import AVFoundation
@preconcurrency import Speech
import Foundation

/// Framework callbacks may arrive on arbitrary queues; no callback inherits
/// the caller's actor. Only parsed, Sendable values cross to the main actor.
enum SpeechCallbackBridge {
    nonisolated static func authorization(_ register: @Sendable (@escaping @Sendable (Bool) -> Void) -> Void) async -> Bool {
        await withCheckedContinuation { continuation in
            register { @Sendable allowed in continuation.resume(returning: allowed) }
        }
    }

    nonisolated static func requestSpeechAuthorization() async -> Bool {
        await authorization { callback in
            SFSpeechRecognizer.requestAuthorization { @Sendable status in callback(status == .authorized) }
        }
    }

    nonisolated static func tap(gate: AudioRequestGate) -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        return { @Sendable buffer, _ in gate.append(buffer) }
    }

    nonisolated static func recognition(onText: @escaping @MainActor @Sendable (String) -> Void,
                                        onFailure: @escaping @MainActor @Sendable (String) -> Void,
                                        onFinish: @escaping @MainActor @Sendable () -> Void) -> @Sendable (SFSpeechRecognitionResult?, Error?) -> Void {
        let events = RecognitionEvents(onText: onText, onFailure: onFailure, onFinish: onFinish)
        return { @Sendable result, error in
            events.submit(text: result?.bestTranscription.formattedString,
                          failed: error != nil, finished: result?.isFinal == true)
        }
    }
}

/// Serializes submissions and drops callbacks after a terminal event.
final class RecognitionEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var terminal = false
    private let onText: @MainActor @Sendable (String) -> Void
    private let onFailure: @MainActor @Sendable (String) -> Void
    private let onFinish: @MainActor @Sendable () -> Void
    init(onText: @escaping @MainActor @Sendable (String) -> Void,
         onFailure: @escaping @MainActor @Sendable (String) -> Void,
         onFinish: @escaping @MainActor @Sendable () -> Void) {
        self.onText = onText; self.onFailure = onFailure; self.onFinish = onFinish
    }
    func submit(text: String?, failed: Bool, finished: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard !terminal else { return }
        if failed || finished { terminal = true }
        DispatchQueue.main.async { [onText, onFailure, onFinish] in
            if let text { onText(text) }
            if failed { onFailure("离线语音识别已停止，请重试。") }
            else if finished { onFinish() }
        }
    }
}

/// Owns the non-Sendable Speech request and serializes append/endAudio.
final class AudioRequestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var ended = false
    private let request: SFSpeechAudioBufferRecognitionRequest
    init(_ request: SFSpeechAudioBufferRecognitionRequest) { self.request = request }
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard !ended else { return }
        request.append(buffer)
    }
    func finish() {
        lock.lock(); defer { lock.unlock() }
        guard !ended else { return }
        ended = true
        request.endAudio()
    }

}

/// Speech recognition always requests Apple's on-device path; no network fallback.
@MainActor final class OnDeviceSpeechBackend: VoiceBackend {
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private let engine = AVAudioEngine()
    private var audioGate: AudioRequestGate?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var hasTap = false

    var isOnDeviceSupported: Bool { recognizer?.isAvailable == true && recognizer?.supportsOnDeviceRecognition == true }

    func requestSpeechPermission() async -> Bool { await SpeechCallbackBridge.requestSpeechAuthorization() }
    func requestMicrophonePermission() async -> Bool { await AVCaptureDevice.requestAccess(for: .audio) }

    func start(onText: @escaping @MainActor @Sendable (String) -> Void, onFailure: @escaping @MainActor @Sendable (String) -> Void, onFinish: @escaping @MainActor @Sendable () -> Void) throws {
        guard let recognizer, isOnDeviceSupported else { throw SpeechError.unavailable }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        let gate = AudioRequestGate(request)
        self.audioGate = gate
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw SpeechError.unavailable }
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: SpeechCallbackBridge.tap(gate: gate))
        hasTap = true
        recognitionTask = recognizer.recognitionTask(with: request, resultHandler: SpeechCallbackBridge.recognition(onText: onText, onFailure: onFailure, onFinish: onFinish))
        engine.prepare()
        try engine.start()
    }

    func finish() {
        engine.stop()
        if hasTap { engine.inputNode.removeTap(onBus: 0); hasTap = false }
        audioGate?.finish()
    }

    func stop() {
        finish()
        recognitionTask?.cancel()
        audioGate = nil
        recognitionTask = nil
    }

    private enum SpeechError: LocalizedError {
        case unavailable
        var errorDescription: String? { "离线语音识别或麦克风不可用。" }
    }
}

@MainActor final class SystemVoiceSpeaker: VoiceSpeaker {
    private let synthesizer = AVSpeechSynthesizer()
    func speak(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        synthesizer.speak(utterance)
    }
    func stop() { synthesizer.stopSpeaking(at: .immediate) }
}
