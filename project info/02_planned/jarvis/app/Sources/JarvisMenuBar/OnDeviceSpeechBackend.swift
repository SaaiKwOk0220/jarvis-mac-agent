@preconcurrency import AVFoundation
@preconcurrency import Speech
import Foundation

/// Local-only endpoint preferences; invalid persisted values fail safely.
enum VoiceEndpointSettings {
    static let pauseKey = "jarvis.voice.pauseSeconds"
    static let maxRecordingKey = "jarvis.voice.maxRecordingSeconds"
    static let pauseRange: ClosedRange<Double> = 2...8
    static let maximumRange: ClosedRange<Double> = 30...180
    static let defaultPause = 3.5
    static let defaultMaximum = 90.0
    static func safePause(_ value: Double) -> Double { value.isFinite ? min(pauseRange.upperBound, max(pauseRange.lowerBound, value)) : defaultPause }
    static func safeMaximum(_ value: Double) -> Double { value.isFinite ? min(maximumRange.upperBound, max(maximumRange.lowerBound, value)) : defaultMaximum }
    static func pauseSeconds(_ defaults: UserDefaults = .standard) -> Double {
        safePause((defaults.object(forKey: pauseKey) as? NSNumber)?.doubleValue ?? defaultPause)
    }
    static func maxRecordingSeconds(_ defaults: UserDefaults = .standard) -> Double {
        safeMaximum((defaults.object(forKey: maxRecordingKey) as? NSNumber)?.doubleValue ?? defaultMaximum)
    }
}

/// Never include userInfo or unrecognized domain text in UI diagnostics.
enum SpeechFailure {
    nonisolated static func safeMessage(_ error: Error) -> String {
        let nsError = error as NSError
        let allowed = ["kAFAssistantErrorDomain", "kLSRErrorDomain", "SFSpeechErrorDomain", "AVFoundationErrorDomain", "NSURLErrorDomain"]
        let domain = allowed.contains(nsError.domain) ? nsError.domain : "其他系统域"
        return "离线语音识别中断（\(domain)，代码 \(nsError.code)）。请检查语音识别和麦克风权限及本机中文语言资源后重试；已有转写请先确认。"
    }
}

@MainActor enum VoicePermissionPolicy {
    enum State { case granted, undetermined, denied }
    static func resolve(_ state: State, request: @MainActor () async -> Bool) async -> Bool {
        switch state {
        case .granted: return true
        case .denied: return false
        case .undetermined: return await request()
        }
    }
}

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

    nonisolated static func tap(gate: AudioRequestGate, monitor: AudioPauseMonitor? = nil) -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        return { @Sendable buffer, _ in
            if gate.append(buffer) { monitor?.observe(buffer) }
        }
    }

    nonisolated static func recognition(onText: @escaping @MainActor @Sendable (String) -> Void,
                                        onFailure: @escaping @MainActor @Sendable (String) -> Void,
                                        onFinish: @escaping @MainActor @Sendable (Bool) -> Void) -> @Sendable (SFSpeechRecognitionResult?, Error?) -> Void {
        let events = RecognitionEvents(onText: onText, onFailure: onFailure, onFinish: onFinish)
        return { @Sendable result, error in
            events.submit(text: result?.bestTranscription.formattedString,
                          failed: error != nil, finished: result?.isFinal == true,
                          failureMessage: error.map(SpeechFailure.safeMessage))
        }
    }
}

/// Serializes submissions and drops callbacks after a terminal event.
final class RecognitionEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var terminal = false
    private let onText: @MainActor @Sendable (String) -> Void
    private let onFailure: @MainActor @Sendable (String) -> Void
    private let onFinish: @MainActor @Sendable (Bool) -> Void
    init(onText: @escaping @MainActor @Sendable (String) -> Void,
         onFailure: @escaping @MainActor @Sendable (String) -> Void,
         onFinish: @escaping @MainActor @Sendable (Bool) -> Void) {
        self.onText = onText; self.onFailure = onFailure; self.onFinish = onFinish
    }
    func submit(text: String?, failed: Bool, finished: Bool, failureMessage: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        guard !terminal else { return }
        if failed || finished { terminal = true }
        DispatchQueue.main.async { [onText, onFailure, onFinish] in
            if let text { onText(text) }
            if failed { onFailure(failureMessage ?? "离线语音识别中断，请检查系统权限和本机中文语言资源后重试。") }
            else if finished { onFinish(!(text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)) }
        }
    }
}

