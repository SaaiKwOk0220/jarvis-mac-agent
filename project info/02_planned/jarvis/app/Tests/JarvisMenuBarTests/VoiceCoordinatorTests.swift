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

private final class PCMTestCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [[Float]] = []
    func append(_ frame: [Float]) { lock.lock(); defer { lock.unlock() }; stored.append(frame) }
    var frames: [[Float]] { lock.lock(); defer { lock.unlock() }; return stored }
}
@MainActor final class VoiceCoordinatorTests: XCTestCase {
    func testRealtimePCMBufferConcurrentProducerConsumer() async {
        let queue = RealtimePCMBuffer(capacity: 64)
        let producer = Task.detached {
            for index in 0..<10_000 {
                let value = [Float(index)]
                while !value.withUnsafeBufferPointer({ queue.write($0) }) { await Task.yield() }
            }
        }
        let consumer = Task.detached {
            var result = [Float]()
            var scratch = [Float](repeating: 0, count: 16)
            while result.count < 10_000 {
                let count = scratch.withUnsafeMutableBufferPointer { queue.read(into: $0) }
                if count == 0 { await Task.yield() } else { result.append(contentsOf: scratch.prefix(count)) }
            }
            return result
        }
        await producer.value
        let result = await consumer.value
        XCTAssertEqual(result, (0..<10_000).map(Float.init))
    }

