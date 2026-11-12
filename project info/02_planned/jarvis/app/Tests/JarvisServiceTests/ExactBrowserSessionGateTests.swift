import XCTest
@testable import JarvisService

final class ExactBrowserSessionGateTests: XCTestCase {
    func testDisableAndReenableInvalidatesOldGeneration() {
        let gate = ExactBrowserSessionGate()
        XCTAssertNil(gate.capture())
        gate.setEnabled(true)
        let old = gate.capture()!
        gate.setEnabled(false)
        gate.setEnabled(true)
        XCTAssertFalse(gate.isValid(old))
        XCTAssertNotNil(gate.capture())
    }
    func testOldGenerationCannotStartAfterCloseAndReopen() throws {
        let gate = ExactBrowserSessionGate()
        gate.setEnabled(true)
        let generation = try XCTUnwrap(gate.capture())
        gate.setEnabled(false)
        gate.setEnabled(true)
        XCTAssertThrowsError(try gate.withCurrentGeneration(generation) { true })
    }
    func testCloseSerializesWithOpenAndRejectsSubsequentOpen() throws {
        let gate = ExactBrowserSessionGate()
        gate.setEnabled(true)
        let generation = try XCTUnwrap(gate.capture())
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), closed = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = try? gate.withCurrentGeneration(generation) {
                entered.signal()
                _ = release.wait(timeout: .now() + 5)
            }
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        DispatchQueue.global().async { gate.setEnabled(false); closed.signal() }
        XCTAssertEqual(closed.wait(timeout: .now() + 0.1), .timedOut)
        release.signal()
        XCTAssertEqual(closed.wait(timeout: .now() + 2), .success)
        XCTAssertThrowsError(try gate.withCurrentGeneration(generation) { true })
    }
}
