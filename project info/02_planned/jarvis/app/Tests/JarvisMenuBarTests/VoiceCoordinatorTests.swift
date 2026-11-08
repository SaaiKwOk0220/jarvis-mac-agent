import XCTest
@preconcurrency import AVFoundation
@preconcurrency import Speech
@testable import JarvisMenuBar

@MainActor private final class FakeVoiceBackend: VoiceBackend {
    var isOnDeviceSupported = true
    var permissionGranted = true
    var started = false
    var stopped = false
    var finished = false
    var handler: (@MainActor @Sendable (String) -> Void)?
    var failureHandler: (@MainActor @Sendable (String) -> Void)?
    var finishHandler: (@MainActor @Sendable (Bool) -> Void)?
    var silenceHandler: (@MainActor @Sendable () -> Void)?
    var deferPermission = false
    var permissionContinuation: CheckedContinuation<Bool, Never>?
    var microphoneRequested = false
    var microphoneGranted = true
    func requestSpeechPermission() async -> Bool {
        if deferPermission { return await withCheckedContinuation { permissionContinuation = $0 } }
        return permissionGranted
    }
    func requestMicrophonePermission() async -> Bool { microphoneRequested = true; return microphoneGranted }
    func start(onText: @escaping @MainActor @Sendable (String) -> Void, onFailure: @escaping @MainActor @Sendable (String) -> Void, onFinish: @escaping @MainActor @Sendable (Bool) -> Void, onSilence: @escaping @MainActor @Sendable () -> Void) throws { started = true; handler = onText; failureHandler = onFailure; finishHandler = onFinish; silenceHandler = onSilence }
    func stop() { stopped = true }
    func finish() { finished = true }
}

@MainActor private final class FakeSpeaker: VoiceSpeaker {
    var stopCount = 0
    var spoken: [String] = []
    var completion: (@MainActor @Sendable () -> Void)?
    func speak(_ text: String, onFinish: @escaping @MainActor @Sendable () -> Void) { spoken.append(text); completion = onFinish }
    func stop() { stopCount += 1 }
}

private final class GateProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var active = false
    private var ended = false
    private var violation = false
    func append() { lock.lock(); if active || ended { violation = true }; active = true; lock.unlock(); usleep(100); lock.lock(); active = false; lock.unlock() }
    func finish() { lock.lock(); if active || ended { violation = true }; ended = true; lock.unlock() }
    var valid: Bool { lock.lock(); defer { lock.unlock() }; return ended && !violation }
}

@MainActor final class VoiceCoordinatorTests: XCTestCase {
    func testAutoSubmitCountdownCanBeCancelledForEditOrClose() async throws {
        let gate = VoiceAutoSubmitGate(tick: .milliseconds(20))
        var sent: [String] = []
        gate.schedule("草稿") { sent.append($0) }
        try await Task.sleep(for: .milliseconds(25))
        gate.cancel()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(sent.isEmpty)
        XCTAssertNil(gate.pendingText)
    }

    func testNewSessionInvalidatesOldCountdownAndSubmitsOnlyOnce() async throws {
        let gate = VoiceAutoSubmitGate(tick: .milliseconds(20))
        var sent: [String] = []
        gate.schedule("旧") { sent.append($0) }
        try await Task.sleep(for: .milliseconds(25))
        gate.schedule("新") { sent.append($0) }
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(sent, ["新"])
        XCTAssertNil(gate.pendingText)
    }

    func testContinuousNoiseAndShortPausesDoNotEndRecording() {
        var detector = SpeechPauseDetector()
        for _ in 0..<20 { XCTAssertFalse(detector.observe(level: 0.08, duration: 0.1)) }
        XCTAssertFalse(detector.observe(level: 0, duration: 1.0))
        XCTAssertFalse(detector.observe(level: 0.08, duration: 0.4))
        XCTAssertFalse(detector.observe(level: 0, duration: 1.0))
    }
    func testSpeakingStateAndInterruptionIgnoreStaleCompletion() async {
        let speaker = FakeSpeaker(); let voice = VoiceCoordinator(backend: FakeVoiceBackend(), speaker: speaker)
        voice.speak("回答")
        XCTAssertTrue(voice.isSpeaking)
        let oldCompletion = speaker.completion
        await voice.start()
        XCTAssertFalse(voice.isSpeaking)
        voice.stop()
        voice.speak("新回答")
        oldCompletion?()
        XCTAssertTrue(voice.isSpeaking)
        speaker.completion?()
        XCTAssertFalse(voice.isSpeaking)
    }
    func testSilenceDetectorRequiresSpeechBeforePauseAndFiresOnce() {
        var detector = SpeechPauseDetector()
        XCTAssertFalse(detector.observe(level: 0, duration: 3))
        XCTAssertFalse(detector.observe(level: 0.08, duration: 0.4))
        XCTAssertFalse(detector.observe(level: 0, duration: 1.0))
        XCTAssertTrue(detector.observe(level: 0, duration: 0.6))
        XCTAssertFalse(detector.observe(level: 0, duration: 3))
    }