/// Owns the non-Sendable Speech request and serializes append/endAudio.
final class AudioRequestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var ended = false
    private let appendBuffer: @Sendable (AVAudioPCMBuffer) -> Void
    private let endAudio: @Sendable () -> Void

    private final class RequestBox: @unchecked Sendable {
        let request: SFSpeechAudioBufferRecognitionRequest
        init(_ request: SFSpeechAudioBufferRecognitionRequest) { self.request = request }
    }

    convenience init(_ request: SFSpeechAudioBufferRecognitionRequest) {
        let box = RequestBox(request)
        self.init(append: { box.request.append($0) }, end: { box.request.endAudio() })
    }

    init(append: @escaping @Sendable (AVAudioPCMBuffer) -> Void, end: @escaping @Sendable () -> Void) {
        appendBuffer = append
        endAudio = end
    }

    @discardableResult func append(_ buffer: AVAudioPCMBuffer) -> Bool {
        // The realtime tap must never wait for another append or for finish.
        guard lock.try() else { return false }
        defer { lock.unlock() }
        guard !ended else { return false }
        appendBuffer(buffer)
        return true
    }
    func finish() {
        // Wait for any in-flight append off the audio callback, then close the
        // gate before invoking the framework outside the lock.
        lock.lock()
        guard !ended else { lock.unlock(); return }
        ended = true
        lock.unlock()
        endAudio()
    }

}

/// Time is measured from samples, not recognition callbacks. Unknown formats
/// never trigger automatic submission; the coordinator stops after a timeout.
struct SpeechPauseDetector {
    private let pauseDuration: Double
    private var speechDuration = 0.0
    private var silenceDuration = 0.0
    private var fired = false
    init(pauseDuration: Double = VoiceEndpointSettings.defaultPause) { self.pauseDuration = pauseDuration }
    mutating func observe(level: Float, duration: Double) -> Bool {
        guard !fired, level.isFinite, duration.isFinite, duration > 0 else { return false }
        if level >= 0.015 {
            speechDuration += duration
            silenceDuration = 0
        } else if speechDuration >= 0.3 {
            silenceDuration += duration
            if silenceDuration >= pauseDuration { fired = true; return true }
        }
        return false
    }
}

/// Consumes buffer samples synchronously on the tap; it never retains a buffer.
final class AudioPauseMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var detector: SpeechPauseDetector
    private let onSilence: @MainActor @Sendable () -> Void
    init(pauseDuration: Double = VoiceEndpointSettings.defaultPause, onSilence: @escaping @MainActor @Sendable () -> Void) {
        detector = SpeechPauseDetector(pauseDuration: pauseDuration)
        self.onSilence = onSilence
    }
    func observe(_ buffer: AVAudioPCMBuffer) {
        guard lock.try() else { return }
        defer { lock.unlock() }
        let channelCount = Int(buffer.format.channelCount)
        guard buffer.format.commonFormat == .pcmFormatFloat32,
              channelCount > 0, channelCount <= 8,
              let channels = buffer.floatChannelData, buffer.frameLength > 0,
              buffer.format.sampleRate.isFinite, buffer.format.sampleRate > 0, buffer.stride > 0 else { return }
        let count = Int(buffer.frameLength)
        // Decimate for a bounded tap cost (at most 256 samples/channel for
        // the configured 1024-frame tap). Sampling can miss or overestimate
        // energy; this is not a speech classifier. Auto-submit has a review countdown.
        let sampleStep = 4
        let sampleCount = (count + sampleStep - 1) / sampleStep
        var maxLevel: Float = 0
        for channel in 0..<channelCount {
            var sum: Double = 0
            for index in stride(from: 0, to: count, by: sampleStep) {
                let sample = Double(channels[channel][index * Int(buffer.stride)])
                sum += sample * sample
            }
            let level = Float((sum / Double(sampleCount)).squareRoot())
            guard level.isFinite else { return }
            maxLevel = max(maxLevel, level)
        }
        if detector.observe(level: maxLevel, duration: Double(count) / buffer.format.sampleRate) {
            DispatchQueue.main.async { [onSilence] in onSilence() }
        }
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

    func requestSpeechPermission() async -> Bool {
        let state: VoicePermissionPolicy.State
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: state = .granted
        case .notDetermined: state = .undetermined
        default: state = .denied
        }
        return await VoicePermissionPolicy.resolve(state) { await SpeechCallbackBridge.requestSpeechAuthorization() }
    }
    func requestMicrophonePermission() async -> Bool {
        let state: VoicePermissionPolicy.State
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: state = .granted
        case .notDetermined: state = .undetermined
        default: state = .denied
        }
        return await VoicePermissionPolicy.resolve(state) { await AVCaptureDevice.requestAccess(for: .audio) }
    }

    func start(onText: @escaping @MainActor @Sendable (String) -> Void, onFailure: @escaping @MainActor @Sendable (String) -> Void, onFinish: @escaping @MainActor @Sendable (Bool) -> Void, onSilence: @escaping @MainActor @Sendable () -> Void) throws {
        guard let recognizer, isOnDeviceSupported else { throw SpeechError.unavailable }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        let gate = AudioRequestGate(request)
        self.audioGate = gate
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw SpeechError.unavailable }
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: SpeechCallbackBridge.tap(gate: gate, monitor: AudioPauseMonitor(pauseDuration: VoiceEndpointSettings.pauseSeconds(), onSilence: onSilence)))
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

