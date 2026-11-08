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
    var finishHandler: (@MainActor @Sendable () -> Void)?
    var deferPermission = false
    var permissionContinuation: CheckedContinuation<Bool, Never>?
    var microphoneRequested = false
    var microphoneGranted = true
    func requestSpeechPermission() async -> Bool {
        if deferPermission { return await withCheckedContinuation { permissionContinuation = $0 } }
        return permissionGranted
    }
    func requestMicrophonePermission() async -> Bool { microphoneRequested = true; return microphoneGranted }
    func start(onText: @escaping @MainActor @Sendable (String) -> Void, onFailure: @escaping @MainActor @Sendable (String) -> Void, onFinish: @escaping @MainActor @Sendable () -> Void) throws { started = true; handler = onText; failureHandler = onFailure; finishHandler = onFinish }
    func stop() { stopped = true }
    func finish() { finished = true }
}

@MainActor private final class FakeSpeaker: VoiceSpeaker {
    var stopCount = 0
    var spoken: [String] = []
    func speak(_ text: String) { spoken.append(text) }
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
    func testNewRecordingDoesNotEraseExistingEditableDraft() async {
        let backend = FakeVoiceBackend(); let speaker = FakeSpeaker()
        let voice = VoiceCoordinator(backend: backend, speaker: speaker)
        var draft = "已有文字"
        let prefix = VoiceDraftPrefix(draft: draft)
        await voice.start()
        XCTAssertNil(prefix.render(transcript: ""), "Clearing the recognizer must not clear the draft")
        backend.handler?("语音内容")
        if let value = prefix.render(transcript: voice.transcript) { draft = value }
        voice.finishRecording(); backend.finishHandler?()
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
        let callback = SpeechCallbackBridge.recognition(onText: { _ in XCTFail("unexpected text") }, onFailure: { _ in delivered.fulfill() }, onFinish: { XCTFail("unexpected completion") })
        DispatchQueue.global().async { callback(nil, NSError(domain: "test", code: 1)) }
        await fulfillment(of: [delivered], timeout: 2)
    }

    func testRecognitionEventsAreOrderedAndTerminal() async {
        let done = expectation(description: "final event")
        var observed: [String] = []
        let events = RecognitionEvents(onText: { observed.append($0) }, onFailure: { _ in XCTFail("unexpected error") }, onFinish: { observed.append("finished"); done.fulfill() })
        DispatchQueue.global().async {
            events.submit(text: "partial", failed: false, finished: false)
            events.submit(text: "final", failed: false, finished: true)
            events.submit(text: "late", failed: false, finished: false)
        }
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(observed, ["partial", "final", "finished"])
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
        backend.finishHandler?()
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
        backend.finishHandler?()
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
        backend.finishHandler?()
        XCTAssertEqual(voice.transcript, "已有转写")
        XCTAssertFalse(voice.isFinishing)
        XCTAssertTrue(voice.needsConfirmation)
        XCTAssertFalse(VoiceDraftPrefix.canRun(draft: voice.transcript, serviceAvailable: true, isRunning: false, voiceBusy: voice.isFinishing || voice.needsConfirmation))
        voice.confirmTranscript()
        XCTAssertFalse(voice.needsConfirmation)
        XCTAssertTrue(VoiceDraftPrefix.canRun(draft: voice.transcript, serviceAvailable: true, isRunning: false, voiceBusy: voice.needsConfirmation))
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
        staleFinish?()
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
