import XCTest
@preconcurrency import AVFoundation
@testable import JarvisMenuBar

// Optional local experiment, offline, on a Mac with the Eddy Mandarin voice installed:
// say -v 'Eddy (Chinese (China mainland))' -o /tmp/jarvis-vad-short.aiff '你好，这是中文语音测试。'
// say -v 'Eddy (Chinese (China mainland))' -o /tmp/jarvis-vad-long.aiff '你好，请帮我整理今天的工作计划。先检查项目进度，然后打开浏览器查找资料，最后把结果总结成一份清晰的报告。'
// JARVIS_SYNTH_SHORT=/tmp/jarvis-vad-short.aiff JARVIS_SYNTH_LONG=/tmp/jarvis-vad-long.aiff swift test --filter SileroSynthesizedSpeechTests
// Check `afinfo /tmp/jarvis-vad-short.aiff` and the long file: audio bytes and
// duration must be nonzero. `say` may exit successfully with zero frames when
// the Mac is locked or speech synthesis is sandboxed; unlock it and regenerate.
// This measures one synthetic voice, not real-world speech recognition accuracy.
final class SileroSynthesizedSpeechTests: XCTestCase {
    private func validInput(bytes: Int64, frames: Int64, sampleRate: Double, channels: UInt32) -> Bool {
        bytes > 0 && bytes <= 8_000_000 && frames > 0 && frames <= 1_000_000 &&
            sampleRate.isFinite && (16_000...192_000).contains(sampleRate) &&
            Double(frames) / sampleRate <= 30 && channels == 1
    }

    func testAudioInputBounds() {
        XCTAssertTrue(validInput(bytes: 100, frames: 22_050, sampleRate: 22_050, channels: 1))
        XCTAssertFalse(validInput(bytes: 4096, frames: 0, sampleRate: 22_050, channels: 1))
        XCTAssertFalse(validInput(bytes: 8_000_001, frames: 22_050, sampleRate: 22_050, channels: 1))
        XCTAssertFalse(validInput(bytes: 100, frames: 1_000_001, sampleRate: 48_000, channels: 1))
        XCTAssertFalse(validInput(bytes: 100, frames: 480_001, sampleRate: 16_000, channels: 1))
        XCTAssertFalse(validInput(bytes: 100, frames: 22_050, sampleRate: .nan, channels: 1))
        XCTAssertFalse(validInput(bytes: 100, frames: 22_050, sampleRate: 22_050, channels: 2))
    }

    func testOfflineSynthesizedMandarinWithNoiseAndTwoFreshSessions() throws {
        guard let shortPath = ProcessInfo.processInfo.environment["JARVIS_SYNTH_SHORT"],
              let longPath = ProcessInfo.processInfo.environment["JARVIS_SYNTH_LONG"] else {
            throw XCTSkip("Generate local Mandarin speech and set JARVIS_SYNTH_SHORT and JARVIS_SYNTH_LONG")
        }
        let modelURL = try XCTUnwrap(OptionalVADAvailability.bundledModelURL)
        func read(_ path: String) throws -> [Float] {
            let url = URL(fileURLWithPath: path)
            let metadata = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard metadata.isRegularFile == true, let bytes = metadata.fileSize, bytes > 0, bytes <= 8_000_000 else {
                throw NSError(domain: "SileroSynthesizedSpeechTests.invalidFile", code: 1)
            }
            let file = try AVAudioFile(forReading: url)
            guard file.length > 0 else {
                throw NSError(domain: "SileroSynthesizedSpeechTests.emptyAudio", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "Synthesized audio has zero frames; say can succeed while locked or sandboxed. Unlock the Mac, regenerate, and check audio bytes with afinfo."])
            }
            guard validInput(bytes: Int64(bytes), frames: file.length, sampleRate: file.processingFormat.sampleRate,
                             channels: file.processingFormat.channelCount) else {
                throw NSError(domain: "SileroSynthesizedSpeechTests.invalidFormat", code: 2)
            }
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
            try file.read(into: buffer)
            let channel = try XCTUnwrap(buffer.floatChannelData?[0])
            return try OfflinePCMResampler.convert(Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))), sourceRate: file.processingFormat.sampleRate)
        }
        let short = try read(shortPath), long = try read(longPath)
        XCTAssertGreaterThan(short.count, 16_000)
        XCTAssertGreaterThan(long.count, short.count)
        for (turn, speech) in [short, long].enumerated() {
            for noise in [Float(0), 0.02] {
                let model = try SileroOfflineInference(modelURL: modelURL)
                var detector = SpeechPauseDetector(pauseDuration: 3.5)
                // Deterministic low-level noise; no microphone or external data.
                var seed: UInt64 = 37
                func noiseSample() -> Float {
                    seed = seed &* 6364136223846793005 &+ 1
                    return (Float((seed >> 32) & 0xffff) / 32767.5 - 1) * noise
                }
                let gap = [Float](repeating: 0, count: 32_000)
                let end = [Float](repeating: 0, count: 64_000)
                let samples = speech + gap + speech + end
                var speechFrames = 0, detectedSpeechFrames = 0, firstEndpoint: Int?
                for start in stride(from: 0, to: samples.count - 511, by: 512) {
                    let frame = (0..<512).map { i in max(-1, min(1, samples[start + i] + noiseSample())) }
                    let probability = try model.probability(frame: frame)
                    if start < speech.count || (start >= speech.count + gap.count && start < 2 * speech.count + gap.count) {
                        speechFrames += 1
                        if probability >= 0.5 { detectedSpeechFrames += 1 }
                    }
                    if detector.observe(level: probability >= 0.5 ? 0.03 : 0, duration: 0.032), firstEndpoint == nil { firstEndpoint = start }
                }
                let fraction = Double(detectedSpeechFrames) / Double(speechFrames)
                print("SILERO_SYNTH turn=\(turn + 1) noise=\(noise) speech_fraction=\(fraction) endpoint=\(firstEndpoint.map { Double($0) / 16000 } ?? -1) second_speech_end=\(Double(2 * speech.count + gap.count) / 16000)")
                XCTAssertGreaterThan(fraction, 0, "Model must detect at least one synthesized speech frame")
                let endpoint = try XCTUnwrap(firstEndpoint, "Expected an endpoint after the final silence")
                XCTAssertGreaterThanOrEqual(endpoint, 2 * speech.count + gap.count, "Endpoint must not cut off the second utterance")
            }
        }
    }
}
