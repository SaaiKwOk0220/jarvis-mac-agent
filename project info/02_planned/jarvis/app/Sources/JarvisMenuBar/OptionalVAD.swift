import Foundation
@preconcurrency import AVFoundation
import CryptoKit
import Atomics
import OnnxRuntimeBindings

enum VADBuildAccess {
    #if JARVIS_VAD_EXPERIMENT
    static let experimentalBuild = true
    #else
    static let experimentalBuild = false
    #endif
    static func allowed(experimentalBuild: Bool, bundleID: String?, isolation: Bool) -> Bool {
        experimentalBuild && bundleID == "local.jarvis.vad-experiment" && isolation
    }
    static func validateStartup(experimentalBuild: Bool, bundleID: String?, isolation: Bool) throws {
        if experimentalBuild && !allowed(experimentalBuild: true, bundleID: bundleID, isolation: isolation) {
            throw VADSessionError.invalidIdentity
        }
    }
    static var currentAllowed: Bool {
        allowed(experimentalBuild: experimentalBuild, bundleID: Bundle.main.bundleIdentifier,
                isolation: Bundle.main.object(forInfoDictionaryKey: "JarvisExperimentalIsolation") as? Bool == true)
    }
}

/// Experimental model availability; never drives automatic execution.
enum OptionalVADAvailability: Equatable {
    case disabled, fallback, available
    static var bundledModelURL: URL? {
        if let path = Bundle.main.resourceURL?.appendingPathComponent("Jarvis_JarvisMenuBar.bundle"),
           let bundle = Bundle(url: path), let url = bundle.url(forResource: "silero-v6.2.3", withExtension: "onnx") { return url }
        if Bundle.main.bundleURL.pathExtension == "app" { return nil }
        return Bundle.module.url(forResource: "silero-v6.2.3", withExtension: "onnx")
    }
    static let expectedHash = "1a153a22f4509e292a94e67d6f9b85e8deb25b4988682b7e174c65279d8788e3"
    static func check(enabled: Bool, modelURL: URL?) -> Self {
        guard enabled else { return .disabled }
        guard let modelURL, let data = try? Data(contentsOf: modelURL),
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == expectedHash,
              let env = try? ORTEnv(loggingLevel: .warning),
              (try? ORTSession(env: env, modelPath: modelURL.path, sessionOptions: nil)) != nil else { return .fallback }
        return .available
    }
}

/// Bounded preallocated storage. Producer never waits for the consumer.
final class BoundedPCMQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Float]
    private var head = 0
    private var count = 0
    private let invalid = ManagedAtomic(false)
    init(capacity: Int) { precondition(capacity > 0); storage = Array(repeating: 0, count: capacity) }
    var failed: Bool { invalid.load(ordering: .acquiring) }
    @discardableResult func append(_ samples: [Float]) -> Bool {
        guard lock.try() else { invalid.store(true, ordering: .releasing); return false }
        defer { lock.unlock() }
        guard !failed, samples.count <= storage.count - count else { invalid.store(true, ordering: .releasing); return false }
        for sample in samples { storage[(head + count) % storage.count] = sample; count += 1 }
        return true
    }
    func take(maximum: Int) -> [Float]? {
        lock.lock(); defer { lock.unlock() }
        guard !failed, maximum > 0, count >= maximum else { return nil }
        let amount = min(maximum, count)
        var result = [Float](); result.reserveCapacity(amount)
        for _ in 0..<amount { result.append(storage[head]); head = (head + 1) % storage.count; count -= 1 }
        return result
    }
}

