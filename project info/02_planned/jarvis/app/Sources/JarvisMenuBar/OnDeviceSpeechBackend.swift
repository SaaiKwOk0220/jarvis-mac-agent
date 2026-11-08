@preconcurrency import AVFoundation
@preconcurrency import Speech
import Foundation

/// Speech recognition always requests Apple's on-device path; no network fallback.
@MainActor final class OnDeviceSpeechBackend: VoiceBackend {
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var hasTap = false

    var isOnDeviceSupported: Bool { recognizer?.isAvailable == true && recognizer?.supportsOnDeviceRecognition == true }

    func requestPermission() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard speech == .authorized else { return false }
        return await AVCaptureDevice.requestAccess(for: .audio)
    }

    func start(onText: @escaping (String) -> Void, onFailure: @escaping (String) -> Void, onFinish: @escaping () -> Void) throws {
        guard let recognizer, isOnDeviceSupported else { throw SpeechError.unavailable }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        self.request = request
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw SpeechError.unavailable }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
        hasTap = true
        recognitionTask = recognizer.recognitionTask(with: request) { result, error in
            let text = result?.bestTranscription.formattedString
            let failed = error != nil
            let finished = result?.isFinal == true
            Task { @MainActor in
                if let text { onText(text) }
                if failed { onFailure("离线语音识别已停止，请重试。") }
                else if finished { onFinish() }
            }
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.stop()
        if hasTap { engine.inputNode.removeTap(onBus: 0); hasTap = false }
        request?.endAudio()
        recognitionTask?.cancel()
        request = nil
        recognitionTask = nil
    }

    private enum SpeechError: LocalizedError {
        case unavailable
        var errorDescription: String? { "离线语音识别或麦克风不可用。" }
    }
}