/// Stores completion callbacks by utterance so a cancelled old utterance can
/// never end the state of a newer one; framework callbacks may arrive off-main.
private final class SpeechCompletionStore: @unchecked Sendable {
    private let lock = NSLock()
    private var callbacks: [ObjectIdentifier: @MainActor @Sendable (Bool) -> Void] = [:]
    func insert(_ id: ObjectIdentifier, _ callback: @escaping @MainActor @Sendable (Bool) -> Void) { lock.lock(); defer { lock.unlock() }; callbacks[id] = callback }
    func take(_ id: ObjectIdentifier) -> (@MainActor @Sendable (Bool) -> Void)? { lock.lock(); defer { lock.unlock() }; return callbacks.removeValue(forKey: id) }
    func clear() { lock.lock(); defer { lock.unlock() }; callbacks.removeAll() }
}

enum VoicePlaybackSettings {
    static let voiceKey = "jarvis.voice.identifier"
    static let rateKey = "jarvis.voice.rate"
    static func availableIdentifier(_ requested: String, in available: [String]) -> String? {
        !requested.isEmpty && available.contains(requested) ? requested : nil
    }
    static func safeRate(_ rate: Double) -> Double {
        guard rate.isFinite else { return 0.5 }
        return min(0.6, max(0.35, rate))
    }
}

@MainActor final class SystemVoiceSpeaker: NSObject, VoiceSpeaker, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private nonisolated let completions = SpeechCompletionStore()
    override init() { super.init(); synthesizer.delegate = self }
    func speak(_ text: String, onFinish: @escaping @MainActor @Sendable (Bool) -> Void) {
        let utterance = AVSpeechUtterance(string: text)
        let defaults = UserDefaults.standard
        let available = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.lowercased().hasPrefix("zh") }
        let requested = defaults.string(forKey: VoicePlaybackSettings.voiceKey) ?? ""
        let identifier = VoicePlaybackSettings.availableIdentifier(requested, in: available.map(\.identifier))
        utterance.voice = identifier.flatMap(AVSpeechSynthesisVoice.init(identifier:)) ?? AVSpeechSynthesisVoice(language: "zh-CN")
        let storedRate = (defaults.object(forKey: VoicePlaybackSettings.rateKey) as? NSNumber)?.doubleValue ?? 0.5
        utterance.rate = Float(VoicePlaybackSettings.safeRate(storedRate))
        completions.insert(ObjectIdentifier(utterance), onFinish)
        synthesizer.speak(utterance)
    }
    func stop() { completions.clear(); synthesizer.stopSpeaking(at: .immediate) }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        if let callback = completions.take(ObjectIdentifier(utterance)) { Task { @MainActor in callback(true) } }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        if let callback = completions.take(ObjectIdentifier(utterance)) { Task { @MainActor in callback(false) } }
    }
}