/// Testable background-only consumer. No result can trigger an agent action.
final class OfflineVADWorker: @unchecked Sendable {
    private let queue: BoundedPCMQueue
    private let frameSize: Int
    private let consumer: @Sendable ([Float]) throws -> Void
    private let executor = DispatchQueue(label: "jarvis.vad.offline")
    private let invalid = ManagedAtomic(false)
    private let lifecycle = NSLock()
    private var scheduled = false
    private var stopped = false
    private let afterSubmitLock: (@Sendable () -> Void)?
    private let beforeFinishLock: (@Sendable () -> Void)?
    init(capacity: Int, frameSize: Int, afterSubmitLock: (@Sendable () -> Void)? = nil, beforeFinishLock: (@Sendable () -> Void)? = nil, consumer: @escaping @Sendable ([Float]) throws -> Void) {
        precondition(frameSize > 0 && capacity >= frameSize)
        queue = BoundedPCMQueue(capacity: capacity); self.frameSize = frameSize; self.consumer = consumer; self.afterSubmitLock = afterSubmitLock; self.beforeFinishLock = beforeFinishLock
    }
    var failed: Bool { invalid.load(ordering: .acquiring) || queue.failed }
    func submit(_ samples: [Float]) -> Bool {
        guard lifecycle.try() else { invalid.store(true, ordering: .releasing); return false }
        defer { lifecycle.unlock() }
        afterSubmitLock?()
        guard !stopped, !failed, queue.append(samples) else { return false }
        if !scheduled { scheduled = true; executor.async { [self] in consume() } }
        return true
    }
    private func consume() {
        while true {
            lifecycle.lock()
            guard !failed, let samples = queue.take(maximum: frameSize) else {
                scheduled = false; lifecycle.unlock(); return
            }
            lifecycle.unlock()
            do { try consumer(samples) } catch { invalid.store(true, ordering: .releasing); return }
        }
    }
    func drain() async {
        await withCheckedContinuation { continuation in
            lifecycle.lock(); executor.async { continuation.resume() }; lifecycle.unlock()
        }
    }
    func finish() async {
        await withCheckedContinuation { continuation in
            beforeFinishLock?()
            lifecycle.lock(); stopped = true; executor.async { continuation.resume() }; lifecycle.unlock()
        }
    }
}

/// Isolated offline Silero inference. Call serially; never starts an agent task.
final class SileroOfflineInference {
    private let environment: ORTEnv
    private let session: ORTSession
    private var state: ORTValue
    private var context = [Float](repeating: 0, count: 64)
    init(modelURL: URL) throws {
        guard OptionalVADAvailability.check(enabled: true, modelURL: modelURL) == .available else { throw NSError(domain: "JarvisVAD", code: 1) }
        environment = try ORTEnv(loggingLevel: .warning)
        session = try ORTSession(env: environment, modelPath: modelURL.path, sessionOptions: nil)
        state = try Self.tensor([Float](repeating: 0, count: 256), .float, [2, 1, 128])
    }
    func probability(frame: [Float]) throws -> Float {
        guard frame.count == 512, frame.allSatisfy(\.isFinite) else { throw NSError(domain: "JarvisVAD", code: 2) }
        let input = try Self.tensor(context + frame, .float, [1, 576])
        let sampleRate = try Self.tensor([Int64(16000)], .int64, [])
        let result = try session.run(withInputs: ["input": input, "state": state, "sr": sampleRate], outputNames: ["output", "stateN"], runOptions: nil)
        guard let output = result["output"], let nextState = result["stateN"] else { throw NSError(domain: "JarvisVAD", code: 3) }
        let bytes = try output.tensorData() as Data
        guard bytes.count == MemoryLayout<Float>.size else { throw NSError(domain: "JarvisVAD", code: 4) }
        let probability = bytes.withUnsafeBytes { $0.loadUnaligned(as: Float.self) }
        guard probability.isFinite, (0...1).contains(probability) else { throw NSError(domain: "JarvisVAD", code: 5) }
        state = nextState
        context = Array(frame.suffix(64))
        return probability
    }
    private static func tensor<T>(_ values: [T], _ type: ORTTensorElementDataType, _ shape: [NSNumber]) throws -> ORTValue {
        let data = values.withUnsafeBytes { NSMutableData(bytes: $0.baseAddress!, length: $0.count) }
        return try ORTValue(tensorData: data, elementType: type, shape: shape)
    }
}

/// Serializes the converter's input request without capturing mutable local state.
private final class ConverterInput: @unchecked Sendable {
    private let lock = NSLock()
    private let buffer: AVAudioPCMBuffer
    private var supplied: Bool
    init(_ buffer: AVAudioPCMBuffer, supplied: Bool = false) { self.buffer = buffer; self.supplied = supplied }
    func next() -> AVAudioPCMBuffer? {
        lock.lock(); defer { lock.unlock() }
        guard !supplied else { return nil }
        supplied = true
        return buffer
    }
}

