import Foundation
import CoreGraphics
import XCTest
@testable import JarvisMenuBar

private final class EnumerationCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: (@Sendable (Result<Int, Error>) -> Void)?
    func install(_ value: @escaping @Sendable (Result<Int, Error>) -> Void) { lock.lock(); completion = value; lock.unlock() }
    func finish(_ value: Int) { lock.lock(); let callback = completion; completion = nil; lock.unlock(); callback?(.success(value)) }
}

private final class CompletionCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

@MainActor
private final class FakeSafariWindowProvider: SafariWindowProviding {
    var snapshots: [[SafariWindowIdentity]]
    var captures = 0
    var cancelDuringCapture = false
    var returnedFrame = Data([1, 2, 3])
    init(_ snapshots: [[SafariWindowIdentity]]) { self.snapshots = snapshots }
    func windows() async throws -> [SafariWindowIdentity] { snapshots.removeFirst() }
    func capture(_ identity: SafariWindowIdentity) async throws -> Data {
        captures += 1
        if cancelDuringCapture { withUnsafeCurrentTask { $0?.cancel() } }
        return returnedFrame
    }
}

@MainActor
final class SafariWindowCaptureTests: XCTestCase {
    private let target = SafariWindowIdentity(bundleID: "com.apple.Safari", windowID: 42, pid: 17, launched: Date(timeIntervalSince1970: 1), title: "a")

    func testRejectsNonSafariAndAmbiguousWindows() {
        XCTAssertTrue(SafariCaptureSelection.matches(target, in: [target]))
        XCTAssertFalse(SafariCaptureSelection.matches(target, in: []))
        XCTAssertFalse(SafariCaptureSelection.matches(target, in: [target, target]))
        let duplicateID = SafariWindowIdentity(bundleID: "com.apple.Safari", windowID: 42, pid: 18, launched: target.launched, title: "b")
        XCTAssertFalse(SafariCaptureSelection.matches(target, in: [target, duplicateID]))
        XCTAssertFalse(SafariCaptureSelection.matches(target, in: [.init(bundleID: "other", windowID: 42, pid: 17, launched: target.launched, title: "a")]))
        XCTAssertFalse(SafariCaptureSelection.matches(target, in: [.init(bundleID: "com.apple.Safari", windowID: 42, pid: 18, launched: target.launched, title: "a")]))
        XCTAssertFalse(SafariCaptureSelection.matches(target, in: [.init(bundleID: "com.apple.Safari", windowID: 42, pid: 17, launched: target.launched.addingTimeInterval(1), title: "a")]))
    }

    func testCaptureRequiresMatchingWindowBeforeAndAfter() async throws {
        let stable = FakeSafariWindowProvider([[target], [target]])
        let frame = try await SafariWindowCapture.validatedFrame(target, provider: stable)
        XCTAssertEqual(frame, Data([1, 2, 3]))
        XCTAssertEqual(stable.captures, 1)
        let changedBefore = FakeSafariWindowProvider([[]])
        do { _ = try await SafariWindowCapture.validatedFrame(target, provider: changedBefore); XCTFail("must reject") } catch {}
        XCTAssertEqual(changedBefore.captures, 0)
        let changedAfter = FakeSafariWindowProvider([[target], []])
        do { _ = try await SafariWindowCapture.validatedFrame(target, provider: changedAfter); XCTFail("must discard") } catch {}
        XCTAssertEqual(changedAfter.captures, 1)
    }

    func testCancellationDiscardsFrameBeforeSecondInspection() async {
        let provider = FakeSafariWindowProvider([[target], [target]])
        provider.cancelDuringCapture = true
        let task = Task { @MainActor in try await SafariWindowCapture.validatedFrame(target, provider: provider) }
        do { _ = try await task.value; XCTFail("cancelled frame must be discarded") } catch is CancellationError {} catch { XCTFail("unexpected failure") }
        XCTAssertEqual(provider.captures, 1)
        XCTAssertEqual(provider.snapshots.count, 1)
    }

    func testNoSnapshotCanBeSubmittedUntilPreviewAndCancelClearsIt() {
        var state = SafariCaptureState()
        XCTAssertNil(state.snapshotForSubmission())
        let token = state.beginSelection()
        XCTAssertTrue(state.setPreview(Data([1, 2, 3]), token: token))
        XCTAssertEqual(state.snapshotForSubmission(), Data([1, 2, 3]))
        state.cancel()
        XCTAssertNil(state.snapshotForSubmission())
        XCTAssertFalse(state.isCurrent(token))
        XCTAssertFalse(state.setPreview(Data([4]), token: token))
    }

