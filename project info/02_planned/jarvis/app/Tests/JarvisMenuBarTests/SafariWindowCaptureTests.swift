import Foundation
import XCTest
@testable import JarvisMenuBar

final class SafariWindowCaptureTests: XCTestCase {
    func testOnlyOneIdentifiedSafariWindowIsAccepted() {
        XCTAssertTrue(SafariCaptureSelection.isAllowed(styleIsWindow: true, windows: [.init(bundleID: "com.apple.Safari", windowID: 42, pid: 17)]))
        XCTAssertFalse(SafariCaptureSelection.isAllowed(styleIsWindow: false, windows: [.init(bundleID: "com.apple.Safari", windowID: 42, pid: 17)]))
        XCTAssertFalse(SafariCaptureSelection.isAllowed(styleIsWindow: true, windows: []))
        XCTAssertFalse(SafariCaptureSelection.isAllowed(styleIsWindow: true, windows: [.init(bundleID: "com.other", windowID: 42, pid: 17)]))
        XCTAssertFalse(SafariCaptureSelection.isAllowed(styleIsWindow: true, windows: [.init(bundleID: "com.apple.Safari", windowID: 0, pid: 17)]))
        XCTAssertFalse(SafariCaptureSelection.isAllowed(styleIsWindow: true, windows: [.init(bundleID: "com.apple.Safari", windowID: 42, pid: 0)]))
        XCTAssertFalse(SafariCaptureSelection.isAllowed(styleIsWindow: true, windows: [.init(bundleID: "com.apple.Safari", windowID: 42, pid: 17), .init(bundleID: "com.apple.Safari", windowID: 43, pid: 17)]))
    }

    func testNoSnapshotCanBeSubmittedUntilExplicitPreviewAndCloseClearsIt() {
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

    func testReselectionInvalidatesOldFrameAndLimitsEncodedSize() {
        var state = SafariCaptureState()
        let old = state.beginSelection()
        let current = state.beginSelection()
        XCTAssertFalse(state.setPreview(Data([1]), token: old))
        XCTAssertFalse(state.setPreview(Data(), token: current))
        XCTAssertFalse(state.setPreview(Data(count: 5 * 1024 * 1024 + 1), token: current))
        XCTAssertNil(state.snapshotForSubmission())
    }

    func testCaptureGatePreventsConcurrentWorkUntilWorkerEnds() {
        let gate = SafariCaptureWorkGate()
        XCTAssertTrue(gate.begin())
        XCTAssertFalse(gate.begin())
        gate.end()
        XCTAssertTrue(gate.begin())
        gate.end()
    }
}
