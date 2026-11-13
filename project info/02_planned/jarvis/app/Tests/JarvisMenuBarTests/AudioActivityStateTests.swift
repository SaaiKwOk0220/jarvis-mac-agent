import XCTest
@preconcurrency import AVFoundation
@testable import JarvisMenuBar

final class AudioActivityStateTests: XCTestCase {
    func testLossCountDistinguishesUnknownFromObservedZero() {
        XCTAssertEqual(AudioTapDiagnostics.lossLabel(nil), "未知")
        XCTAssertEqual(AudioTapDiagnostics.lossLabel(0), "0")
        XCTAssertEqual(AudioTapDiagnostics.lossLabel(3), "3")
    }
    func testTapReportsAcceptedAndRejectedBuffersSeparatelyPerSession() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8))
        buffer.frameLength = 8
        let first = AudioTapDiagnostics()
        let next = AudioTapDiagnostics()
        let gate = AudioRequestGate(append: { _ in }, end: {})
        let tap = SpeechCallbackBridge.tap(gate: gate, tapDiagnostics: first)
        tap(buffer, AVAudioTime(hostTime: 0))
        XCTAssertEqual(first.snapshot(now: DispatchTime.now().uptimeNanoseconds).buffers, 1)
        gate.finish()
        tap(buffer, AVAudioTime(hostTime: 0))
        XCTAssertEqual(first.snapshot(now: DispatchTime.now().uptimeNanoseconds).losses, 1)
        XCTAssertEqual(next.snapshot(now: DispatchTime.now().uptimeNanoseconds).buffers, 0)
    }
    func testSessionCountersAndFreshness() {
        let first = AudioTapDiagnostics()
        let second = AudioTapDiagnostics()
        first.accept(at: 100)
        XCTAssertEqual(first.snapshot(now: 120).buffers, 1)
        XCTAssertTrue(first.snapshot(now: 120).fresh)
        XCTAssertFalse(first.snapshot(now: 1_000_000_000).fresh)
        first.lost()
        XCTAssertFalse(first.snapshot(now: 120).fresh)
        XCTAssertEqual(second.snapshot(now: 120).buffers, 0)
    }
    func testMissingStaleLowLevelAndLossAreUnknown() {
        var state = AudioActivityState()
        XCTAssertEqual(state.status(now: 1), .unknown)
        state.observe(level: 0.001, at: 1)
        XCTAssertEqual(state.status(now: 1.1), .unknown)
        state.observe(level: 0.1, at: 2)
        XCTAssertEqual(state.status(now: 2.1), .active)
        XCTAssertEqual(state.status(now: 4), .unknown)
        state.observe(level: 0.1, at: 5)
        state.lost()
        XCTAssertEqual(state.status(now: 5.1), .unknown)
    }
}
