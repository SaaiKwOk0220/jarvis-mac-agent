import XCTest
@preconcurrency import AVFoundation
@preconcurrency import Speech
import JarvisLLM
@testable import JarvisMenuBar

@MainActor private final class FakeVoiceBackend: VoiceBackend {
    var isOnDeviceSupported = true
    var permissionGranted = true
    var started = false
    var stopped = false
    var finished = false
    var onFinish: (() -> Void)?
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
    func finish() { finished = true; onFinish?() }
}

@MainActor private final class FakeSpeaker: VoiceSpeaker {
    var stopCount = 0
    var spoken: [String] = []
    var completion: (@MainActor @Sendable (Bool) -> Void)?
    func speak(_ text: String, onFinish: @escaping @MainActor @Sendable (Bool) -> Void) { spoken.append(text); completion = onFinish }
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

private actor ConversationTestProvider: LLMProvider {
    let identifier = "test"
    private(set) var requests: [[LLMMessage]] = []
    func complete(messages: [LLMMessage], tools: [LLMTool]) async throws -> LLMResponse {
        requests.append(messages)
        return .init(content: "回答\(requests.count)", toolCalls: [], usage: nil)
    }
}
private actor DeferredTaskCreation {
    private var continuation: CheckedContinuation<UUID, Never>?
    private(set) var cancelled: [UUID] = []
    var isWaiting: Bool { continuation != nil }
    private let onStart: @Sendable () -> Void
    init(onStart: @escaping @Sendable () -> Void) { self.onStart = onStart }
    func create() async -> UUID { await withCheckedContinuation { continuation = $0; onStart() } }
    func finish(_ id: UUID) { continuation?.resume(returning: id); continuation = nil }
    func cancel(_ id: UUID) { cancelled.append(id) }
}
private struct ConversationTestRunner: AgentToolRunner {
    func tools() -> [LLMTool] { [] }
    func perform(_ call: LLMToolCall) async throws -> AgentToolOutcome { .denied("unexpected tool") }
}
private struct ConversationTestWaiter: ApprovalWaiter {
    func waitForResolution(requestID: UUID, payloadDigest: String, taskID: UUID) async throws -> ToolResolution { .cancelled }
}

@MainActor final class VoiceCoordinatorTests: XCTestCase {
    func testVoiceQualityLabelsAndPreviewDoesNotOpenMicrophone() async {
        XCTAssertEqual(VoicePlaybackSettings.qualityLabel(.default), "默认")
        XCTAssertEqual(VoicePlaybackSettings.qualityLabel(.enhanced), "增强")
        XCTAssertEqual(VoicePlaybackSettings.qualityLabel(.premium), "高品质")
        let backend = FakeVoiceBackend(); let speaker = FakeSpeaker()
        let voice = VoiceCoordinator(backend: backend, speaker: speaker)
        voice.previewVoice(conversationActive: false, isRunning: false)
        XCTAssertEqual(speaker.spoken, [VoicePlaybackSettings.previewText])
        XCTAssertTrue(voice.isSpeaking)
        XCTAssertFalse(backend.microphoneRequested)
        XCTAssertFalse(backend.started)
        voice.stopSpeaking()
        XCTAssertFalse(voice.isSpeaking)
        voice.previewVoice(conversationActive: true, isRunning: false)
        voice.previewVoice(conversationActive: false, isRunning: true)
        XCTAssertEqual(speaker.spoken.count, 1)
        await voice.start(onTranscript: { _ in })
        voice.previewVoice(conversationActive: false, isRunning: false)
        XCTAssertEqual(speaker.spoken.count, 1)
    }

    func testLongSentencePauseDoesNotFinishAtOneAndHalfSeconds() {
        var detector = SpeechPauseDetector(pauseDuration: 3.5)
        XCTAssertFalse(detector.observe(level: 0.08, duration: 0.4))
        XCTAssertFalse(detector.observe(level: 0, duration: 1.8))
        XCTAssertFalse(detector.observe(level: 0.08, duration: 0.4))
        XCTAssertFalse(detector.observe(level: 0, duration: 3.4))
        XCTAssertTrue(detector.observe(level: 0, duration: 0.2))
    }