/// Offline-only conversion of one complete mono recording to 16 kHz.
enum OfflinePCMResampler {
    static func convert(_ samples: [Float], sourceRate: Double) throws -> [Float] {
        guard sourceRate.isFinite, sourceRate >= 16_000, sourceRate <= 192_000,
              !samples.isEmpty, samples.count <= 1_000_000, samples.allSatisfy(\.isFinite),
              let source = AVAudioFormat(standardFormatWithSampleRate: sourceRate, channels: 1),
              let target = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
              let converter = AVAudioConverter(from: source, to: target),
              let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw NSError(domain: "JarvisVAD", code: 6)
        }
        input.frameLength = AVAudioFrameCount(samples.count)
        guard let inputChannels = input.floatChannelData else { throw NSError(domain: "JarvisVAD", code: 7) }
        samples.withUnsafeBufferPointer { buffer in inputChannels[0].update(from: buffer.baseAddress!, count: samples.count) }
        let estimated = Int(ceil(Double(samples.count) * 16_000 / sourceRate)) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(estimated)) else { throw NSError(domain: "JarvisVAD", code: 8) }
        let feeder = ConverterInput(input)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            guard let chunk = feeder.next() else { state.pointee = .endOfStream; return nil }
            state.pointee = .haveData; return chunk
        }
        guard error == nil, status != .error, let channels = output.floatChannelData else { throw error ?? NSError(domain: "JarvisVAD", code: 9) }
        return Array(UnsafeBufferPointer(start: channels[0], count: Int(output.frameLength)))
    }
}

/// Serial, off-audio-thread streaming conversion; preserves converter state across chunks.
final class StreamingPCMResampler {
    private let source: AVAudioFormat
    private let target: AVAudioFormat
    private let converter: AVAudioConverter
    private var ended = false
    init(sourceRate: Double) throws {
        guard sourceRate.isFinite, (16_000...192_000).contains(sourceRate),
              let source = AVAudioFormat(standardFormatWithSampleRate: sourceRate, channels: 1),
              let target = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
              let converter = AVAudioConverter(from: source, to: target) else { throw NSError(domain: "JarvisVAD", code: 10) }
        converter.primeMethod = .none
        self.source = source; self.target = target; self.converter = converter
    }
    func convert(_ samples: [Float], final: Bool = false) throws -> [Float] {
        guard !ended, samples.count <= 1_000_000, samples.allSatisfy(\.isFinite) else { throw NSError(domain: "JarvisVAD", code: 11) }
        let capacity = max(samples.count, 1)
        guard let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(capacity)),
              let sourceData = input.floatChannelData else { throw NSError(domain: "JarvisVAD", code: 12) }
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { if let base = $0.baseAddress { sourceData[0].update(from: base, count: samples.count) } }
        let count = Int(ceil(Double(samples.count) * 16_000 / source.sampleRate)) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(count)) else { throw NSError(domain: "JarvisVAD", code: 13) }
        let feeder = ConverterInput(input, supplied: samples.isEmpty)
        var error: NSError?
        var converted = [Float]()
        for _ in 0..<8 {
            output.frameLength = 0
            let status = converter.convert(to: output, error: &error) { _, state in
                guard let chunk = feeder.next() else { state.pointee = final ? .endOfStream : .noDataNow; return nil }
                state.pointee = .haveData; return chunk
            }
            guard status != .error, error == nil, let channels = output.floatChannelData else { throw error ?? NSError(domain: "JarvisVAD", code: 14) }
            converted.append(contentsOf: UnsafeBufferPointer(start: channels[0], count: Int(output.frameLength)))
            if status == .endOfStream { ended = true; return converted }
            if !final || output.frameLength == 0 { break }
        }
        if final { throw NSError(domain: "JarvisVAD", code: 15) }
        return converted
    }
}

