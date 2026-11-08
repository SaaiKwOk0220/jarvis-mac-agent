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

    nonisolated static func tap(request: SFSpeechAudioBufferRecognitionRequest) -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        let box = RequestBox(request)
        return { @Sendable buffer, _ in box.value.append(buffer) }
    }

    nonisolated static func recognition(onText: @escaping @MainActor @Sendable (String) -> Void,
                                        onFailure: @escaping @MainActor @Sendable (String) -> Void,
                                        onFinish: @escaping @MainActor @Sendable () -> Void) -> @Sendable (SFSpeechRecognitionResult?, Error?) -> Void {
        return { @Sendable result, error in
            let text = result?.bestTranscription.formattedString
            let failed = error != nil
            let finished = result?.isFinal == true
            Task { @MainActor in
                if let text { onText(text) }
                if failed { onFailure("离线语音识别已停止，请重试。") }
                else if finished { onFinish() }
            }
        }
    }

    private final class RequestBox: @unchecked Sendable {
        let value: SFSpeechAudioBufferRecognitionRequest
        init(_ value: SFSpeechAudioBufferRecognitionRequest) { self.value = value }
    }
}

/// Speech recognition always requests Apple's on-device path; no network fallback.
@MainActor final class OnDeviceSpeechBackend: VoiceBackend {
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var hasTap = false

    var isOnDeviceSupported: Bool { recognizer?.isAvailable == true && recognizer?.supportsOnDeviceRecognition == true }

    func requestPermission() async -> Bool {
        guard await SpeechCallbackBridge.requestSpeechAuthorization() else { return false }
        return await AVCaptureDevice.requestAccess(for: .audio)
    }

    func start(onText: @escaping @MainActor @Sendable (String) -> Void, onFailure: @escaping @MainActor @Sendable (String) -> Void, onFinish: @escaping @MainActor @Sendable () -> Void) throws {
        guard let recognizer, isOnDeviceSupported else { throw SpeechError.unavailable }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        self.request = request
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw SpeechError.unavailable }
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: SpeechCallbackBridge.tap(request: request))
        hasTap = true
        recognitionTask = recognizer.recognitionTask(with: request, resultHandler: SpeechCallbackBridge.recognition(onText: onText, onFailure: onFailure, onFinish: onFinish))
        engine.prepare()
        try engine.start()
    }

    func finish() {
        engine.stop()
        if hasTap { engine.inputNode.removeTap(onBus: 0); hasTap = false }
        request?.endAudio()
    }

    func stop() {
        finish()
        recognitionTask?.cancel()
        request = nil
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
