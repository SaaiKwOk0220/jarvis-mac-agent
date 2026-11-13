import XCTest
@testable import JarvisService

final class SafariReadGateTests: XCTestCase {
    func testDisablingInvalidatesPreviouslyCapturedGeneration() {
        let gate = SafariReadGate()
        XCTAssertNil(gate.capture())
        gate.setEnabled(true)
        let generation = gate.capture()!
        XCTAssertTrue(gate.isValid(generation))
        gate.setEnabled(false)
        gate.setEnabled(true)
        XCTAssertFalse(gate.isValid(generation))
        XCTAssertNotNil(gate.capture())
    }
    func testDeliveryRejectsClosedOrReopenedGeneration() throws {
        let gate = SafariReadGate()
        gate.setEnabled(true)
        let generation = try XCTUnwrap(gate.capture())
        XCTAssertEqual(try gate.withCurrentGeneration(generation) { "delivered" }, "delivered")
        gate.setEnabled(false)
        gate.setEnabled(true)
        XCTAssertThrowsError(try gate.withCurrentGeneration(generation) { "must not deliver" })
    }
    func testCloseWaitsForInFlightDeliveryAndInvalidatesOldGeneration() throws {
        let gate = SafariReadGate()
        gate.setEnabled(true)
        let generation = try XCTUnwrap(gate.capture())
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let closed = DispatchSemaphore(value: 0)
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
        XCTAssertThrowsError(try gate.withCurrentGeneration(generation) { () })
    }
}