    func testSpeechEndpointSettingsClampInvalidValues() {
        XCTAssertEqual(VoiceEndpointSettings.pauseRange, 2...8)
        XCTAssertEqual(VoiceEndpointSettings.maximumRange, 30...180)
        XCTAssertEqual(VoiceEndpointSettings.defaultPause, 3.5)
        XCTAssertEqual(VoiceEndpointSettings.defaultMaximum, 90)
        XCTAssertEqual(VoiceEndpointSettings.safePause(.nan), 3.5)
        XCTAssertEqual(VoiceEndpointSettings.safePause(0.1), 2)
        XCTAssertEqual(VoiceEndpointSettings.safePause(99), 8)
        XCTAssertEqual(VoiceEndpointSettings.safeMaximum(.infinity), 90)
        XCTAssertEqual(VoiceEndpointSettings.safeMaximum(1), 30)
        XCTAssertEqual(VoiceEndpointSettings.safeMaximum(500), 180)
    }

    func testSpeechErrorMessageDoesNotLeakTranscriptOrUnknownDomain() {
        let known = NSError(domain: "kAFAssistantErrorDomain", code: 1101,
                            userInfo: [NSLocalizedDescriptionKey: "PRIVATE-TRANSCRIPT"])
        let message = SpeechFailure.safeMessage(known)
        XCTAssertTrue(message.contains("kAFAssistantErrorDomain"))
        XCTAssertTrue(message.contains("1101"))
        XCTAssertFalse(message.contains("PRIVATE-TRANSCRIPT"))
        let unknown = NSError(domain: "PRIVATE-DOMAIN", code: 17, userInfo: nil)
        XCTAssertFalse(SpeechFailure.safeMessage(unknown).contains("PRIVATE-DOMAIN"))
    }

    func testPartialUpdatesDoNotEndRecordingAndFailureNeverAutoSubmits() async {
        let backend = FakeVoiceBackend(); let voice = VoiceCoordinator(backend: backend)
        var sent: [String] = []
        await voice.start(autoSubmit: { sent.append($0) })
        backend.handler?("第一部分")
        XCTAssertTrue(voice.isRecording)
        backend.handler?("第一部分第二部分")
        XCTAssertTrue(voice.isRecording)
        backend.silenceHandler?()
        let staleFinal = backend.finishHandler
        backend.failureHandler?("识别中断")
        staleFinal?(true)
        XCTAssertEqual(voice.transcript, "第一部分第二部分")
        XCTAssertTrue(voice.needsConfirmation)
        XCTAssertTrue(sent.isEmpty)
        XCTAssertFalse(voice.isRecording)
    }

    func testSimultaneousFinalAndErrorIsFailureNotSuccess() async {
        let done = expectation(description: "error delivered")
        var text = ""
        var finalized = false
        let events = RecognitionEvents(onText: { text = $0 }, onFailure: { _ in done.fulfill() }, onFinish: { _ in finalized = true })
        events.submit(text: "保留的转写", failed: true, finished: true)
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(text, "保留的转写")
        XCTAssertFalse(finalized, "An error must never be treated as a successful final result")
    }

    func testLowVolumeAndContinuousNoiseDoNotAutoFinish() {
        var quiet = SpeechPauseDetector(pauseDuration: 3.5)
        XCTAssertFalse(quiet.observe(level: 0.005, duration: 2))
        XCTAssertFalse(quiet.observe(level: 0, duration: 5))
        var noise = SpeechPauseDetector(pauseDuration: 3.5)
        for _ in 0..<200 { XCTAssertFalse(noise.observe(level: 0.03, duration: 0.1)) }
    }
    func testVoiceEndpointClampsCorruptPersistedSettings() {
        XCTAssertEqual(VoiceEndpointSettings.safePause(.nan), 3.5)
        XCTAssertEqual(VoiceEndpointSettings.safePause(.infinity), 3.5)
        XCTAssertEqual(VoiceEndpointSettings.safePause(-1), 2)
        XCTAssertEqual(VoiceEndpointSettings.safePause(9), 8)
        XCTAssertEqual(VoiceEndpointSettings.safeMaximum(.nan), 90)
        XCTAssertEqual(VoiceEndpointSettings.safeMaximum(-.infinity), 90)
        XCTAssertEqual(VoiceEndpointSettings.safeMaximum(1), 30)
        XCTAssertEqual(VoiceEndpointSettings.safeMaximum(999), 180)
        XCTAssertEqual(VoiceEndpointSettings.safeMaximum(75), 75)
    }

    func testInterfaceStatusDoesNotMislabelRunningTaskAsThinking() {
        XCTAssertEqual(VoiceInterfaceStatus.label(recording: false, running: true, speaking: false), "任务进行中")
        XCTAssertEqual(VoiceInterfaceStatus.label(recording: true, running: false, speaking: false), "聆听中")
    }