    func testCaptureGateBlocksConcurrencyUntilWorkerEnds() {
        let gate = SafariCaptureWorkGate()
        XCTAssertTrue(gate.begin()); XCTAssertFalse(gate.begin())
        gate.end(); XCTAssertTrue(gate.begin()); gate.end()
    }

    func testStalledCaptureReportsBusyWithoutStartingAnotherCapture() async {
        XCTAssertTrue(SafariCaptureWorkGate.shared.begin())
        defer { SafariCaptureWorkGate.shared.end() }
        let provider = FakeSafariWindowProvider([[target], [target]])
        do { _ = try await SafariWindowCapture.validatedFrame(target, provider: provider); XCTFail("must reject concurrent capture") }
        catch SafariWindowCaptureError.busy {} catch { XCTFail("must report busy") }
        XCTAssertEqual(provider.captures, 0)
    }

    func testCancelledEnumerationKeepsGateUntilUnderlyingCallbackFinishes() async throws {
        let gate = SafariEnumerationGate(), worker = EnumerationCompletion()
        let started = expectation(description: "underlying worker started")
        let first = Task { try await gate.run { callback in worker.install(callback); started.fulfill() } }
        await fulfillment(of: [started], timeout: 2)
        first.cancel()
        do { let _: Int = try await gate.run { $0(.success(2)) }; XCTFail("overlapping enumeration must fail") }
        catch SafariWindowCaptureError.busy {} catch { XCTFail("unexpected error") }
        worker.finish(1)
        do { _ = try await first.value; XCTFail("cancelled result must be discarded") } catch is CancellationError {} catch { XCTFail("unexpected error") }
        let second: Int = try await gate.run { $0(.success(3)) }
        XCTAssertEqual(second, 3)
    }

    func testWindowLabelsDisambiguateSameTitle() {
        let choices = [target, SafariWindowIdentity(bundleID: target.bundleID, windowID: 43, pid: target.pid, launched: target.launched, title: target.title)]
        XCTAssertEqual(SafariWindowLabel.text(at: 0, window: choices[0]), "窗口 1：a")
        XCTAssertEqual(SafariWindowLabel.text(at: 1, window: choices[1]), "窗口 2：a")
    }

    func testStalledEnumerationMessageOffersWaitOrRestartWithoutPromisingRecovery() {
        let message = SafariWindowMessages.enumerationBusy
        XCTAssertTrue(message.contains("等待系统恢复"))
        XCTAssertTrue(message.contains("重启 Jarvis"))
        XCTAssertFalse(message.contains("立即恢复"))
    }

    func testAlreadyCancelledEnumerationNeverStartsUnderlyingWork() async {
        let gate = SafariEnumerationGate()
        let invoked = expectation(description: "underlying worker must not start")
        invoked.isInverted = true
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            let _: Int = try await gate.run { callback in invoked.fulfill(); callback(.success(1)) }
        }
        do { try await task.value; XCTFail("cancelled task must fail") } catch is CancellationError {} catch { XCTFail("unexpected failure") }
        await fulfillment(of: [invoked], timeout: 0.1)
    }

    func testSyntheticFrameEncodesToBoundedPNGWithoutScreenAccess() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8,
                                              bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let data = try SafariCaptureEncoding.encode(image)
        XCTAssertEqual(Array(data.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
        XCTAssertLessThanOrEqual(data.count, 5 * 1024 * 1024)
    }

    func testOversizedSyntheticFrameIsRejectedBeforeEncoding() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 1281, height: 1, bitsPerComponent: 8,
                                              bytesPerRow: 1281 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        XCTAssertThrowsError(try SafariCaptureEncoding.encode(image))
    }

    func testFrameCompletionOnlyResumesOnce() async throws {
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            let completion = SafariFrameCompletion(continuation)
            completion.finish { Data([1]) }
            completion.finish { XCTFail("duplicate callback must not be processed"); return Data([2]) }
        }
        XCTAssertEqual(data, Data([1]))
    }

    func testConcurrentFrameCallbacksProcessOnlyOneResult() async throws {
        let counter = CompletionCounter()
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            let completion = SafariFrameCompletion(continuation)
            DispatchQueue.concurrentPerform(iterations: 50) { index in
                completion.finish { counter.increment(); return Data([UInt8(index)]) }
            }
        }
        XCTAssertEqual(data.count, 1)
        XCTAssertEqual(counter.value, 1)
    }
}
