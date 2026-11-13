import XCTest
import JarvisDomain
import JarvisPersistence
@testable import JarvisService

private actor FakeSafariCapture: SafariTargetCapturing {
    let target: SafariCapturedTarget
    var shouldFail = false
    init(_ target: SafariCapturedTarget) { self.target = target }
    func capture() async throws -> SafariCapturedTarget { target }
    func verify(_ target: SafariCapturedTarget) async throws { if shouldFail || target != self.target { throw SafariAXReadError.targetChanged } }
    func read(_ target: SafariCapturedTarget) async throws -> String { try await verify(target); return "page text" }
    func invalidate() { shouldFail = true }
}

final class SafariReadCoordinatorTests: XCTestCase {
    func testSensitiveURLIsOnlyAvailableToBoundPreviewAndSingleUseGrant() async throws {
        let coordinator = SafariReadCoordinator()
        let task = UUID()
        let target = SafariCapturedTarget(url: "https://example.com/private?token=secret", processID: 12, windowIdentity: UUID())
        let capture = FakeSafariCapture(target)
        let request = try await coordinator.prepare(taskID: task, capture: capture)
        XCTAssertEqual(request.target, "https://example.com")
        let serialized = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        XCTAssertFalse(serialized.contains("secret"))
        XCTAssertFalse(serialized.contains("private"))
        let preview = await coordinator.preview(request)
        XCTAssertEqual(preview, target.url)
        let changed = ToolRequest(id: request.id, taskID: task, name: request.name, sideEffect: request.sideEffect, target: "https://other.example", payload: request.payload)
        let wrong = await coordinator.preview(changed)
        XCTAssertNil(wrong)
        let approval = Approval(toolRequestID: request.id, actionDigest: request.payloadDigest, decision: .approved)
        let result = try await coordinator.readApproved(request, approval: approval)
        XCTAssertEqual(result, "page text")
        do { _ = try await coordinator.readApproved(request, approval: approval); XCTFail("ticket must be single-use") } catch { }
    }

    func testApprovedReadIsSingleUseAndRevalidatesTarget() async throws {
        let coordinator = SafariReadCoordinator()
        let target = SafariCapturedTarget(url: "https://example.com/a?private=x", processID: 12, windowIdentity: UUID())
        let request = try await coordinator.prepare(taskID: UUID(), capture: FakeSafariCapture(target))
        let approval = Approval(toolRequestID: request.id, actionDigest: request.payloadDigest, decision: .approved)
        let result = try await coordinator.readApproved(request, approval: approval)
        XCTAssertEqual(result, "page text")
        do { _ = try await coordinator.readApproved(request, approval: approval); XCTFail("ticket must be consumed") } catch { }
    }

    func testRejectedOrMismatchedApprovalCannotRead() async throws {
        let coordinator = SafariReadCoordinator()
        let target = SafariCapturedTarget(url: "https://example.com/", processID: 12, windowIdentity: UUID())
        let request = try await coordinator.prepare(taskID: UUID(), capture: FakeSafariCapture(target))
        let bad = [Approval(toolRequestID: request.id, actionDigest: request.payloadDigest, decision: .rejected), Approval(toolRequestID: UUID(), actionDigest: request.payloadDigest, decision: .approved), Approval(toolRequestID: request.id, actionDigest: "wrong", decision: .approved)]
        for approval in bad {
            do { _ = try await coordinator.readApproved(request, approval: approval); XCTFail("invalid approval") } catch { }
        }
        let good = Approval(toolRequestID: request.id, actionDigest: request.payloadDigest, decision: .approved)
        let result = try await coordinator.readApproved(request, approval: good)
        XCTAssertEqual(result, "page text")
    }

    func testChangedWindowRejectsApprovalAndCannotRetryTicket() async throws {
        let coordinator = SafariReadCoordinator()
        let target = SafariCapturedTarget(url: "https://example.com/", processID: 12, windowIdentity: UUID())
        let capture = FakeSafariCapture(target)
        let request = try await coordinator.prepare(taskID: UUID(), capture: capture)
        await capture.invalidate()
        let approval = Approval(toolRequestID: request.id, actionDigest: request.payloadDigest, decision: .approved)
        do { _ = try await coordinator.readApproved(request, approval: approval); XCTFail("changed target must fail") } catch SafariAXReadError.targetChanged { }
        do { _ = try await coordinator.readApproved(request, approval: approval); XCTFail("ticket must be burned") } catch { }
    }
}

private actor WaitingSafariCapture: SafariTargetCapturing {
    let target = SafariCapturedTarget(url: "https://example.com/", processID: 12, windowIdentity: UUID())
    var attempts = 0
    func capture() async throws -> SafariCapturedTarget { target }
    func verify(_ target: SafariCapturedTarget) async throws {
        attempts += 1
        if attempts < 3 { throw SafariAXReadError.notFocused }
    }
    func read(_ target: SafariCapturedTarget) async throws -> String { "ready" }
}