    func testDelayedCreateAfterCancellationCancelsCreatedTask() async throws {
        let started = expectation(description: "task creation started")
        let deferred = DeferredTaskCreation(onStart: { started.fulfill() })
        let lifecycle = VoiceRunLifecycle()
        let old = lifecycle.begin()
        let pending = Task {
            try await CancellableTaskCreation.run(create: { await deferred.create() }, cancel: { await deferred.cancel($0) })
        }
        await fulfillment(of: [started], timeout: 3)
        guard await deferred.isWaiting else { pending.cancel(); return XCTFail("create did not begin") }
        pending.cancel()
        lifecycle.invalidate()
        _ = lifecycle.begin() // A new session has an empty draft.
        var currentDraft = ""
        let id = UUID()
        await deferred.finish(id)
        do { _ = try await pending.value; XCTFail("cancelled creation must not return a task") }
        catch is CancellationError {
            if lifecycle.mayRestore(token: old, visible: true, currentDraft: currentDraft) { currentDraft = "旧任务" }
        }
        catch { XCTFail("unexpected error: \(error)") }
        let cancelled = await deferred.cancelled
        XCTAssertEqual(cancelled, [id])
        XCTAssertEqual(currentDraft, "", "A delayed old cancellation restored an old goal into the new session")
    }
    func testClearingVoiceDraftResetsOriginBeforeTypingAgain() {
        var origin = VoiceInputOrigin(containsVoice: true, restoredID: "old")
        origin.applyEdit("")
        origin.applyEdit("纯文字")
        XCTAssertFalse(origin.containsVoice)
        XCTAssertNil(origin.restoredID)
    }

    func testFailedVoiceDraftsRemainRecoverableWithoutBlockingNewTurn() {
        var recovery = VoiceFailedDrafts()
        recovery.save("第一句")
        recovery.save("第二句")
        XCTAssertEqual(recovery.items, ["第一句", "第二句"])
        XCTAssertNil(recovery.takeIfDraftEmpty("正在编辑"))
        XCTAssertEqual(recovery.items.count, 2)
        XCTAssertEqual(recovery.takeIfDraftEmpty(""), "第一句")
        XCTAssertEqual(recovery.items, ["第二句"])
    }

    func testDelayedOldRunCannotRestoreIntoNewRunOrClosedWindow() {
        let lifecycle = VoiceRunLifecycle()
        let old = lifecycle.begin()
        XCTAssertTrue(lifecycle.mayRestore(token: old, visible: true, currentDraft: ""))
        XCTAssertFalse(lifecycle.mayRestore(token: old, visible: false, currentDraft: ""))
        XCTAssertFalse(lifecycle.mayRestore(token: old, visible: true, currentDraft: "新草稿"))
        lifecycle.invalidate()
        let next = lifecycle.begin()
        XCTAssertFalse(lifecycle.mayRestore(token: old, visible: true, currentDraft: ""))
        XCTAssertTrue(lifecycle.mayRestore(token: next, visible: true, currentDraft: ""))
    }

    func testManualRunKeepsExplicitlyStartedConversation() {
        let conversation = VoiceConversationSession()
        XCTAssertNil(conversation.manualRunToken)
        let token = conversation.begin()
        XCTAssertEqual(conversation.manualRunToken, token)
        conversation.stop()
        XCTAssertNil(conversation.manualRunToken)
    }
    func testConversationResumesOnlyWhenActiveVisibleAndDraftEmpty() {
        let session = VoiceConversationSession()
        let token = session.begin()
        XCTAssertTrue(session.mayResume(token: token, visible: true, serviceAvailable: true, isRunning: false, draft: "", voiceBusy: false))
        XCTAssertFalse(session.mayResume(token: token, visible: false, serviceAvailable: true, isRunning: false, draft: "", voiceBusy: false))
        XCTAssertFalse(session.mayResume(token: token, visible: true, serviceAvailable: true, isRunning: false, draft: "未提交草稿", voiceBusy: false))
        XCTAssertFalse(session.mayResume(token: token, visible: true, serviceAvailable: true, isRunning: true, draft: "", voiceBusy: false))
        session.stop()
        XCTAssertFalse(session.mayResume(token: token, visible: true, serviceAvailable: true, isRunning: false, draft: "", voiceBusy: false))
        _ = session.begin()
        XCTAssertFalse(session.mayResume(token: token, visible: true, serviceAvailable: true, isRunning: false, draft: "", voiceBusy: false))
    }