    func testAutoFinalOnlyOnceAndOnlyAfterDetectedPause() async {
        let backend = FakeVoiceBackend(); let voice = VoiceCoordinator(backend: backend)
        var sent: [String] = []
        await voice.start(autoSubmit: { sent.append($0) })
        backend.handler?("测试")
        backend.silenceHandler?()
        backend.finishHandler?(true)
        backend.finishHandler?(true)
        XCTAssertEqual(sent, ["测试"])
    }

    func testDraftUpdatePrecedesAutoSubmitAndLateTextIsIgnored() async {
        let backend = FakeVoiceBackend(); let voice = VoiceCoordinator(backend: backend)
        var events: [String] = []
        await voice.start(onTranscript: { events.append("draft:" + $0) }, autoSubmit: { events.append("run:" + $0) })
        backend.handler?("最终")
        let staleText = backend.handler
        backend.silenceHandler?()
        backend.finishHandler?(true)
        staleText?("迟到")
        XCTAssertEqual(events, ["draft:最终", "run:最终"])
    }

    func testAutoFinalRejectsEmptyFailureAndCancellation() async {
        let backend = FakeVoiceBackend(); let voice = VoiceCoordinator(backend: backend)
        var sent: [String] = []
        await voice.start(autoSubmit: { sent.append($0) })
        backend.handler?("部分")
        backend.silenceHandler?()
        backend.finishHandler?(false)
        XCTAssertTrue(sent.isEmpty)
        voice.confirmTranscript()
        await voice.start(autoSubmit: { sent.append($0) })
        backend.handler?("旧结果")
        backend.silenceHandler?()
        voice.stop()
        backend.finishHandler?(true)
        XCTAssertTrue(sent.isEmpty)
    }

    func testAutoSubmitRequiresPauseAndIsSuppressedAfterFailure() async {
        let backend = FakeVoiceBackend(); let voice = VoiceCoordinator(backend: backend)
        var sent: [String] = []
        await voice.start(autoSubmit: { sent.append($0) })
        backend.handler?("未等待停顿")
        voice.finishRecording()
        backend.finishHandler?(true)
        XCTAssertTrue(sent.isEmpty, "Manual stop must not auto-submit")
        await voice.start(autoSubmit: { sent.append($0) })
        backend.handler?("部分结果")
        backend.silenceHandler?()
        let staleFinal = backend.finishHandler
        backend.failureHandler?("error")
        staleFinal?(true)
        XCTAssertTrue(sent.isEmpty, "A result after an error must not auto-submit")
        XCTAssertTrue(voice.needsConfirmation)
    }

    func testRecordingTimeoutFallsBackToManualEvenWithFinalText() async throws {
        let backend = FakeVoiceBackend()
        let voice = VoiceCoordinator(backend: backend, recordingLimit: .milliseconds(20))
        var sent: [String] = []
        await voice.start(autoSubmit: { sent.append($0) })
        backend.handler?("测试")
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertTrue(voice.isFinishing)
        XCTAssertTrue(backend.finished)
        backend.finishHandler?(true)
        XCTAssertTrue(sent.isEmpty)
        XCTAssertEqual(voice.transcript, "测试")
        XCTAssertNotNil(voice.errorMessage)
    }

    func testSilenceDetectorDoesNotTreatInvalidMeasurementsAsPause() {
        var detector = SpeechPauseDetector()
        XCTAssertFalse(detector.observe(level: .nan, duration: 1))
        XCTAssertFalse(detector.observe(level: 0.1, duration: .infinity))
        XCTAssertFalse(detector.observe(level: 0, duration: 9))
    }