/// Preallocated single-producer/single-consumer float ring; callers must enforce one producer and consumer.
final class RealtimePCMBuffer: @unchecked Sendable {
    private let capacity: Int
    private let storage: UnsafeMutablePointer<Float>
    private let writeIndex = ManagedAtomic<UInt64>(0)
    private let readIndex = ManagedAtomic<UInt64>(0)
    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
        storage = .allocate(capacity: capacity)
        storage.initialize(repeating: 0, count: capacity)
    }
    deinit { storage.deinitialize(count: capacity); storage.deallocate() }
    /// Producer only. Never blocks or partially writes on overflow.
    func write(_ input: UnsafeBufferPointer<Float>) -> Bool {
        let head = writeIndex.load(ordering: .relaxed)
        let tail = readIndex.load(ordering: .acquiring)
        let used = head &- tail
        guard used <= UInt64(capacity), UInt64(input.count) <= UInt64(capacity) - used else { return false }
        for index in 0..<input.count { storage[Int((head &+ UInt64(index)) % UInt64(capacity))] = input[index] }
        writeIndex.store(head &+ UInt64(input.count), ordering: .releasing)
        return true
    }
    /// Copies Float32 channels in frame-major order; no allocation or partial write.
    func writePCM(_ buffer: AVAudioPCMBuffer) -> Bool {
        let channels = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)
        guard buffer.format.commonFormat == .pcmFormatFloat32, (1...8).contains(channels),
              frames > 0, frames <= capacity / channels, buffer.stride > 0,
              let input = buffer.floatChannelData else { return false }
        let count = frames * channels
        let head = writeIndex.load(ordering: .relaxed)
        let tail = readIndex.load(ordering: .acquiring)
        let used = head &- tail
        guard used <= UInt64(capacity), UInt64(count) <= UInt64(capacity) - used else { return false }
        for frame in 0..<frames {
            for channel in 0..<channels {
                let offset = frame * channels + channel
                storage[Int((head &+ UInt64(offset)) % UInt64(capacity))] = input[channel][frame * Int(buffer.stride)]
            }
        }
        writeIndex.store(head &+ UInt64(count), ordering: .releasing)
        return true
    }
    /// Consumer only. Returns the number copied into the caller's buffer.
    func read(into output: UnsafeMutableBufferPointer<Float>) -> Int {
        let tail = readIndex.load(ordering: .relaxed)
        let head = writeIndex.load(ordering: .acquiring)
        let available = min(head &- tail, UInt64(capacity))
        let count = min(Int(available), output.count)
        for index in 0..<count { output[index] = storage[Int((tail &+ UInt64(index)) % UInt64(capacity))] }
        readIndex.store(tail &+ UInt64(count), ordering: .releasing)
        return count
    }
}

/// Converts complete interleaved frames on a background worker.
enum VADDownmix {
    static func mono(_ samples: [Float], channels: Int) throws -> [Float] {
        guard (1...8).contains(channels), samples.count % channels == 0,
              samples.allSatisfy(\.isFinite) else { throw NSError(domain: "JarvisVAD", code: 16) }
        var output = [Float](); output.reserveCapacity(samples.count / channels)
        for frame in stride(from: 0, to: samples.count, by: channels) {
            var sum = 0.0
            for channel in 0..<channels { sum += Double(samples[frame + channel]) }
            let value = Float(sum / Double(channels))
            guard value.isFinite else { throw NSError(domain: "JarvisVAD", code: 17) }
            output.append(value)
        }
        return output
    }
}

/// Tracks complete tap callbacks without blocking the audio thread.
final class VADTapDrainGate: @unchecked Sendable {
    private let state = ManagedAtomic<UInt64>(0)
    private let closed: UInt64 = 1 << 63
    func enter() -> Bool {
        while true {
            let value = state.load(ordering: .acquiring)
            guard value & closed == 0, value < closed - 1 else { return false }
            if state.compareExchange(expected: value, desired: value + 1, ordering: .acquiringAndReleasing).exchanged { return true }
        }
    }
    func leave() { _ = state.wrappingDecrementThenLoad(ordering: .acquiringAndReleasing) }
    func close() {
        while true {
            let value = state.load(ordering: .acquiring)
            if value & closed != 0 { return }
            if state.compareExchange(expected: value, desired: value | closed, ordering: .acquiringAndReleasing).exchanged { return }
        }
    }
    var isDrained: Bool { state.load(ordering: .acquiring) == closed }
}