    func testRealtimePCMBufferCopiesInterleavedStereoAndRejectsOverflow() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 2, interleaved: true))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2))
        buffer.frameLength = 2
        let channels = try XCTUnwrap(buffer.floatChannelData)
        channels[0][0] = 1; channels[0][2] = 2
        channels[1][0] = 3; channels[1][2] = 4
        let queue = RealtimePCMBuffer(capacity: 4)
        XCTAssertTrue(queue.writePCM(buffer))
        XCTAssertFalse(queue.writePCM(buffer))
        var output = [Float](repeating: 0, count: 4)
        XCTAssertEqual(output.withUnsafeMutableBufferPointer { queue.read(into: $0) }, 4)
        XCTAssertEqual(output, [1, 3, 2, 4])
    }

    func testVADDownmixPreservesFramesAndRejectsIncompleteInput() throws {
        XCTAssertEqual(try VADDownmix.mono([1, -1, 0.5, 0.5], channels: 2), [0, 0.5])
        XCTAssertEqual(try VADDownmix.mono([0.2, -0.3], channels: 1), [0.2, -0.3])
        XCTAssertThrowsError(try VADDownmix.mono([0, 1, 2], channels: 2))
        XCTAssertThrowsError(try VADDownmix.mono([Float.nan], channels: 1))
    }

    func testRealtimePCMBufferCopiesPlanarStereo() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2))
        buffer.frameLength = 2
        let channels = try XCTUnwrap(buffer.floatChannelData)
        channels[0][0] = 1; channels[0][1] = 2
        channels[1][0] = 3; channels[1][1] = 4
        let queue = RealtimePCMBuffer(capacity: 4)
        XCTAssertTrue(queue.writePCM(buffer))
        var output = [Float](repeating: 0, count: 4)
        XCTAssertEqual(output.withUnsafeMutableBufferPointer { queue.read(into: $0) }, 4)
        XCTAssertEqual(output, [1, 3, 2, 4])
    }

    func testRealtimePCMBufferPreservesOrderAndRejectsOverflow() {
        let queue = RealtimePCMBuffer(capacity: 4)
        XCTAssertTrue([Float(1), 2, 3].withUnsafeBufferPointer { queue.write($0) })
        XCTAssertFalse([Float(4), 5].withUnsafeBufferPointer { queue.write($0) })
        var first = [Float](repeating: 0, count: 2)
        XCTAssertEqual(first.withUnsafeMutableBufferPointer { queue.read(into: $0) }, 2)
        XCTAssertEqual(first, [1, 2])
        XCTAssertTrue([Float(4), 5].withUnsafeBufferPointer { queue.write($0) })
        var rest = [Float](repeating: 0, count: 4)
        XCTAssertEqual(rest.withUnsafeMutableBufferPointer { queue.read(into: $0) }, 3)
        XCTAssertEqual(Array(rest.prefix(3)), [3, 4, 5])
    }

    func testBoundedPCMQueueConcurrentOverflowIsTerminal() async {
        let queue = BoundedPCMQueue(capacity: 1)
        XCTAssertTrue(queue.append([1]))
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 { group.addTask { _ = queue.append([2]) } }
        }
        XCTAssertTrue(queue.failed)
        XCTAssertNil(queue.take(maximum: 1))
    }
    func testFinishWaitsForSubmissionAlreadyHoldingLifecycleLock() async {
        let entered = expectation(description: "submit entered critical section")
        let release = DispatchSemaphore(value: 0)
        let finishStarted = expectation(description: "finish attempts lifecycle lock")
        let values = PCMTestCollector()
        let worker = OfflineVADWorker(capacity: 4, frameSize: 2, afterSubmitLock: {
            entered.fulfill()
            release.wait()
        }, beforeFinishLock: { finishStarted.fulfill() }) { values.append($0) }
        let submit = Task.detached { worker.submit([1, 2]) }
        await fulfillment(of: [entered], timeout: 2)
        let finish = Task.detached { await worker.finish() }
        await fulfillment(of: [finishStarted], timeout: 2)
        release.signal()
        let accepted = await submit.value
        await finish.value
        XCTAssertTrue(accepted)
        XCTAssertEqual(values.frames, [[1, 2]])
    }

    func testConcurrentFinishNeverLosesAcceptedFrame() async {
        for _ in 0..<200 {
            let values = PCMTestCollector()
            let worker = OfflineVADWorker(capacity: 4, frameSize: 2) { values.append($0) }
            let submitted = Task.detached { worker.submit([1, 2]) }
            await worker.finish()
            let accepted = await submitted.value
            if accepted { XCTAssertEqual(values.frames, [[1, 2]]) }
        }
    }
    func testVADWorkerFinishWaitsForScheduledFrames() async {
        let values = PCMTestCollector()
        let worker = OfflineVADWorker(capacity: 16, frameSize: 2) { values.append($0) }
        XCTAssertTrue(worker.submit([1, 2, 3, 4]))
        await worker.finish()
        XCTAssertEqual(values.frames, [[1, 2], [3, 4]])
        XCTAssertFalse(worker.submit([5, 6]))
    }
    func testVADWorkerFinishDiscardsPartialAndRejectsMoreInput() async {
        let values = PCMTestCollector()
        let worker = OfflineVADWorker(capacity: 8, frameSize: 2) { values.append($0) }
        XCTAssertTrue(worker.submit([1]))
        await worker.finish()
        XCTAssertEqual(values.frames, [])
        XCTAssertFalse(worker.submit([2]))
    }
    func testVADWorkerBuffersIncompleteFrames() async {
        let values = PCMTestCollector()
        let worker = OfflineVADWorker(capacity: 8, frameSize: 2) { values.append($0) }
        XCTAssertTrue(worker.submit([1]))
        await worker.drain()
        XCTAssertEqual(values.frames, [])
        XCTAssertTrue(worker.submit([2, 3]))
        await worker.drain()
        XCTAssertEqual(values.frames, [[1, 2]])
    }
    func testVADWorkerFailureStopsConsumption() async {
        let worker = OfflineVADWorker(capacity: 8, frameSize: 2) { _ in throw NSError(domain: "test", code: 1) }
        XCTAssertTrue(worker.submit([1, 2]))
        await worker.drain()
        XCTAssertTrue(worker.failed)
        XCTAssertFalse(worker.submit([3, 4]))
    }
    func testBoundedPCMQueueFailsClosedOnOverflow() {
        let queue = BoundedPCMQueue(capacity: 3)
        XCTAssertTrue(queue.append([1, 2]))
        XCTAssertFalse(queue.append([3, 4]))
        XCTAssertTrue(queue.failed)
        XCTAssertNil(queue.take(maximum: 3))
    }
    func testBoundedPCMQueuePreservesOrderAcrossWrap() {
        let queue = BoundedPCMQueue(capacity: 3)
        XCTAssertTrue(queue.append([1, 2]))
        XCTAssertEqual(queue.take(maximum: 1), [1])
        XCTAssertTrue(queue.append([3, 4]))
        XCTAssertEqual(queue.take(maximum: 3), [2, 3, 4])
    }

    func testStreamingResamplerMatchesWholeSignal() throws {
        let source = (0..<48_000).map { Float(sin(Double($0) * 2 * .pi * 1_000 / 48_000)) }
        let whole = try StreamingPCMResampler(sourceRate: 48_000).convert(source, final: true)
        let stream = try StreamingPCMResampler(sourceRate: 48_000)
        var chunked = [Float]()
        for start in stride(from: 0, to: source.count, by: 4_800) {
            chunked += try stream.convert(Array(source[start..<min(start + 4_800, source.count)]))
        }
        chunked += try stream.convert([], final: true)
        XCTAssertEqual(chunked.count, whole.count)
        let difference = zip(chunked, whole).reduce(0.0) { $0 + Double(abs($1.0 - $1.1)) } / Double(max(whole.count, 1))
        XCTAssertLessThan(difference, 0.001)
    }

    func testStreamingResamplerPreservesLengthAcrossChunks() throws {
        let converter = try StreamingPCMResampler(sourceRate: 48_000)
        var result = [Float]()
        for _ in 0..<10 { result += try converter.convert(Array(repeating: 0, count: 4_800)) }
        result += try converter.convert([], final: true)
        XCTAssertEqual(result.count, 16_000, accuracy: 32)
        XCTAssertTrue(result.allSatisfy { $0.isFinite && abs($0) < 0.001 })
        XCTAssertThrowsError(try converter.convert([0]))
    }

    func testOfflineResamplerConverts48kHzSilence() throws {
        let result = try OfflinePCMResampler.convert(Array(repeating: 0, count: 48_000), sourceRate: 48_000)
        XCTAssertEqual(result.count, 16_000, accuracy: 32)
        XCTAssertTrue(result.allSatisfy { $0.isFinite && abs($0) < 0.001 })
        XCTAssertThrowsError(try OfflinePCMResampler.convert([0], sourceRate: 0))
    }

    func testVADTerminalFailureAndEndpointAreMutuallyExclusive() {
        let failureFirst = VADTerminalState()
        XCTAssertTrue(failureFirst.fail())
        XCTAssertFalse(failureFirst.endpoint())
        let endpointFirst = VADTerminalState()
        XCTAssertTrue(endpointFirst.endpoint())
        XCTAssertFalse(endpointFirst.fail())
    }

    func testLiveVADConcurrentProducerFailsClosed() async throws {
        let url = try XCTUnwrap(OptionalVADAvailability.bundledModelURL)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16))
        buffer.frameLength = 16
        let entered = expectation(description: "producer acquired")
        let failed = expectation(description: "concurrent producer fails")
        let release = DispatchSemaphore(value: 0)
        let vad = try OptionalLiveVAD(format: format, modelURL: url, pause: 2, onProducerAcquired: {
            entered.fulfill(); release.wait()
        }, onFailure: { _ in failed.fulfill() }, onSilence: {})
        vad.start()
        let first = Task.detached { vad.submit(buffer) }
        await fulfillment(of: [entered], timeout: 2)
        vad.submit(buffer)
        release.signal()
        await first.value
        await fulfillment(of: [failed], timeout: 3)
        vad.stop()
    }

    func testLiveVADHighRateContinuousInputForTenSeconds() async throws {
        let url = try XCTUnwrap(OptionalVADAvailability.bundledModelURL)
        for rate in [96_000.0, 192_000.0] {
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate * 0.02)))
            buffer.frameLength = buffer.frameCapacity
            let samples = try XCTUnwrap(buffer.floatChannelData)[0]
            for i in 0..<Int(buffer.frameLength) { samples[i] = Float(0.001 * sin(Double(i) * 2 * .pi * 1000 / rate)) }
            let failed = expectation(description: "continuous \(rate) has no overflow")
            failed.isInverted = true
            let premature = expectation(description: "no premature endpoint at \(rate)")
            premature.isInverted = true
            let vad = try OptionalLiveVAD(format: format, modelURL: url, pause: 8, onFailure: { _ in failed.fulfill() }, onSilence: { premature.fulfill() })
            vad.start()
            for _ in 0..<500 { vad.submit(buffer); try await Task.sleep(for: .milliseconds(20)) }
            try await Task.sleep(for: .milliseconds(300))
            let counts = vad.testFrameCounts
            XCTAssertEqual(counts.accepted, Int(buffer.frameLength) * 500)
            XCTAssertEqual(counts.consumed, counts.accepted)
            await fulfillment(of: [failed, premature], timeout: 0.1)
            vad.stop()
        }
    }

    func testLiveVADPermitHeldUntilBlockedWorkerExits() async throws {
        let url = try XCTUnwrap(OptionalVADAvailability.bundledModelURL)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let entered = expectation(description: "initialization held")
        let release = DispatchSemaphore(value: 0)
        var first: OptionalLiveVAD? = try OptionalLiveVAD(format: format, modelURL: url, pause: 2, beforeInitialize: { entered.fulfill(); release.wait() }, onFailure: { _ in }, onSilence: {})
        first?.start(); await fulfillment(of: [entered], timeout: 2)
        first?.stop(); first = nil
        for _ in 0..<10 {
            XCTAssertThrowsError(try OptionalLiveVAD(format: format, modelURL: url, pause: 2, onFailure: { _ in }, onSilence: {}))
        }
        release.signal()
        var retried: OptionalLiveVAD?
        for _ in 0..<100 {
            retried = try? OptionalLiveVAD(format: format, modelURL: url, pause: 2, onFailure: { _ in }, onSilence: {})
            if retried != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(retried)
        retried?.stop()
    }

    func testLiveVADSlowInferenceOverflowFailsClosed() async throws {
        let url = try XCTUnwrap(OptionalVADAvailability.bundledModelURL)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
        buffer.frameLength = buffer.frameCapacity
        let entered = expectation(description: "inference entered")
        let failed = expectation(description: "overflow fails")
        let silence = expectation(description: "no endpoint")
        silence.isInverted = true
        let release = DispatchSemaphore(value: 0)
        let vad = try OptionalLiveVAD(format: format, modelURL: url, pause: 2, beforeInference: { entered.fulfill(); release.wait() }, onFailure: { _ in failed.fulfill() }, onSilence: { silence.fulfill() })
        vad.start(); vad.submit(buffer)
        await fulfillment(of: [entered], timeout: 3)
        vad.submit(buffer); vad.submit(buffer); vad.submit(buffer)
        release.signal()
        await fulfillment(of: [failed, silence], timeout: 1)
        vad.stop()
    }

    func testLiveVADSlowInitializationOverflowFailsClosed() async throws {
        let url = try XCTUnwrap(OptionalVADAvailability.bundledModelURL)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
        buffer.frameLength = buffer.frameCapacity
        let entered = expectation(description: "initialization waiting")
        let failed = expectation(description: "overflow fails")
        let silence = expectation(description: "no silence")
        silence.isInverted = true
        let release = DispatchSemaphore(value: 0)
        let vad = try OptionalLiveVAD(format: format, modelURL: url, pause: 2, beforeInitialize: { entered.fulfill(); release.wait() }, onFailure: { _ in failed.fulfill() }, onSilence: { silence.fulfill() })
        vad.start()
        await fulfillment(of: [entered], timeout: 2)
        vad.submit(buffer); vad.submit(buffer); vad.submit(buffer)
        release.signal()
        await fulfillment(of: [failed, silence], timeout: 1)
        vad.stop()
    }

    func testLiveVADHandlesHighRateSilence() async throws {
        let url = try XCTUnwrap(OptionalVADAvailability.bundledModelURL)
        for rate in [96_000.0, 192_000.0] {
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate * 0.02)))
            buffer.frameLength = buffer.frameCapacity
            let failed = expectation(description: "no failure at \(rate)")
            failed.isInverted = true
            let vad = try OptionalLiveVAD(format: format, modelURL: url, pause: 2, onFailure: { _ in failed.fulfill() }, onSilence: {})
            vad.start()
            for _ in 0..<12 { vad.submit(buffer); try await Task.sleep(for: .milliseconds(20)) }
            await fulfillment(of: [failed], timeout: 0.2)
            vad.stop()
        }
    }

    func testLiveVADRejectsUnexpectedFormatWithoutSilence() throws {
        let url = try XCTUnwrap(OptionalVADAvailability.bundledModelURL)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let other = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: other, frameCapacity: 32))
        buffer.frameLength = 32
        let failed = expectation(description: "failure")
        let silence = expectation(description: "no silence")
        silence.isInverted = true
        let vad = try OptionalLiveVAD(format: format, modelURL: url, pause: 2, onFailure: { _ in failed.fulfill() }, onSilence: { silence.fulfill() })
        vad.start(); vad.submit(buffer)
        wait(for: [failed, silence], timeout: 0.3)
        vad.stop()
    }

    func testBundledVADModelIsValid() throws {
        let url = try XCTUnwrap(OptionalVADAvailability.bundledModelURL)
        XCTAssertEqual(OptionalVADAvailability.check(enabled: true, modelURL: url), .available)
        let model = try SileroOfflineInference(modelURL: url)
        XCTAssertTrue((0...1).contains(try model.probability(frame: Array(repeating: 0, count: 512))))
    }

    func testSileroModelProducesFiniteProbabilities() throws {
        guard let path = ProcessInfo.processInfo.environment["JARVIS_TEST_VAD_MODEL"] else {
            throw XCTSkip("Set JARVIS_TEST_VAD_MODEL to test the optional model")
        }
        let model = try SileroOfflineInference(modelURL: URL(fileURLWithPath: path))
        for _ in 0..<3 {
            let probability = try model.probability(frame: Array(repeating: 0, count: 512))
            XCTAssertTrue((0...1).contains(probability))
        }
        XCTAssertThrowsError(try model.probability(frame: [0]))
    }

    func testOptionalVADIsDisabledByDefaultAndFallsBackForMissingModel() {
        XCTAssertEqual(OptionalVADAvailability.check(enabled: false, modelURL: nil), .disabled)
        XCTAssertEqual(OptionalVADAvailability.check(enabled: true, modelURL: nil), .fallback)
    }

    func testSyntheticNoiseAndSlowSpeechExposeEnergyBaselineLimits() {
        func frame(_ value: Float, _ seconds: Int) -> VADFrame {
            VADFrame(samples: Array(repeating: value, count: 160 * seconds), sampleRate: 160)
        }
        let noise = VADEvaluator.evaluate([frame(0.03, 1), frame(0.02, 5)], using: EnergyVADCandidate(pauseDuration: 3.5))
        XCTAssertNil(noise.endpointSeconds)
        let slow = VADEvaluator.evaluate([frame(0.03, 1), frame(0, 4), frame(0.03, 1)], using: EnergyVADCandidate(pauseDuration: 3.5))
        XCTAssertEqual(slow.endpointSeconds, 5)
    }

    func testOfflineVADEvaluationReportsEndpointWithoutExecuting() {
        let frames = [VADFrame(samples: Array(repeating: 0.03, count: 8), sampleRate: 16), VADFrame(samples: Array(repeating: 0, count: 64), sampleRate: 16)]
        let report = VADEvaluator.evaluate(frames, using: EnergyVADCandidate(pauseDuration: 3.5))
        XCTAssertEqual(report.endpointSeconds, 4.5)
        XCTAssertEqual(report.framesProcessed, 2)
        let low = VADEvaluator.evaluate([VADFrame(samples: Array(repeating: 0.005, count: 16), sampleRate: 16), VADFrame(samples: Array(repeating: 0, count: 64), sampleRate: 16)], using: EnergyVADCandidate(pauseDuration: 3.5))
        XCTAssertNil(low.endpointSeconds)
    }

    func testStalePartialFallsBackWithoutSending() async throws {
        let backend = FakeVoiceBackend()
        let voice = VoiceCoordinator(backend: backend, stalePartialLimit: .milliseconds(40))
        var sent: [String] = []
        await voice.start(autoSubmit: { sent.append($0) })
        backend.handler?("第一句")
        try await Task.sleep(for: .milliseconds(25))
        backend.handler?("更新的第一句")
        try await Task.sleep(for: .milliseconds(25))
        XCTAssertTrue(voice.isRecording)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(voice.isFinishing)
        backend.finishHandler?(true)
        XCTAssertEqual(voice.transcript, "更新的第一句")
        XCTAssertTrue(sent.isEmpty)
        XCTAssertNotNil(voice.errorMessage)
    }

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

    func testTwoSuccessiveVoiceTurnsEachFinishOnSilence() async {
        let backend = FakeVoiceBackend(); let voice = VoiceCoordinator(backend: backend)
        var sent: [String] = []
        for text in ["第一句", "第二句"] {
            await voice.start(autoSubmit: { sent.append($0) })
            backend.handler?(text)
            backend.silenceHandler?()
            backend.finishHandler?(true)
        }
        XCTAssertEqual(sent, ["第一句", "第二句"])
    }

    func testInvalidExperimentalIdentityStopsBeforeStorageAccess() {
        for (identifier, marker) in [("local.jarvis.dev", true), ("local.jarvis.vad-experiment", false)] {
            var storageAccessed = false
            do {
                try VADBuildAccess.validateStartup(experimentalBuild: true, bundleID: identifier, isolation: marker)
                storageAccessed = true
            } catch { }
            XCTAssertFalse(storageAccessed)
        }
        XCTAssertNoThrow(try VADBuildAccess.validateStartup(experimentalBuild: false, bundleID: "local.jarvis.dev", isolation: false))
        XCTAssertNoThrow(try VADBuildAccess.validateStartup(experimentalBuild: true, bundleID: "local.jarvis.vad-experiment", isolation: true))
    }

    func testVADBuildAccessRequiresBuildFlagAndExactIsolatedIdentity() {
        XCTAssertFalse(VADBuildAccess.allowed(experimentalBuild: false, bundleID: "local.jarvis.vad-experiment", isolation: true))
        XCTAssertFalse(VADBuildAccess.allowed(experimentalBuild: true, bundleID: "local.jarvis.dev", isolation: true))
        XCTAssertFalse(VADBuildAccess.allowed(experimentalBuild: true, bundleID: "local.jarvis.vad-experiment", isolation: false))
        XCTAssertTrue(VADBuildAccess.allowed(experimentalBuild: true, bundleID: "local.jarvis.vad-experiment", isolation: true))
    }

    func testExperimentalAppUsesDistinctDataDirectory() {
        XCTAssertEqual(AppStorageScope.directory(experimental: false), "Jarvis")
        XCTAssertEqual(AppStorageScope.directory(experimental: true), "Jarvis-VAD-Experiment")
    }

    func testConfirmationOnlyEndpointPreservesPartialWithoutFailureOrAutoSubmit() async {
        let backend = FakeVoiceBackend(); let voice = VoiceCoordinator(backend: backend)
        var submissions = 0
        await voice.start(autoSubmit: { _ in submissions += 1 })
        backend.handler?("测试文字")
        backend.finishHandler?(false)
        XCTAssertTrue(voice.needsConfirmation)
        XCTAssertEqual(voice.transcript, "测试文字")
        XCTAssertNil(voice.errorMessage)
        XCTAssertEqual(submissions, 0)
    }

    func testOldFailureCannotStopNewRecording() async {
        let backend = FakeVoiceBackend(); let voice = VoiceCoordinator(backend: backend)
        await voice.start()
        let oldFailure = backend.failureHandler
        voice.stop()
        await voice.start()
        XCTAssertTrue(voice.isRecording)
        oldFailure?("旧会话错误")
        XCTAssertTrue(voice.isRecording)
        XCTAssertNil(voice.errorMessage)
        voice.stop()
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
