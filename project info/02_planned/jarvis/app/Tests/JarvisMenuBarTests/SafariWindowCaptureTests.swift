import Foundation
import XCTest
@testable import JarvisMenuBar

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
}