/// Exactly one terminal reason wins; all endpoint outcomes require manual confirmation.
final class VADTerminalState: @unchecked Sendable {
    private let state = ManagedAtomic<Int>(0)
    func fail() -> Bool {
        while true {
            let current = state.load(ordering: .acquiring)
            guard current == 0 || current == 2 else { return false }
            if state.compareExchange(expected: current, desired: 1, ordering: .acquiringAndReleasing).exchanged { return true }
        }
    }
    func endpoint() -> Bool { state.compareExchange(expected: 0, desired: 2, ordering: .acquiringAndReleasing).exchanged }
    func confirmEndpoint() -> Bool { state.compareExchange(expected: 2, desired: 4, ordering: .acquiringAndReleasing).exchanged }
    func stop() { _ = state.exchange(3, ordering: .acquiringAndReleasing) }
}

enum VADSessionError: LocalizedError {
    case busy, invalidIdentity
    var errorDescription: String? {
        switch self {
        case .busy: return "上一次语音检测仍在结束，请稍后重试，或关闭实验性检测。"
        case .invalidIdentity: return "实验性语音检测身份或数据隔离配置无效，请使用隔离实验包。"
        }
    }
}

/// Held until the last worker reference has exited, not merely until stop is requested.
private final class VADSessionPermit {
    private static let busy = ManagedAtomic(false)
    private var acquired = false
    init() throws {
        guard Self.busy.compareExchange(expected: false, desired: true, ordering: .acquiringAndReleasing).exchanged else { throw VADSessionError.busy }
        acquired = true
    }
    deinit { if acquired { Self.busy.store(false, ordering: .releasing) } }
}