    func testConversationHistoryIsBoundedAndClearedOnStop() {
        let session = VoiceConversationSession()
        let token = session.begin()
        for index in 0..<7 { session.record(user: "问\(index)", answer: "答\(index)", token: token) }
        XCTAssertEqual(session.history.count, 10)
        XCTAssertEqual(session.history.first?.content, "问2")
        session.stop()
        XCTAssertTrue(session.history.isEmpty)
        _ = session.begin()
        session.record(user: "旧", answer: "旧", token: token)
        XCTAssertTrue(session.history.isEmpty)
    }

    func testTwoTurnsUseSessionHistoryAndNewConversationDoesNot() async throws {
        let provider = ConversationTestProvider()
        let agent = AgentSession(provider: provider, runner: ConversationTestRunner(),
                                 approvalWaiter: ConversationTestWaiter(), taskID: UUID())
        let conversation = VoiceConversationSession()
        let token = conversation.begin()
        let first = try await agent.run(goal: "我叫小明", history: conversation.history)
        guard case .completed(let answer) = first else { return XCTFail("first turn did not complete") }
        conversation.record(user: "我叫小明", answer: answer, token: token)
        _ = try await agent.run(goal: "我叫什么？", history: conversation.history)
        conversation.stop()
        _ = conversation.begin()
        _ = try await agent.run(goal: "新的问题", history: conversation.history)
        let calls = await provider.requests
        XCTAssertEqual(Array(calls[1].map(\.content).suffix(3)), ["我叫小明", "回答1", "我叫什么？"])
        XCTAssertFalse(calls[2].contains { $0.content == "我叫小明" || $0.content == "回答1" })
    }

    func testPlaybackCompletionReopensOnlyCurrentActiveSession() {
        let session = VoiceConversationSession()
        let token = session.begin()
        var reopened = 0
        session.playbackFinished(completed: true, token: token, visible: true, serviceAvailable: true,
                                 isRunning: false, draft: "", voiceBusy: false) { reopened += 1 }
        XCTAssertEqual(reopened, 1)
        session.stop()
        session.playbackFinished(completed: true, token: token, visible: true, serviceAvailable: true,
                                 isRunning: false, draft: "", voiceBusy: false) { reopened += 1 }
        XCTAssertEqual(reopened, 1)
        let next = session.begin()
        session.playbackFinished(completed: false, token: next, visible: true, serviceAvailable: true,
                                 isRunning: false, draft: "", voiceBusy: false) { reopened += 1 }
        XCTAssertEqual(reopened, 1)
        XCTAssertFalse(session.isActive)
    }

    func testCancelledSpeechDoesNotSignalNaturalCompletion() {
        let speaker = FakeSpeaker(); let voice = VoiceCoordinator(backend: FakeVoiceBackend(), speaker: speaker)
        var natural = false
        voice.speak("回答") { completed in natural = completed }
        speaker.completion?(false)
        XCTAssertFalse(natural)
        XCTAssertFalse(voice.isSpeaking)
    }

    func testSpeechCompletionCannotResumeTwice() {
        let speaker = FakeSpeaker(); let voice = VoiceCoordinator(backend: FakeVoiceBackend(), speaker: speaker)
        var completions = 0
        voice.speak("回答") { finished in if finished { completions += 1 } }
        let callback = speaker.completion
        callback?(true); callback?(true)
        XCTAssertEqual(completions, 1)
    }

    func testVoicePreferenceFallsBackWhenVoiceIsUnavailableAndClampsRate() {
        XCTAssertEqual(VoicePlaybackSettings.availableIdentifier("installed", in: ["installed"]), "installed")
        XCTAssertNil(VoicePlaybackSettings.availableIdentifier("missing", in: ["installed"]))
        XCTAssertNil(VoicePlaybackSettings.availableIdentifier("", in: ["installed"]))
        XCTAssertEqual(VoicePlaybackSettings.safeRate(0.5), 0.5, accuracy: 0.0001)
        XCTAssertEqual(VoicePlaybackSettings.safeRate(100), 0.6, accuracy: 0.0001)
        XCTAssertEqual(VoicePlaybackSettings.safeRate(.nan), 0.5, accuracy: 0.0001)
    }

