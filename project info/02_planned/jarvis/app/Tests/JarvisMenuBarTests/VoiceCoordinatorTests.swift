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
    func requestPermission() async -> Bool {
        if deferPermission { return await withCheckedContinuation { permissionContinuation = $0 } }
        return permissionGranted
    }
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

@MainActor final class VoiceCoordinatorTests: XCTestCase {
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
        XCTAssertFalse(voice.isRecording)
    }
}