/// Optional VAD runs off the tap; any loss or unsupported format fails closed.
final class OptionalLiveVAD: @unchecked Sendable {
    private static let initializationBusy = ManagedAtomic(false)
    private let permit: VADSessionPermit
    private let queue: RealtimePCMBuffer
    private let channelCount: Int
    private let sampleRate: Double
    private let worker = DispatchQueue(label: "jarvis.vad.live", qos: .userInitiated)
    private let invalid = ManagedAtomic(false)
    private let failureCode = ManagedAtomic<Int>(0)
    private let terminal = VADTerminalState()
    private let active = ManagedAtomic(true)
    private let producerBusy = ManagedAtomic(false)
    private let acceptedFrames = ManagedAtomic<Int>(0)
    private let consumedFrames = ManagedAtomic<Int>(0)
    var testFrameCounts: (accepted: Int, consumed: Int) {
        (acceptedFrames.load(ordering: .acquiring), consumedFrames.load(ordering: .acquiring))
    }
    private let onProducerAcquired: (@Sendable () -> Void)?
    private let beforeInitialize: (@Sendable () -> Void)?
    private let beforeInference: (@Sendable () -> Void)?
    private let onFailure: @MainActor @Sendable (String) -> Void
    private let onSilence: @MainActor @Sendable () -> Void
    private var converter: StreamingPCMResampler?
    private var model: SileroOfflineInference?
    private let modelURL: URL
    private var timer: DispatchSourceTimer?
    private var pending = [Float]()
    private var detector: SpeechPauseDetector
    init(format: AVAudioFormat, modelURL: URL, pause: Double,
         onProducerAcquired: (@Sendable () -> Void)? = nil,
         beforeInitialize: (@Sendable () -> Void)? = nil,
         beforeInference: (@Sendable () -> Void)? = nil,
         onFailure: @escaping @MainActor @Sendable (String) -> Void,
         onSilence: @escaping @MainActor @Sendable () -> Void) throws {
        guard format.commonFormat == .pcmFormatFloat32, (1...8).contains(Int(format.channelCount)),
              format.sampleRate.isFinite, (16_000...192_000).contains(format.sampleRate) else { throw NSError(domain: "JarvisVAD", code: 20) }
        permit = try VADSessionPermit()
        channelCount = Int(format.channelCount); sampleRate = format.sampleRate
        queue = RealtimePCMBuffer(capacity: Int(format.sampleRate) * channelCount * 2)
        self.modelURL = modelURL
        detector = SpeechPauseDetector(pauseDuration: pause)
        self.onProducerAcquired = onProducerAcquired; self.beforeInitialize = beforeInitialize; self.beforeInference = beforeInference
        self.onFailure = onFailure; self.onSilence = onSilence
    }
    func start() {
        let timer = DispatchSource.makeTimerSource(queue: worker)
        timer.schedule(deadline: .now(), repeating: .milliseconds(20))
        timer.setEventHandler { [weak self] in self?.consume() }
        self.timer = timer
        worker.async { [weak self] in
            guard let self, self.active.load(ordering: .acquiring) else { return }
            do {
                guard Self.initializationBusy.compareExchange(expected: false, desired: true, ordering: .acquiringAndReleasing).exchanged else { self.fail(); return }
                defer { Self.initializationBusy.store(false, ordering: .releasing) }
                self.beforeInitialize?()
                guard self.active.load(ordering: .acquiring) else { return }
                let converter = try StreamingPCMResampler(sourceRate: self.sampleRate)
                let model = try SileroOfflineInference(modelURL: self.modelURL)
                guard self.active.load(ordering: .acquiring) else { return }
                self.converter = converter; self.model = model
            } catch { self.fail() }
        }
        timer.resume()
    }
    /// Called by one audio producer. Copies only; never waits or schedules work.
    func submit(_ buffer: AVAudioPCMBuffer) {
        guard active.load(ordering: .acquiring) else { return }
        guard producerBusy.compareExchange(expected: false, desired: true, ordering: .acquiringAndReleasing).exchanged else {
            markInvalid(code: 1); return
        }
        defer { producerBusy.store(false, ordering: .releasing) }
        onProducerAcquired?()
        guard Int(buffer.format.channelCount) == channelCount, buffer.format.sampleRate == sampleRate,
              buffer.format.commonFormat == .pcmFormatFloat32 else { markInvalid(code: 2); return }
        guard queue.writePCM(buffer) else { markInvalid(code: 1); return }
        _ = acceptedFrames.wrappingIncrementThenLoad(by: Int(buffer.frameLength), ordering: .relaxed)
    }
    func signalLoss() { if active.load(ordering: .acquiring) { markInvalid(code: 1) } }
    private func markInvalid(code: Int) {
        if terminal.fail() {
            failureCode.store(code, ordering: .releasing)
            invalid.store(true, ordering: .releasing)
        }
    }
    func stop() { terminal.stop(); active.store(false, ordering: .releasing); timer?.cancel(); timer = nil }
    private func consume() {
        guard active.load(ordering: .acquiring) else { return }
        guard !invalid.load(ordering: .acquiring) else { fail(); return }
        guard let converter, let model else { return }
        let framesPerTick = Int(ceil(sampleRate * 0.04))
        var raw = [Float](repeating: 0, count: framesPerTick * channelCount)
        let count = raw.withUnsafeMutableBufferPointer { queue.read(into: $0) }
        guard count > 0 else { return }
        _ = consumedFrames.wrappingIncrementThenLoad(by: count / channelCount, ordering: .relaxed)
        do {
            guard count % channelCount == 0 else { throw NSError(domain: "JarvisVAD", code: 21) }
            let mono = try VADDownmix.mono(Array(raw.prefix(count)), channels: channelCount)
            pending += try converter.convert(mono)
            while pending.count >= 512 {
                let frame = Array(pending.prefix(512)); pending.removeFirst(512)
                beforeInference?()
                let probability = try model.probability(frame: frame)
                guard !invalid.load(ordering: .acquiring), active.load(ordering: .acquiring) else { fail(); return }
                if detector.observe(level: probability >= 0.5 ? 0.03 : 0, duration: 512.0 / 16000) {
                    guard terminal.endpoint() else { fail(); return }
                    active.store(false, ordering: .releasing)
                    DispatchQueue.main.async { [onSilence] in onSilence() }
                    return
                }
            }
        } catch { fail() }
    }
    private func fail() {
        guard active.exchange(false, ordering: .acquiringAndReleasing) else { return }
        let message: String
        switch failureCode.load(ordering: .acquiring) {
        case 1: message = "音频处理跟不上或输入丢失，请检查转写并手动发送；可关闭实验性检测后重试。"
        case 2: message = "麦克风格式发生变化或不受支持，请检查转写并手动发送；可关闭实验性检测后重试。"
        default: message = "语音检测模型或音频处理不可用，请检查转写并手动发送；可关闭实验性检测后重试。"
        }
        DispatchQueue.main.async { [onFailure] in onFailure(message) }
    }
}