    func testPermissionRequestOnlyRunsForUndeterminedState() async {
        var requests = 0
        let request: @MainActor () async -> Bool = { requests += 1; return true }
        let granted = await VoicePermissionPolicy.resolve(.granted, request: request)
        let denied = await VoicePermissionPolicy.resolve(.denied, request: request)
        XCTAssertTrue(granted)
        XCTAssertFalse(denied)
        XCTAssertEqual(requests, 0)
        let determined = await VoicePermissionPolicy.resolve(.undetermined, request: request)
        XCTAssertTrue(determined)
        XCTAssertEqual(requests, 1)
    }
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
        let submitted = expectation(description: "new countdown completed")
        gate.schedule("旧") { sent.append($0) }
        try await Task.sleep(for: .milliseconds(25))
        gate.schedule("新") { sent.append($0); submitted.fulfill() }
        await fulfillment(of: [submitted], timeout: 3)
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
        oldCompletion?(true)
        XCTAssertTrue(voice.isSpeaking)
        speaker.completion?(true)
        XCTAssertFalse(voice.isSpeaking)
    }
    func testSilenceDetectorRequiresSpeechBeforePauseAndFiresOnce() {
        var detector = SpeechPauseDetector(pauseDuration: 1.5)
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
        let timedOut = expectation(description: "recording timeout requests finalization")
        backend.onFinish = { timedOut.fulfill() }
        var sent: [String] = []
        await voice.start(autoSubmit: { sent.append($0) })
        backend.handler?("测试")
        await fulfillment(of: [timedOut], timeout: 2)
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
        let monitor = AudioPauseMonitor(pauseDuration: 1.5, onSilence: { paused.fulfill() })
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
        let monitor = AudioPauseMonitor(pauseDuration: 1.5, onSilence: { paused.fulfill() })
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
        let monitor = AudioPauseMonitor(pauseDuration: 1.5, onSilence: { paused.fulfill() })
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

extension VoiceCoordinatorTests {
    func testDiagnosticsAreIsolatedPerMonitorAndCleared() {
        let first = AudioPauseMonitor(onSilence: {})
        let second = AudioPauseMonitor(onSilence: {})
        first.setDiagnosticsEnabled(true)
        second.setDiagnosticsEnabled(true)
        first.recordDiagnostic(formatSupported: true, aboveThreshold: true, duration: 0.5)
        first.recordDiagnostic(formatSupported: true, aboveThreshold: false, duration: 0.25)
        XCTAssertEqual(first.diagnosticSnapshot().silenceSeconds, 0.25, accuracy: 0.001)
        XCTAssertEqual(second.diagnosticSnapshot().silenceSeconds, 0, accuracy: 0.001)
        first.clearDiagnostics()
        XCTAssertNil(first.diagnosticSnapshot().formatSupported)
    }
}

extension VoiceCoordinatorTests {
    func testConcurrentDiagnosticSnapshotsRemainSessionLocal() {
        let first = AudioPauseMonitor(onSilence: {})
        let second = AudioPauseMonitor(onSilence: {})
        first.setDiagnosticsEnabled(true)
        second.setDiagnosticsEnabled(true)
        DispatchQueue.concurrentPerform(iterations: 1000) { index in
            let monitor = index.isMultiple(of: 2) ? first : second
            monitor.recordDiagnostic(formatSupported: true, aboveThreshold: index.isMultiple(of: 2), duration: 0.01)
            _ = monitor.diagnosticSnapshot()
        }
        XCTAssertEqual(first.diagnosticSnapshot().aboveThreshold, true)
        XCTAssertEqual(second.diagnosticSnapshot().aboveThreshold, false)
        XCTAssertEqual(first.diagnosticSnapshot().silenceSeconds, 0, accuracy: 0.001)
        XCTAssertEqual(second.diagnosticSnapshot().silenceSeconds, 5, accuracy: 0.001)
    }
}

extension VoiceCoordinatorTests {
    func testDiagnosticReasonsDistinguishManualFinishAndSilence() async {
        let manualBackend = FakeVoiceBackend()
        let manual = VoiceCoordinator(backend: manualBackend)
        await manual.start()
        manual.finishRecording()
        manualBackend.finishHandler?(true)
        XCTAssertEqual(manual.diagnosticReason, "手动结束录音")

        let autoBackend = FakeVoiceBackend()
        let automatic = VoiceCoordinator(backend: autoBackend)
        await automatic.start()
        autoBackend.silenceHandler?()
        autoBackend.finishHandler?(true)
        XCTAssertEqual(automatic.diagnosticReason, "检测到停顿")

        let stoppedBackend = FakeVoiceBackend()
        let stopped = VoiceCoordinator(backend: stoppedBackend)
        await stopped.start()
        stopped.stop()
        XCTAssertEqual(stopped.diagnosticReason, "手动停止")
    }
}