    func testAudioSamplesTriggerPauseOnlyAfterSpeechAndSilence() async throws {
        let paused = expectation(description: "detected pause")
        let monitor = AudioPauseMonitor(onSilence: { paused.fulfill() })
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        let speech = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 6400))
        speech.frameLength = 6400
        let samples = try XCTUnwrap(speech.floatChannelData)
        for index in 0..<6400 { samples[0][index] = 0.1 }
        let silence = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 25600))
        silence.frameLength = 25600
        let zero = try XCTUnwrap(silence.floatChannelData)
        for index in 0..<25600 { zero[0][index] = 0 }
        monitor.observe(speech)
        monitor.observe(silence)
        await fulfillment(of: [paused], timeout: 2)
    }

    func testSpeechOnSecondChannelStillDetectsPause() async throws {
        let paused = expectation(description: "second channel detected")
        let monitor = AudioPauseMonitor(onSilence: { paused.fulfill() })
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 2))
        let speech = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 6400))
        speech.frameLength = 6400
        let channels = try XCTUnwrap(speech.floatChannelData)
        for index in 0..<6400 { channels[0][index] = 0; channels[1][index] = 0.1 }
        let silence = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 25600))
        silence.frameLength = 25600
        let zero = try XCTUnwrap(silence.floatChannelData)
        for index in 0..<25600 { zero[0][index] = 0; zero[1][index] = 0 }
        monitor.observe(speech); monitor.observe(silence)
        await fulfillment(of: [paused], timeout: 2)
    }

    func testInterleavedStereoDetectsSpeechOnSecondChannel() async throws {
        let paused = expectation(description: "interleaved second channel detected")
        let monitor = AudioPauseMonitor(onSilence: { paused.fulfill() })
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 2, interleaved: true))
        let speech = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 6400))
        speech.frameLength = 6400
        let channels = try XCTUnwrap(speech.floatChannelData)
        for index in 0..<6400 { channels[0][index * 2] = 0; channels[1][index * 2] = 0.1 }
        let silence = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 25600))
        silence.frameLength = 25600
        let zero = try XCTUnwrap(silence.floatChannelData)
        for index in 0..<25600 { zero[0][index * 2] = 0; zero[1][index * 2] = 0 }
        monitor.observe(speech); monitor.observe(silence)
        await fulfillment(of: [paused], timeout: 2)
    }

    func testNonFloatAudioNeverTriggersAutomaticPause() async throws {
        let paused = expectation(description: "unsupported format must not trigger")
        paused.isInverted = true
        let monitor = AudioPauseMonitor(onSilence: { paused.fulfill() })
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000))
        buffer.frameLength = 16000
        monitor.observe(buffer); monitor.observe(buffer)
        await fulfillment(of: [paused], timeout: 0.1)
    }
    func testNewRecordingDoesNotEraseExistingEditableDraft() async {
        let backend = FakeVoiceBackend(); let speaker = FakeSpeaker()
        let voice = VoiceCoordinator(backend: backend, speaker: speaker)
        var draft = "已有文字"
        let prefix = VoiceDraftPrefix(draft: draft)
        await voice.start()
        XCTAssertNil(prefix.render(transcript: ""), "Clearing the recognizer must not clear the draft")
        backend.handler?("语音内容")
        if let value = prefix.render(transcript: voice.transcript) { draft = value }
        voice.finishRecording(); backend.finishHandler?(true)
        draft += "，手动补充"
        voice.stopSpeaking()
        XCTAssertEqual(draft, "已有文字 语音内容，手动补充")
        XCTAssertTrue(VoiceDraftPrefix.canRun(draft: draft, serviceAvailable: true, isRunning: false, voiceBusy: false))
    }

    func testRunRequiresServiceNonemptyDraftAndFinishedRecording() {
        XCTAssertFalse(VoiceDraftPrefix.canRun(draft: "文字", serviceAvailable: false, isRunning: false, voiceBusy: false))
        XCTAssertFalse(VoiceDraftPrefix.canRun(draft: "文字", serviceAvailable: true, isRunning: false, voiceBusy: true))
        XCTAssertFalse(VoiceDraftPrefix.canRun(draft: " \n", serviceAvailable: true, isRunning: false, voiceBusy: false))
        XCTAssertTrue(VoiceDraftPrefix.canRun(draft: "文字", serviceAvailable: true, isRunning: false, voiceBusy: false))
    }

    func testAutomaticVoiceSubmissionNeverUsesExistingDraftOrMissingService() {
        XCTAssertFalse(VoiceDraftPrefix.allowsAutomaticSubmission(draft: "原有草稿", serviceAvailable: true))
        XCTAssertFalse(VoiceDraftPrefix.allowsAutomaticSubmission(draft: "", serviceAvailable: false))
        XCTAssertTrue(VoiceDraftPrefix.allowsAutomaticSubmission(draft: " \n", serviceAvailable: true))
    }

    func testStartingRunDoesNotShowReadyBeforeTaskIDExists() {
        XCTAssertEqual(VoiceDraftPrefix.idleStatus(draft: "任务", serviceAvailable: true, isRunning: true), "正在创建任务…")
    }
    func testAuthorizationCallbackCanArriveOnBackgroundQueue() async {
        let allowed = await SpeechCallbackBridge.authorization { callback in
            DispatchQueue.global().async { callback(true) }
        }
        XCTAssertTrue(allowed)
    }

    func testRecognitionCallbackCanArriveOnBackgroundQueue() async {
        let delivered = expectation(description: "failure delivered to main actor")
        let callback = SpeechCallbackBridge.recognition(onText: { _ in XCTFail("unexpected text") }, onFailure: { _ in delivered.fulfill() }, onFinish: { _ in XCTFail("unexpected completion") })
        DispatchQueue.global().async { callback(nil, NSError(domain: "test", code: 1)) }
        await fulfillment(of: [delivered], timeout: 2)
    }

    func testRecognitionEventsAreOrderedAndTerminal() async {
        let done = expectation(description: "final event")
        var observed: [String] = []
        let events = RecognitionEvents(onText: { observed.append($0) }, onFailure: { _ in XCTFail("unexpected error") }, onFinish: { _ in observed.append("finished"); done.fulfill() })
        DispatchQueue.global().async {
            events.submit(text: "partial", failed: false, finished: false)
            events.submit(text: "final", failed: false, finished: true)
            events.submit(text: "late", failed: false, finished: false)
        }
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(observed, ["partial", "final", "finished"])
    }

    func testFinalValidityComesFromFinalEventRatherThanPartial() async {
        let done = expectation(description: "all final events")
        done.expectedFulfillmentCount = 3
        var validity: [Bool] = []
        for text: String? in [nil, "  ", "最终"] {
            let events = RecognitionEvents(onText: { _ in }, onFailure: { _ in XCTFail("unexpected error") }, onFinish: { valid in validity.append(valid); done.fulfill() })
            events.submit(text: "partial", failed: false, finished: false)
            events.submit(text: text, failed: false, finished: true)
        }
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(validity, [false, false, true])
    }

    func testAudioTapRunsOnBackgroundQueueAndCanFinish() async {
        let done = expectation(description: "background audio tap")
        let gate = AudioRequestGate(SFSpeechAudioBufferRecognitionRequest())
        let tap = SpeechCallbackBridge.tap(gate: gate)
        DispatchQueue.global().async {
            guard let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64) else { return }
            buffer.frameLength = 64
            tap(buffer, AVAudioTime(hostTime: 0))
            gate.finish()
            tap(buffer, AVAudioTime(hostTime: 0))
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 2)
    }

    func testBusyAudioTapDropsFrameAndFinishWaitsForAppend() async throws {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let endCalled = DispatchSemaphore(value: 0)
        let done = expectation(description: "append and finish")
        done.expectedFulfillmentCount = 2
        let gate = AudioRequestGate(append: { _ in entered.signal(); _ = release.wait(timeout: .now() + 2) }, end: { endCalled.signal(); done.fulfill() })
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        let first = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64))
        let second = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64))
        let tap = SpeechCallbackBridge.tap(gate: gate)
        DispatchQueue.global().async {
            tap(first, AVAudioTime(hostTime: 0)); done.fulfill()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        // This must return immediately, not wait for the in-flight append.
        let start = Date()
        tap(second, AVAudioTime(hostTime: 0))
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5, "Audio callback waited for the held gate")
        DispatchQueue.global().async { gate.finish() }
        XCTAssertEqual(endCalled.wait(timeout: .now() + 0.1), .timedOut, "endAudio ran during append")
        release.signal()
        await fulfillment(of: [done], timeout: 3)
    }

    func testConcurrentAudioTapsAndFinishDoNotOverlap() async {
        let probe = GateProbe()
        let gate = AudioRequestGate(append: { _ in probe.append() }, end: { probe.finish() })
        let done = expectation(description: "concurrent taps and finish")
        DispatchQueue.global().async {
            DispatchQueue.concurrentPerform(iterations: 500) { index in
                if index == 100 { gate.finish(); return }
                guard let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1),
                      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64) else { return }
                gate.append(buffer)
            }
            gate.finish()
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 5)
        XCTAssertTrue(probe.valid, "append overlapped endAudio or happened after it")
    }
    func testStartingRecordingStopsSpeechAndBlocksSpeechUntilFinished() async {
        let backend = FakeVoiceBackend(); let speaker = FakeSpeaker()
        let voice = VoiceCoordinator(backend: backend, speaker: speaker)
        voice.speak("回答")
        XCTAssertEqual(speaker.spoken, ["回答"])
        let before = speaker.stopCount
        await voice.start()
        XCTAssertGreaterThan(speaker.stopCount, before)
        voice.speak("录音时禁止")
        voice.finishRecording()
        voice.speak("结束转写前禁止")
        XCTAssertEqual(speaker.spoken, ["回答"])
        voice.stop()
        voice.speak("可以朗读")
        XCTAssertEqual(speaker.spoken, ["回答", "可以朗读"])
        voice.stopSpeaking()
        XCTAssertGreaterThan(speaker.stopCount, before + 1)
    }
    func testUnsupportedDeviceNeverRequestsOrStarts() async {
        let backend = FakeVoiceBackend(); backend.isOnDeviceSupported = false
        let voice = VoiceCoordinator(backend: backend)
        await voice.start()
        XCTAssertFalse(backend.started)
        XCTAssertNotNil(voice.errorMessage)
    }

    func testPermissionDeniedDoesNotStart() async {
        let backend = FakeVoiceBackend(); backend.permissionGranted = false
        let voice = VoiceCoordinator(backend: backend)
        await voice.start()
        XCTAssertFalse(backend.started)
        XCTAssertNotNil(voice.errorMessage)
    }

    func testMicrophoneDeniedAfterSpeechPermissionDoesNotStart() async {
        let backend = FakeVoiceBackend(); backend.microphoneGranted = false
        let voice = VoiceCoordinator(backend: backend)
        await voice.start()
        XCTAssertTrue(backend.microphoneRequested)
        XCTAssertFalse(backend.started)
        XCTAssertNotNil(voice.errorMessage)
    }

    func testTranscriptRequiresManualSendAndStopReleases() async {
        let backend = FakeVoiceBackend(); let voice = VoiceCoordinator(backend: backend)
        await voice.start()
        XCTAssertTrue(voice.isRecording)
        backend.handler?("你好")
        XCTAssertEqual(voice.transcript, "你好")
        voice.stop()
        XCTAssertFalse(voice.isRecording)
        XCTAssertTrue(backend.stopped)
        backend.handler?("迟到结果")
        XCTAssertEqual(voice.transcript, "你好")
    }

    func testRecognizerFailureStopsAndShowsError() async {
        let backend = FakeVoiceBackend(); let voice = VoiceCoordinator(backend: backend)
        await voice.start()
        backend.failureHandler?("识别失败")
        XCTAssertTrue(backend.stopped)
        XCTAssertFalse(voice.isRecording)
        XCTAssertEqual(voice.errorMessage, "识别失败")
    }

    func testFinalResultStopsRecording() async {
        let backend = FakeVoiceBackend(); let voice = VoiceCoordinator(backend: backend)
        await voice.start()
        backend.handler?("你好")
        backend.finishHandler?(true)
        XCTAssertEqual(voice.transcript, "你好")
        XCTAssertTrue(backend.stopped)
        XCTAssertFalse(voice.isRecording)
    }

    func testManualFinishAcceptsDelayedFinalAndThenReleases() async {
        let backend = FakeVoiceBackend(); let voice = VoiceCoordinator(backend: backend)
        await voice.start()
        voice.finishRecording()
        XCTAssertTrue(backend.finished)
        XCTAssertFalse(backend.stopped)
        XCTAssertTrue(voice.isFinishing)
        backend.handler?("最终文本")
        backend.finishHandler?(true)
        XCTAssertEqual(voice.transcript, "最终文本")
        XCTAssertFalse(voice.isFinishing)
        XCTAssertTrue(backend.stopped)
    }

    func testEmptyFinalCannotErasePartialTranscript() async {
        let backend = FakeVoiceBackend(); let voice = VoiceCoordinator(backend: backend)
        await voice.start()
        backend.handler?("已有转写")
        voice.finishRecording()
        backend.handler?("")
        backend.finishHandler?(false)
        XCTAssertEqual(voice.transcript, "已有转写")
        XCTAssertFalse(voice.isFinishing)
        XCTAssertTrue(voice.needsConfirmation)
        XCTAssertFalse(VoiceDraftPrefix.canRun(draft: voice.transcript, serviceAvailable: true, isRunning: false, voiceBusy: voice.isFinishing || voice.needsConfirmation))
        voice.confirmTranscript()
        XCTAssertFalse(voice.needsConfirmation)
        XCTAssertTrue(VoiceDraftPrefix.canRun(draft: voice.transcript, serviceAvailable: true, isRunning: false, voiceBusy: voice.needsConfirmation))
    }

    func testMissingFinalTextRequiresConfirmationInsteadOfReusingPartialState() async {
        let backend = FakeVoiceBackend(); let voice = VoiceCoordinator(backend: backend)
        await voice.start()
        backend.handler?("部分结果")
        voice.finishRecording()
        backend.finishHandler?(false)
        XCTAssertEqual(voice.transcript, "部分结果")
        XCTAssertTrue(voice.needsConfirmation)
        XCTAssertFalse(voice.isFinishing)
    }

    func testCancellingTranscriptionCanRestoreOriginalDraft() {
        let prefix = VoiceDraftPrefix(draft: "用户原有草稿")
        XCTAssertEqual(prefix.render(transcript: "部分转写"), "用户原有草稿 部分转写")
        XCTAssertEqual(prefix.originalDraft, "用户原有草稿")
    }

    func testCancelWhileFinishingDiscardsLateResult() async {
        let backend = FakeVoiceBackend(); let voice = VoiceCoordinator(backend: backend)
        await voice.start()
        voice.finishRecording()
        voice.stop()
        backend.handler?("迟到结果")
        XCTAssertEqual(voice.transcript, "")
        XCTAssertFalse(voice.isFinishing)
    }

    func testRapidRestartIgnoresPreviousSessionCallbacks() async {
        let backend = FakeVoiceBackend(); let voice = VoiceCoordinator(backend: backend)
        await voice.start()
        let staleText = backend.handler
        let staleFinish = backend.finishHandler
        voice.stop()
        await voice.start()
        staleText?("旧录音")
        staleFinish?(true)
        XCTAssertTrue(voice.isRecording)
        XCTAssertEqual(voice.transcript, "")
        backend.handler?("新录音")
        XCTAssertEqual(voice.transcript, "新录音")
        voice.stop()
    }

    func testFinishTimeoutStopsAndKeepsPartialText() async throws {
        let backend = FakeVoiceBackend(); let voice = VoiceCoordinator(backend: backend)
        await voice.start()
        backend.handler?("部分转写")
        voice.finishRecording()
        try await Task.sleep(for: .seconds(5.2))
        XCTAssertFalse(voice.isFinishing)
        XCTAssertEqual(voice.transcript, "部分转写")
        XCTAssertNotNil(voice.errorMessage)
        XCTAssertTrue(backend.stopped)
    }

    func testClosingDuringPermissionDoesNotStartRecording() async {
        let backend = FakeVoiceBackend(); backend.deferPermission = true
        let voice = VoiceCoordinator(backend: backend)
        let task = Task { await voice.start() }
        await Task.yield()
        XCTAssertNotNil(backend.permissionContinuation)
        voice.stop()
        backend.permissionContinuation?.resume(returning: true)
        await task.value
        XCTAssertFalse(backend.started)
        XCTAssertFalse(backend.microphoneRequested)
        XCTAssertFalse(voice.isRecording)
    }
}