extension SafariReadCoordinatorTests {
    func testApprovedReadWaitsForSafariFocus() async throws {
        let coordinator = SafariReadCoordinator(focusTimeout: .seconds(1), focusPollInterval: .milliseconds(10))
        let capture = WaitingSafariCapture()
        let request = try await coordinator.prepare(taskID: UUID(), capture: capture)
        let approval = Approval(toolRequestID: request.id, actionDigest: request.payloadDigest, decision: .approved)
        let result = try await coordinator.readApproved(request, approval: approval)
        XCTAssertEqual(result, "ready")
        let attempts = await capture.attempts
        XCTAssertEqual(attempts, 4)
    }
}

private actor ChangesDuringRead: SafariTargetCapturing {
    let target = SafariCapturedTarget(url: "https://example.com/path", processID: 12, windowIdentity: UUID())
    private var changed = false
    func capture() async throws -> SafariCapturedTarget { target }
    func verify(_ target: SafariCapturedTarget) async throws { if changed { throw SafariAXReadError.targetChanged } }
    func read(_ target: SafariCapturedTarget) async throws -> String { changed = true; return "must never escape" }
}

extension SafariReadCoordinatorTests {
    func testTargetChangeDuringReadDiscardsResultAndBurnsTicket() async throws {
        let coordinator = SafariReadCoordinator()
        let request = try await coordinator.prepare(taskID: UUID(), capture: ChangesDuringRead())
        let approval = Approval(toolRequestID: request.id, actionDigest: request.payloadDigest, decision: .approved)
        do { _ = try await coordinator.readApproved(request, approval: approval); XCTFail("changed page must not return text") }
        catch SafariAXReadError.targetChanged { }
        do { _ = try await coordinator.readApproved(request, approval: approval); XCTFail("consumed ticket must not replay") }
        catch SafariReadCoordinatorError.unavailable { }
    }
}

private actor NeverFocusedSafariCapture: SafariTargetCapturing {
    let target = SafariCapturedTarget(url: "https://example.com/", processID: 12, windowIdentity: UUID())
    func capture() async throws -> SafariCapturedTarget { target }
    func verify(_ target: SafariCapturedTarget) async throws { throw SafariAXReadError.notFocused }
    func read(_ target: SafariCapturedTarget) async throws -> String { XCTFail("must not read without focus"); return "" }
}

extension SafariReadCoordinatorTests {
    func testApprovedReadFocusWaitTimesOutAndConsumesGrant() async throws {
        let coordinator = SafariReadCoordinator(focusTimeout: .milliseconds(30), focusPollInterval: .milliseconds(10))
        let request = try await coordinator.prepare(taskID: UUID(), capture: NeverFocusedSafariCapture())
        let approval = Approval(toolRequestID: request.id, actionDigest: request.payloadDigest, decision: .approved)
        do { _ = try await coordinator.readApproved(request, approval: approval); XCTFail("expected timeout") }
        catch SafariAXReadError.focusTimedOut { }
        do { _ = try await coordinator.readApproved(request, approval: approval); XCTFail("timeout must burn ticket") }
        catch SafariReadCoordinatorError.unavailable { }
    }

    func testApprovedReadFocusWaitCanBeCancelled() async throws {
        let coordinator = SafariReadCoordinator(focusTimeout: .seconds(5), focusPollInterval: .milliseconds(10))
        let request = try await coordinator.prepare(taskID: UUID(), capture: NeverFocusedSafariCapture())
        let approval = Approval(toolRequestID: request.id, actionDigest: request.payloadDigest, decision: .approved)
        let job = Task { try await coordinator.readApproved(request, approval: approval) }
        try await Task.sleep(for: .milliseconds(30))
        job.cancel()
        do { _ = try await job.value; XCTFail("expected cancellation") }
        catch is CancellationError { }
        do { _ = try await coordinator.readApproved(request, approval: approval); XCTFail("cancel must burn ticket") }
        catch SafariReadCoordinatorError.unavailable { }
    }
}

extension SafariReadCoordinatorTests {
    func testDisabledAndReenabledGateCannotReadOldApproval() async throws {
        let gate = SafariReadGate()
        gate.setEnabled(true)
        let coordinator = SafariReadCoordinator(gate: gate)
        let target = SafariCapturedTarget(url: "https://example.com/", processID: 12, windowIdentity: UUID())
        let request = try await coordinator.prepare(taskID: UUID(), capture: FakeSafariCapture(target))
        let approval = Approval(toolRequestID: request.id, actionDigest: request.payloadDigest, decision: .approved)
        gate.setEnabled(false)
        gate.setEnabled(true)
        do {
            _ = try await coordinator.readApproved(request, approval: approval)
            XCTFail("Old approval must not survive disabling")
        } catch SafariReadCoordinatorError.unavailable {}
    }
}

extension SafariReadCoordinatorTests {
    func testRevocationSuppressesOldPreviewAfterReenable() async throws {
        let gate = SafariReadGate()
        gate.setEnabled(true)
        let coordinator = SafariReadCoordinator(gate: gate)
        let target = SafariCapturedTarget(url: "https://example.com/private", processID: 12, windowIdentity: UUID())
        let request = try await coordinator.prepare(taskID: UUID(), capture: FakeSafariCapture(target))
        let before = await coordinator.preview(request)
        XCTAssertEqual(before, target.url)
        gate.setEnabled(false)
        gate.setEnabled(true)
        let after = await coordinator.preview(request)
        XCTAssertNil(after)
    }
}
