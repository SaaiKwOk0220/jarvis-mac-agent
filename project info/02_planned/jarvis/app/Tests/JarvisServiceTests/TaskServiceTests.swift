import Foundation
import XCTest
import JarvisDomain
import JarvisPersistence
import JarvisPolicy
@testable import JarvisService

final class TaskServiceTests: XCTestCase {
    func testExactBrowserApprovalTransactionFailureShowsExpiredTarget() async throws {
        #if !JARVIS_EXACT_BROWSER_EXPERIMENT && !JARVIS_COMBINED_EXPERIMENT
        throw XCTSkip("Exact browser feature is unavailable in ordinary builds")
        #endif
        let recorder = BrowserRecorder()
        let fixture = try Fixture(browserOpen: BrowserOpenExecutor(opener: { url in recorder.record(url); return true }, exactOpener: { url in recorder.record(url); return true }), exactBrowserEnabled: true)
        let task = try await fixture.service.createTask(title: "Open")
        let request = ToolRequest(taskID: task.id, name: "browser_open", sideEffect: .externalSend, target: "https://example.com/private", payload: "Open in browser")
        _ = try await fixture.service.submit(request: request)
        let before = try await fixture.service.listPendingApprovalRequests(taskID: task.id)
        let digest = try XCTUnwrap(before.first?.digest)
        try fixture.database.write { db in
            try db.execute(sql: "CREATE TRIGGER fail_approval BEFORE INSERT ON approvals BEGIN SELECT RAISE(ABORT, 'test failure'); END")
        }
        await XCTAssertThrowsErrorAsync(try await fixture.service.approve(requestID: request.id, digest: digest))
        let pending = try await fixture.service.listPendingApprovalRequests(taskID: task.id)
        XCTAssertEqual(pending.first?.target, "[目标已失效，请拒绝此请求后重新请求]")
        let count = await recorder.count
        XCTAssertEqual(count, 0)
    }
    func testExactBrowserExpiredTicketCannotExecute() async throws {
        #if !JARVIS_EXACT_BROWSER_EXPERIMENT && !JARVIS_COMBINED_EXPERIMENT
        throw XCTSkip("Exact browser feature is unavailable in ordinary builds")
        #endif
        let recorder = BrowserRecorder()
        let fixture = try Fixture(browserOpen: BrowserOpenExecutor(opener: { url in recorder.record(url); return true }, exactOpener: { url in recorder.record(url); return true }), exactBrowserEnabled: true, browserTicketLifetime: 0.05)
        let task = try await fixture.service.createTask(title: "Open")
        let request = ToolRequest(taskID: task.id, name: "browser_open", sideEffect: .externalSend, target: "https://example.com/private", payload: "Open in browser")
        _ = try await fixture.service.submit(request: request)
        let pending = try await fixture.service.listPendingApprovalRequests(taskID: task.id)
        let digest = try XCTUnwrap(pending.first?.digest)
        try await Task.sleep(for: .milliseconds(100))
        await XCTAssertThrowsErrorAsync(try await fixture.service.approve(requestID: request.id, digest: digest))
        let count = await recorder.count
        XCTAssertEqual(count, 0)
        XCTAssertEqual(fixture.service.testBrowserTicketCount, 0)
    }
    func testExactBrowserTransactionFailureRevokesTicket() async throws {
        #if !JARVIS_EXACT_BROWSER_EXPERIMENT && !JARVIS_COMBINED_EXPERIMENT
        throw XCTSkip("Exact browser feature is unavailable in ordinary builds")
        #endif
        let fixture = try Fixture(exactBrowserEnabled: true)
        let task = try await fixture.service.createTask(title: "Open")
        try fixture.database.write { db in
            try db.execute(sql: "CREATE TRIGGER fail_browser_insert BEFORE INSERT ON tool_requests BEGIN SELECT RAISE(ABORT, 'test failure'); END")
        }
        let request = ToolRequest(taskID: task.id, name: "browser_open", sideEffect: .externalSend, target: "https://example.com/private?secret=x", payload: "Open in browser")
        await XCTAssertThrowsErrorAsync(try await fixture.service.submit(request: request))
        XCTAssertEqual(fixture.service.testBrowserTicketCount, 0)
        XCTAssertNil(try fixture.requests.fetch(id: request.id))
    }
    func testExactBrowserRejectAndCancelCannotExecute() async throws {
        #if !JARVIS_EXACT_BROWSER_EXPERIMENT && !JARVIS_COMBINED_EXPERIMENT
        throw XCTSkip("Exact browser feature is unavailable in ordinary builds")
        #endif
        let recorder = BrowserRecorder()
        let fixture = try Fixture(browserOpen: BrowserOpenExecutor(opener: { url in recorder.record(url); return true }, exactOpener: { url in recorder.record(url); return true }), exactBrowserEnabled: true)
        for shouldCancel in [false, true] {
            let task = try await fixture.service.createTask(title: "Open")
            let request = ToolRequest(taskID: task.id, name: "browser_open", sideEffect: .externalSend, target: "https://example.com/private?secret=x", payload: "Open in browser")
            _ = try await fixture.service.submit(request: request)
            let pending = try await fixture.service.listPendingApprovalRequests(taskID: task.id)
            let digest = try XCTUnwrap(pending.first?.digest)
            if shouldCancel { try await fixture.service.cancel(taskID: task.id) }
            else { try await fixture.service.reject(requestID: request.id) }
            await XCTAssertThrowsErrorAsync(try await fixture.service.approve(requestID: request.id, digest: digest))
        }
        let count = await recorder.count
        XCTAssertEqual(count, 0)
    }
    func testExactBrowserPendingTicketFailsAfterServiceRestart() async throws {
        #if !JARVIS_EXACT_BROWSER_EXPERIMENT && !JARVIS_COMBINED_EXPERIMENT
        throw XCTSkip("Exact browser feature is unavailable in ordinary builds")
        #endif
        let recorder = BrowserRecorder()
        let fixture = try Fixture(browserOpen: BrowserOpenExecutor(opener: { url in recorder.record(url); return true }, exactOpener: { url in recorder.record(url); return true }), exactBrowserEnabled: true)
        let task = try await fixture.service.createTask(title: "Open")
        let request = ToolRequest(taskID: task.id, name: "browser_open", sideEffect: .externalSend, target: "https://example.com/private?secret=x", payload: "Open in browser")
        _ = try await fixture.service.submit(request: request)
        let pending = try await fixture.service.listPendingApprovalRequests(taskID: task.id)
        let restarted = try fixture.makeService()
        await XCTAssertThrowsErrorAsync(try await restarted.approve(requestID: request.id, digest: pending[0].digest))
        let count = await recorder.count
        XCTAssertEqual(count, 0)
    }
    func testExactBrowserURLRemainsEphemeralUntilApproved() async throws {
        #if !JARVIS_EXACT_BROWSER_EXPERIMENT && !JARVIS_COMBINED_EXPERIMENT
        throw XCTSkip("Exact browser feature is unavailable in ordinary builds")
        #endif
        let recorder = BrowserRecorder()
        let fixture = try Fixture(browserOpen: BrowserOpenExecutor(opener: { url in recorder.record(url); return true }, exactOpener: { url in recorder.record(url); return true }), exactBrowserEnabled: true)
        let task = try await fixture.service.createTask(title: "Open")
        let secret = "private-path-token"
        let request = ToolRequest(taskID: task.id, name: "browser_open", sideEffect: .externalSend, target: "https://example.com/\(secret)?token=\(secret)", payload: "Open in browser")
        let decision = try await fixture.service.submit(request: request)
        guard case .requireApproval = decision else { return XCTFail("Exact destination must require approval") }
        let pending = try await fixture.service.listPendingApprovalRequests(taskID: task.id)
        XCTAssertEqual(pending.first?.target, request.target)
        XCTAssertFalse(try fixture.requests.fetch(id: request.id)!.0.target.contains(secret))
        XCTAssertTrue(try fixture.audit.events(for: task.id).allSatisfy { !$0.target.contains(secret) && !$0.result.contains(secret) && !$0.summary.contains(secret) })
        try await fixture.service.approve(requestID: request.id, digest: pending[0].digest)
        try await fixture.waitForRequest(id: request.id, status: .completed)
        let persisted = try XCTUnwrap(fixture.requests.fetch(id: request.id)?.0)
        XCTAssertFalse(persisted.target.contains(secret))
        XCTAssertFalse(persisted.payload.contains(secret))
        XCTAssertTrue(try fixture.audit.events(for: task.id).allSatisfy {
            !$0.target.contains(secret) && !$0.result.contains(secret) && !$0.summary.contains(secret)
        })
        let count = await recorder.count
        XCTAssertEqual(count, 1)
    }

    func testBrowserOpenRequiresApprovalAndRedactsAuditPath() async throws {
        let recorder = BrowserRecorder()
        let fixture = try Fixture(browserOpen: BrowserOpenExecutor(opener: { url in recorder.record(url); return true }, exactOpener: { url in recorder.record(url); return true }))
        let task = try await fixture.service.createTask(title: "Open page")
        let request = ToolRequest(taskID: task.id, name: "browser_open", sideEffect: .externalSend, target: "https://example.com/", payload: "Open in browser")
        let decision = try await fixture.service.submit(request: request)
        XCTAssertEqual(decision, .requireApproval(reason: "opens the initial origin only; afterward the browser may navigate anywhere, redirect, run scripts, and send network requests; the domain and your original task text may be stored locally"))
        let before = await recorder.count
        XCTAssertEqual(before, 0)
        let pending = try await fixture.service.listPendingApprovalRequests(taskID: task.id)
        XCTAssertEqual(pending.first?.target, request.target)
        let events = try fixture.audit.events(for: task.id)
        XCTAssertTrue(events.allSatisfy { !$0.target.contains("private-path") && !$0.result.contains("private-path") })
        try await fixture.service.approve(requestID: request.id, digest: request.payloadDigest)
        try await fixture.waitForRequest(id: request.id, status: .completed)
        let after = await recorder.count
        XCTAssertEqual(after, 1)
        await XCTAssertThrowsErrorAsync(try await fixture.service.approve(requestID: request.id, digest: request.payloadDigest))
        let afterRepeat = await recorder.count
        XCTAssertEqual(afterRepeat, 1)
        let completedEvents = try fixture.audit.events(for: task.id)
        XCTAssertTrue(completedEvents.allSatisfy { !$0.target.contains("private-path") && !$0.result.contains("private-path") })
    }

    func testBrowserRejectAndCancellationNeverOpen() async throws {
        for cancel in [false, true] {
            let recorder = BrowserRecorder()
            let fixture = try Fixture(browserOpen: BrowserOpenExecutor(opener: { url in recorder.record(url); return true }, exactOpener: { url in recorder.record(url); return true }))
            let task = try await fixture.service.createTask(title: "Open")
            let request = ToolRequest(taskID: task.id, name: "browser_open", sideEffect: .externalSend, target: "https://example.com/", payload: "Open in browser")
            _ = try await fixture.service.submit(request: request)
            if cancel { try await fixture.service.cancel(taskID: task.id) }
            else { try await fixture.service.reject(requestID: request.id) }
            await XCTAssertThrowsErrorAsync(try await fixture.service.approve(requestID: request.id, digest: request.payloadDigest))
            let count = await recorder.count
            XCTAssertEqual(count, 0)
        }
    }

    func testPendingBrowserOpenIsNotAutomaticallyReplayedAfterServiceRestart() async throws {
        let recorder = BrowserRecorder()
        let fixture = try Fixture(browserOpen: BrowserOpenExecutor(opener: { url in recorder.record(url); return true }, exactOpener: { url in recorder.record(url); return true }))
        let task = try await fixture.service.createTask(title: "Open")
        let request = ToolRequest(taskID: task.id, name: "browser_open", sideEffect: .externalSend, target: "https://example.com/", payload: "Open in browser")
        _ = try await fixture.service.submit(request: request)
        let restarted = try fixture.makeService()
        try await Task.sleep(for: .milliseconds(100))
        let pending = try await restarted.listPendingApprovalRequests(taskID: task.id)
        XCTAssertEqual(pending.count, 1)
        let count = await recorder.count
        XCTAssertEqual(count, 0)
    }

    func testBrowserExecutorRevalidatesMalformedRequest() async throws {
        let recorder = BrowserRecorder()
        let executor = BrowserOpenExecutor(opener: { url in recorder.record(url); return true }, exactOpener: { url in recorder.record(url); return true })
        let request = ToolRequest(taskID: UUID(), name: "browser_open", sideEffect: .externalSend, target: "https://example.com/?secret=x", payload: "Open in browser")
        await XCTAssertThrowsErrorAsync(try await executor.execute(request))
        let count = await recorder.count
        XCTAssertEqual(count, 0)
    }

    func testInternalExactExecutorRejectsCredentials() async throws {
        let recorder = BrowserRecorder()
        let executor = BrowserOpenExecutor(opener: { url in recorder.record(url); return true }, exactOpener: { url in recorder.record(url); return true })
        let request = ToolRequest(taskID: UUID(), name: "browser_open", sideEffect: .externalSend, target: "https://user:pass@example.com/private", payload: "Open in browser")
        let gate = ExactBrowserSessionGate()
        gate.setEnabled(true)
        let generation = try XCTUnwrap(gate.capture())
        await XCTAssertThrowsErrorAsync(try await executor.executeApprovedExact(request, gate: gate, generation: generation))
        let count = await recorder.count
        XCTAssertEqual(count, 0)
    }

    func testBrowserOpenWithoutExecutorCannotFallBackToNoOp() async throws {
        let fixture = try Fixture()
        let task = try await fixture.service.createTask(title: "Open")
        let request = ToolRequest(taskID: task.id, name: "browser_open", sideEffect: .externalSend, target: "https://example.com/", payload: "Open in browser")
        _ = try await fixture.service.submit(request: request)
        try await fixture.service.approve(requestID: request.id, digest: request.payloadDigest)
        try await fixture.waitForRequest(id: request.id, status: .failed)
        XCTAssertEqual(try fixture.requests.fetch(id: request.id)?.1, .failed)
        XCTAssertFalse(try fixture.audit.events(for: task.id).contains { $0.summary == "tool result" })
    }

    @MainActor
    func testCancelledQueuedMainActorOpenDoesNotCallSystemOpener() async {
        var didOpen = false
        let task = Task { @MainActor in
            BrowserOpenExecutor.openOnMainActorIfNotCancelled(URL(string: "https://example.com/")!) { _ in
                didOpen = true
                return true
            }
        }
        task.cancel()
        let result = await task.value
        XCTAssertFalse(result)
        XCTAssertFalse(didOpen)
    }

    func testRejectedSensitiveURLDoesNotEnterRequestApprovalOrAuditStorage() async throws {
        let fixture = try Fixture()
        let task = try await fixture.service.createTask(title: "Open page")
        let secret = "sensitive-path-token"
        let request = ToolRequest(taskID: task.id, name: "browser_open", sideEffect: .externalSend, target: "https://example.com/\(secret)?token=\(secret)", payload: "Open in browser")
        let decision = try await fixture.service.submit(request: request)
        XCTAssertEqual(decision, .deny(reason: "invalid browser destination"))
        XCTAssertNil(try fixture.requests.fetch(id: request.id))
        let pending = try await fixture.service.listPendingApprovalRequests(taskID: task.id)
        XCTAssertTrue(pending.isEmpty)
        XCTAssertTrue(try fixture.approvals.list().isEmpty)
        let events = try fixture.audit.events(for: task.id)
        XCTAssertFalse(events.isEmpty)
        XCTAssertTrue(events.allSatisfy { !$0.target.contains(secret) && !$0.result.contains(secret) && !$0.summary.contains(secret) })
    }

    func testCancellationAfterBrowserOpenCannotUndoOpen() async throws {
        let recorder = BrowserRecorder()
        let fixture = try Fixture(browserOpen: BrowserOpenExecutor(opener: { url in recorder.record(url); return true }, exactOpener: { url in recorder.record(url); return true }))
        let task = try await fixture.service.createTask(title: "Open")
        let request = ToolRequest(taskID: task.id, name: "browser_open", sideEffect: .externalSend, target: "https://example.com/", payload: "Open in browser")
        _ = try await fixture.service.submit(request: request)
        try await fixture.service.approve(requestID: request.id, digest: request.payloadDigest)
        try await fixture.waitForRequest(id: request.id, status: .completed)
        try await fixture.service.cancel(taskID: task.id)
        let count = await recorder.count
        XCTAssertEqual(count, 1)
    }

    func testLegalTransitionsPersistTheNewStatus() async throws {
        let fixture = try Fixture()
        let task = try await fixture.service.createTask(title: "Build release")

        try fixture.service.transition(taskID: task.id, to: .planning)
        try fixture.service.transition(taskID: task.id, to: .running)

        let stored = try await fixture.service.getTask(id: task.id)
        XCTAssertEqual(stored?.status, .running)
    }

    func testIllegalTransitionIsRejectedWithoutChangingStoredStatus() async throws {
        let fixture = try Fixture()
        let task = try await fixture.service.createTask(title: "Build release")

        XCTAssertThrowsError(try fixture.service.transition(taskID: task.id, to: .completed)) {
            XCTAssertEqual($0 as? TaskServiceError, .illegalTransition(from: .draft, to: .completed))
        }

        let stored = try await fixture.service.getTask(id: task.id)
        XCTAssertEqual(stored?.status, .draft)
    }

    func testProtectedRequestPersistsAwaitingApproval() async throws {
        let fixture = try Fixture()
        let task = try await fixture.service.createTask(title: "Edit document")
        let request = ToolRequest(
            taskID: task.id,
            name: "write_file",
            sideEffect: .localWrite,
            target: "/tmp/jarvis-service/document.txt",
            payload: "private contents"
        )

        let decision = try await fixture.service.submit(request: request)

        XCTAssertEqual(decision, .requireApproval(reason: "local write changes local state"))
        let stored = try await fixture.service.getTask(id: task.id)
        XCTAssertEqual(stored?.status, .awaitingApproval)
    }

    func testServiceRecreationApprovesPersistedRequestAndRecordsApproval() async throws {
        let fixture = try Fixture()
        let task = try await fixture.service.createTask(title: "Restart approval")
        let request = ToolRequest(taskID: task.id, name: "write_file", sideEffect: .localWrite, target: "/tmp/jarvis-service/a", payload: "content", scope: ToolScope(workingDirectory: "/tmp/jarvis-service"))
        _ = try await fixture.service.submit(request: request)
        let restarted = try fixture.makeService()

        try await restarted.approve(requestID: request.id, digest: request.payloadDigest)

        for _ in 0..<50 {
            if try fixture.requests.fetch(id: request.id)?.1 == .completed { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertEqual(try fixture.requests.fetch(id: request.id)?.1, .completed)
        XCTAssertEqual(try fixture.approvals.list().map(\.decision), [.approved])
    }

    func testServiceRecreationRejectsPersistedRequestAndRecordsRejection() async throws {
        let fixture = try Fixture()
        let task = try await fixture.service.createTask(title: "Restart rejection")
        let request = ToolRequest(taskID: task.id, name: "write_file", sideEffect: .localWrite, target: "/tmp/jarvis-service/a", payload: "content")
        _ = try await fixture.service.submit(request: request)

        try await fixture.makeService().reject(requestID: request.id)

        XCTAssertEqual(try fixture.tasks.fetch(id: task.id)?.status, .blocked)
        XCTAssertEqual(try fixture.requests.fetch(id: request.id)?.1, .rejected)
        XCTAssertEqual(try fixture.approvals.list().map(\.decision), [.rejected])
    }

    func testExecutorFailurePersistsFailedRequestTaskAndAudit() async throws {
        let fixture = try Fixture(executor: ThrowingExecutor())
        let task = try await fixture.service.createTask(title: "Failure")
        let request = ToolRequest(taskID: task.id, name: "read_file", sideEffect: .read, target: "/tmp/jarvis-service/a", payload: "")

        await XCTAssertThrowsErrorAsync(try await fixture.service.submit(request: request))

        XCTAssertEqual(try fixture.tasks.fetch(id: task.id)?.status, .failed)
        XCTAssertEqual(try fixture.requests.fetch(id: request.id)?.1, .failed)
        XCTAssertTrue(try fixture.audit.events(for: task.id).contains { $0.summary == "tool failure" })
    }

    func testCancellationCancelsExecutingRequestAndSuppressesSuccess() async throws {
        let executor = SuspendingExecutor()
        let fixture = try Fixture(executor: executor)
        let task = try await fixture.service.createTask(title: "Cancel running")
        let request = ToolRequest(taskID: task.id, name: "read_file", sideEffect: .read, target: "/tmp/jarvis-service/a", payload: "")
        let submission = Task.detached { try? await fixture.service.submit(request: request) }
        await executor.started()

        try await fixture.service.cancel(taskID: task.id)
        executor.resume()
        _ = await submission.result
        try await Task.sleep(nanoseconds: 5_000_000)

        XCTAssertEqual(try fixture.tasks.fetch(id: task.id)?.status, .cancelled)
        XCTAssertEqual(try fixture.requests.fetch(id: request.id)?.1, .cancelled)
        XCTAssertFalse(try fixture.audit.events(for: task.id).contains { $0.summary == "tool result" })
    }

    func testApprovalDigestMismatchRejectsRequestAndLeavesTaskAwaitingApproval() async throws {
        let fixture = try Fixture()
        let task = try await fixture.service.createTask(title: "Edit document")
        let request = ToolRequest(
            taskID: task.id,
            name: "write_file",
            sideEffect: .localWrite,
            target: "/tmp/jarvis-service/document.txt",
            payload: "private contents",
            scope: ToolScope(workingDirectory: "/tmp/jarvis-service")
        )
        _ = try await fixture.service.submit(request: request)

        await XCTAssertThrowsErrorAsync(try await fixture.service.approve(requestID: request.id, digest: "tampered")) {
            XCTAssertEqual($0 as? TaskServiceError, .approvalDigestMismatch)
        }

        let stored = try await fixture.service.getTask(id: task.id)
        XCTAssertEqual(stored?.status, .awaitingApproval)
        XCTAssertTrue(try fixture.audit.events(for: task.id).contains { $0.summary == "approval rejected" })
    }

    func testCancellationPersistsCancelledStatusAndAuditsIt() async throws {
        let fixture = try Fixture()
        let task = try await fixture.service.createTask(title: "Build release")

        try await fixture.service.cancel(taskID: task.id)

        let stored = try await fixture.service.getTask(id: task.id)
        XCTAssertEqual(stored?.status, .cancelled)
        XCTAssertTrue(try fixture.audit.events(for: task.id).contains { $0.summary == "task cancelled" })
    }

    func testSecondServiceCannotSubmitAfterConcurrentCancellation() async throws {
        let fixture = try Fixture()
        let task = try await fixture.service.createTask(title: "Cross service cancellation")
        let policy = BlockingAllowPolicy()
        let second = try TaskService(taskRepository: fixture.tasks, auditRepository: fixture.audit, policy: policy, policyConfig: PolicyConfig(approvedDirectories: ["/tmp/jarvis-service"]), requestRepository: fixture.requests, approvalRepository: fixture.approvals, unitOfWork: SQLitePersistenceUnitOfWork(database: fixture.database))
        let request = ToolRequest(taskID: task.id, name: "read_file", sideEffect: .read, target: "/tmp/jarvis-service/a", payload: "")
        let submission = Task.detached { try? await second.submit(request: request) }

        XCTAssertTrue(policy.waitForEvaluation())
        try await fixture.service.cancel(taskID: task.id)
        policy.open()
        _ = await submission.result

        XCTAssertEqual(try fixture.tasks.fetch(id: task.id)?.status, .cancelled)
        XCTAssertNil(try fixture.requests.fetch(id: request.id))
    }

    func testAllowedExecutionIsTrackedAndCancelled() async throws {
        let executor = SuspendingExecutor()
        let fixture = try Fixture(executor: executor)
        let task = try await fixture.service.createTask(title: "Cancel allowed execution")
        let request = ToolRequest(taskID: task.id, name: "read_file", sideEffect: .read, target: "/tmp/jarvis-service/a", payload: "")
        let submission = Task.detached { try? await fixture.service.submit(request: request) }
        await executor.started()

        try await fixture.service.cancel(taskID: task.id)
        executor.resume()
        _ = await submission.result
        XCTAssertEqual(try fixture.requests.fetch(id: request.id)?.1, .cancelled)
        XCTAssertFalse(try fixture.audit.events(for: task.id).contains { $0.summary == "tool result" })
    }

    func testCancellationCancelsMultipleExecutionsForOneTask() async throws {
        let executor = MultiSuspendingExecutor()
        let fixture = try Fixture(executor: executor)
        let task = try await fixture.service.createTask(title: "Cancel multiple executions")
        let requests = (0..<2).map { ToolRequest(taskID: task.id, name: "read_file", sideEffect: .read, target: "/tmp/jarvis-service/\($0)", payload: "") }
        let submissions = requests.map { request in Task.detached { try? await fixture.service.submit(request: request) } }
        await executor.started(ids: Set(requests.map(\.id)))

        try await fixture.service.cancel(taskID: task.id)
        requests.forEach { executor.resume(id: $0.id) }
        for submission in submissions { _ = await submission.result }
        for request in requests { XCTAssertEqual(try fixture.requests.fetch(id: request.id)?.1, .cancelled) }
        XCTAssertFalse(try fixture.audit.events(for: task.id).contains { $0.summary == "tool result" })
    }

    func testApprovedRequestCompletesTaskAfterNoOpExecutor() async throws {
        let fixture = try Fixture()
        let task = try await fixture.service.createTask(title: "Approve demo completion")
        let request = ToolRequest(taskID: task.id, name: "demo_write", sideEffect: .localWrite,
            target: "/tmp/jarvis-service/draft.txt", payload: "Create a local demo draft")
        _ = try await fixture.service.submit(request: request)
        XCTAssertEqual(try fixture.tasks.fetch(id: task.id)?.status, .awaitingApproval)

        try await fixture.service.approve(requestID: request.id, digest: request.payloadDigest)

        for _ in 0..<100 {
            if try fixture.requests.fetch(id: request.id)?.1 == .completed { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(try fixture.tasks.fetch(id: task.id)?.status, .running,
            "Task stays .running after executor success; call complete(taskID:) to finish")
        XCTAssertEqual(try fixture.requests.fetch(id: request.id)?.1, .completed)
        XCTAssertTrue(try fixture.audit.events(for: task.id).contains { $0.summary == "tool result" })

        try await fixture.service.complete(taskID: task.id)
        XCTAssertEqual(try fixture.tasks.fetch(id: task.id)?.status, .completed,
            "complete(taskID:) transitions the running task to .completed")
    }

    func testRejectsRepositoriesFromDifferentDatabases() throws {
        let first = try Database(path: ":memory:"); try first.migrate()
        let second = try Database(path: ":memory:"); try second.migrate()
        XCTAssertThrowsError(try TaskService(taskRepository: SQLiteTaskRepository(database: first), auditRepository: SQLiteAuditRepository(database: second), policy: Policy())) {
            XCTAssertEqual($0 as? TaskServiceError, .incompatiblePersistence)
        }
    }

    func testPersistenceCannotRecordOrSubmitRequestsForCancelledTask() async throws {
        let fixture = try Fixture()
        let task = try await fixture.service.createTask(title: "Persistence guard")
        try fixture.service.transition(taskID: task.id, to: .planning)
        try fixture.service.transition(taskID: task.id, to: .running)
        try await fixture.service.cancel(taskID: task.id)
        let immediate = ToolRequest(taskID: task.id, name: "read_file", sideEffect: .read, target: "/tmp/jarvis-service/a", payload: "")
        let pending = ToolRequest(taskID: task.id, name: "write_file", sideEffect: .localWrite, target: "/tmp/jarvis-service/b", payload: "")
        let uow = SQLitePersistenceUnitOfWork(database: fixture.database)

        XCTAssertThrowsError(try uow.recordRequest(immediate, status: .executing, audits: []))
        XCTAssertThrowsError(try uow.submitRequest(pending, status: .pending, taskStatus: .awaitingApproval, audits: []))
        XCTAssertEqual(try fixture.tasks.fetch(id: task.id)?.status, .cancelled)
        XCTAssertNil(try fixture.requests.fetch(id: immediate.id))
        XCTAssertNil(try fixture.requests.fetch(id: pending.id))
    }

    func testAllowedRequestCreatesRequestDecisionAndResultAuditEvents() async throws {
        let fixture = try Fixture()
        let task = try await fixture.service.createTask(title: "Read document")
        let request = ToolRequest(
            taskID: task.id,
            name: "read_file",
            sideEffect: .read,
            target: "/tmp/jarvis-service/document.txt",
            payload: "secret=do-not-record"
        )

        let decision = try await fixture.service.submit(request: request)
        XCTAssertEqual(decision, .allow)

        let summaries = try fixture.audit.events(for: task.id).map(\.summary)
        XCTAssertTrue(summaries.contains("tool request received"))
        XCTAssertTrue(summaries.contains("policy allowed"))
        XCTAssertTrue(summaries.contains("tool result"))
        XCTAssertFalse(try fixture.audit.events(for: task.id).contains { $0.summary.contains("do-not-record") || $0.result.contains("do-not-record") })
    }

    func testLoopbackJSONEndpointsCreateListDetailAndCancelWhileRejectingRemotePeers() async throws {
        let fixture = try Fixture()
        let server = LoopbackServer(service: fixture.service)

        let create = await server.handle(
            method: "POST",
            path: "/tasks",
            body: Data("{\"title\":\"From endpoint\"}".utf8),
            peerHost: "127.0.0.1"
        )
        XCTAssertEqual(create.status, 201)
        let task = try JSONDecoder().decode(JarvisTask.self, from: create.body)

        let list = await server.handle(method: "GET", path: "/tasks", body: Data(), peerHost: "::1")
        XCTAssertEqual(list.status, 200)
        XCTAssertEqual(try JSONDecoder().decode([JarvisTask].self, from: list.body).map(\.id), [task.id])

        let detail = await server.handle(method: "GET", path: "/tasks/\(task.id.uuidString)", body: Data(), peerHost: "127.0.0.1")
        XCTAssertEqual(detail.status, 200)
        XCTAssertEqual(try JSONDecoder().decode(JarvisTask.self, from: detail.body).id, task.id)

        let cancel = await server.handle(method: "POST", path: "/tasks/\(task.id.uuidString)/cancel", body: Data(), peerHost: "127.0.0.1")
        XCTAssertEqual(cancel.status, 204)
        let stored = try await fixture.service.getTask(id: task.id)
        XCTAssertEqual(stored?.status, .cancelled)

        let remote = await server.handle(method: "GET", path: "/tasks", body: Data(), peerHost: "203.0.113.10")
        XCTAssertEqual(remote.status, 403)
    }

    func testLoopbackServerServesJSONOverLocalhost() async throws {
        let fixture = try Fixture()
        let server = LoopbackServer(service: fixture.service)
        let port = try await server.start()
        defer { server.stop() }

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/tasks")!)
        request.setValue("Bearer \(try XCTUnwrap(server.authorizationToken))", forHTTPHeaderField: "Authorization")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{\"title\":\"Socket task\"}".utf8)
        let (data, response) = try await URLSession.shared.data(for: request)

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 201)
        XCTAssertEqual(try JSONDecoder().decode(JarvisTask.self, from: data).title, "Socket task")
    }

    func testLoopbackServerServesPersistedPendingApprovalMetadata() async throws {
        let fixture = try Fixture()
        let task = try await fixture.service.createTask(title: "Approval metadata")
        let request = ToolRequest(taskID: task.id, name: "write_file", sideEffect: .localWrite, target: "/tmp/jarvis-service/secret.txt", payload: "api_key=do-not-leak")
        _ = try await fixture.service.submit(request: request)
        let server = LoopbackServer(service: fixture.service)
        let response = await server.handle(method: "GET", path: "/tasks/\(task.id.uuidString)/requests", body: Data(), peerHost: "127.0.0.1")

        XCTAssertEqual(response.status, 200)
        let json = try JSONSerialization.jsonObject(with: response.body) as? [[String: Any]]
        let item = try XCTUnwrap(json?.first)
        XCTAssertEqual(item["id"] as? String, request.id.uuidString)
        XCTAssertEqual(item["taskID"] as? String, task.id.uuidString)
        XCTAssertEqual(item["digest"] as? String, request.payloadDigest)
        XCTAssertEqual(item["target"] as? String, request.target)
        XCTAssertEqual(item["reason"] as? String, "local write changes local state")
        XCTAssertEqual(item["payload"] as? String, "[REDACTED]")
    }

    func testLoopbackServerServesRedactedTaskTimeline() async throws {
        let fixture = try Fixture()
        let task = try await fixture.service.createTask(title: "Timeline")
        let response = await LoopbackServer(service: fixture.service).handle(
            method: "GET", path: "/tasks/\(task.id.uuidString)/timeline", body: Data(), peerHost: "127.0.0.1")

        XCTAssertEqual(response.status, 200)
        let events = try JSONDecoder().decode([TimelineEvent].self, from: response.body)
        XCTAssertEqual(events.map(\.summary), ["task created"])
        XCTAssertEqual(events.first?.target, "local task service")
    }

    func testShellRequestRoutesToTerminalExecutor() async throws {
        let fixture = try Fixture(terminal: TerminalToolExecutor(timeout: .seconds(5)))
        let task = try await fixture.service.createTask(title: "Run shell through service")
        let request = ToolRequest(
            taskID: task.id,
            name: "shell",
            sideEffect: .localExecute,
            target: "/tmp/jarvis-service",
            payload: "pwd"
        )

        let decision = try await fixture.service.submit(request: request)
        XCTAssertEqual(decision, .requireApproval(reason: "shell command requires explicit approval"))

        try await fixture.service.approve(requestID: request.id, digest: request.payloadDigest)

        for _ in 0..<100 {
            if try fixture.requests.fetch(id: request.id)?.1 == .completed { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(try fixture.tasks.fetch(id: task.id)?.status, .running,
            "Task stays .running after TerminalToolExecutor finishes; call complete(taskID:) to finish")
        XCTAssertEqual(try fixture.requests.fetch(id: request.id)?.1, .completed)
        XCTAssertTrue(
            try fixture.audit.events(for: task.id).contains { $0.summary == "tool result" && $0.result.contains("exit=0") },
            "audit must show TerminalToolExecutor output, not NoOp"
        )
    }

    func testShellRequestRequiresExplicitApproval() async throws {
        let fixture = try Fixture(terminal: TerminalToolExecutor(timeout: .seconds(5)))
        let task = try await fixture.service.createTask(title: "Shell awaits approval")
        let request = ToolRequest(
            taskID: task.id,
            name: "shell",
            sideEffect: .localExecute,
            target: "/tmp/jarvis-service",
            payload: "pwd"
        )

        let decision = try await fixture.service.submit(request: request)

        XCTAssertEqual(decision, .requireApproval(reason: "shell command requires explicit approval"))
        XCTAssertEqual(try fixture.tasks.fetch(id: task.id)?.status, .awaitingApproval)
        XCTAssertEqual(try fixture.requests.fetch(id: request.id)?.1, .pending)
    }

    /// Verifies that `submit(request:)` reaches the TerminalToolExecutor for a
    /// shell command by looking for the executor's "exit=0" marker in the
    /// audit summary. This is distinct from `testShellRequestRoutesToTerminalExecutor`
    /// above which checks the executor output — this test pins
    /// the executor's output format so future refactors can't silently swap
    /// in the NoOpToolExecutor.
    func testSubmitShellCommandReachesTerminalExecutor() async throws {
        let fixture = try Fixture(terminal: TerminalToolExecutor(timeout: .seconds(5)))
        let task = try await fixture.service.createTask(title: "Menu shell command")
        let request = ToolRequest(
            taskID: task.id,
            name: "shell",
            sideEffect: .localExecute,
            target: "/tmp/jarvis-service",
            payload: "pwd"
        )

        _ = try await fixture.service.submit(request: request)
        try await fixture.service.approve(requestID: request.id, digest: request.payloadDigest)

        for _ in 0..<100 {
            if try fixture.requests.fetch(id: request.id)?.1 == .completed { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(try fixture.tasks.fetch(id: task.id)?.status, .running,
            "Task stays .running after TerminalToolExecutor finishes; call complete(taskID:) to finish")
        XCTAssertEqual(try fixture.requests.fetch(id: request.id)?.1, .completed)
        let toolResultAudit = try fixture.audit.events(for: task.id).first { $0.summary == "tool result" }
        XCTAssertNotNil(toolResultAudit, "expected a 'tool result' audit after Terminal executor finishes")
        XCTAssertTrue(
            toolResultAudit?.result.contains("exit=0") == true,
            "audit must carry TerminalToolExecutor's exit=0 marker; got: \(toolResultAudit?.result ?? "<nil>")"
        )
    }

    /// Pins the executor dispatch contract: a `name == "fetch"` request with
    /// `sideEffect == .read` must reach the WebFetchToolExecutor when one is
    /// installed. We assert on the executor's own marker ("HTTP 200") rather
    /// than the body so the assertion survives any change to the canned body
    /// string while still detecting a silent fall-through to NoOpToolExecutor.
    func testFetchRequestRoutesToWebFetchExecutor() async throws {
        let body = "hello-from-mock"
        let session = MockURLSessionFactory.make()
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/plain"])!
            return (response, Data(body.utf8))
        }
        defer { MockURLProtocol.handler = nil }

        let executor = WebFetchToolExecutor(session: session)
        let fixture = try Fixture(webFetch: executor)
        let task = try await fixture.service.createTask(title: "Fetch through service")
        let request = ToolRequest(
            taskID: task.id,
            name: "fetch",
            sideEffect: .read,
            target: "https://example.com/path",
            payload: "https://example.com/path",
            scope: ToolScope(browserProfile: "default")
        )

        let decision = try await fixture.service.submit(request: request)

        XCTAssertEqual(decision, .allow,
            "fetch should be allowed by policy without approval")
        for _ in 0..<100 {
            if try fixture.requests.fetch(id: request.id)?.1 == .completed { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(try fixture.tasks.fetch(id: task.id)?.status, .running,
            "Task stays .running after WebFetchToolExecutor finishes; call complete(taskID:) to finish")
        XCTAssertEqual(try fixture.requests.fetch(id: request.id)?.1, .completed)
        let toolResultAudit = try fixture.audit.events(for: task.id).first { $0.summary == "tool result" }
        XCTAssertNotNil(toolResultAudit, "expected a 'tool result' audit after fetch executor finishes")
        XCTAssertTrue(
            toolResultAudit?.result.contains("HTTP 200") == true,
            "audit must carry WebFetchToolExecutor's HTTP status marker; got: \(toolResultAudit?.result ?? "<nil>")"
        )
        XCTAssertTrue(
            toolResultAudit?.result.contains(body) == true,
            "audit must carry the fetched body so the user can see it; got: \(toolResultAudit?.result ?? "<nil>")"
        )
    }

    /// Pins the executor dispatch contract for screenshots: a
    /// `name == "screenshot"` request with `sideEffect == .read` must reach
    /// the `ScreenshotToolExecutor` when one is installed. The mock closure
    /// returns the PNG magic bytes so we can detect fall-through to a
    /// different executor (the NoOpToolExecutor would produce
    /// "demo executor completed"). The audit log carries the
    /// `ScreenshotToolExecutor`'s own summary format so the assertion
    /// pins the executor identity, not just that *some* tool ran.
    func testScreenshotRequestRoutesToScreenshotExecutor() async throws {
        let executor = ScreenshotToolExecutor(capture: { Data([0x89, 0x50, 0x4E, 0x47]) })
        let fixture = try Fixture(screenshot: executor)
        let task = try await fixture.service.createTask(title: "Screenshot through service")
        let request = ToolRequest(
            taskID: task.id,
            name: "screenshot",
            sideEffect: .read,
            target: "/tmp/jarvis-service/test.png",
            payload: "screen"
        )

        let decision = try await fixture.service.submit(request: request)
        XCTAssertEqual(decision, .allow,
            "screenshot is a .read action that lands inside an approved directory; policy should allow without approval")

        for _ in 0..<100 {
            if try fixture.requests.fetch(id: request.id)?.1 == .completed { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(try fixture.tasks.fetch(id: task.id)?.status, .running,
            "Task stays .running after ScreenshotToolExecutor finishes; call complete(taskID:) to finish")
        XCTAssertEqual(try fixture.requests.fetch(id: request.id)?.1, .completed)
        let toolResultAudit = try fixture.audit.events(for: task.id).first { $0.summary == "tool result" }
        XCTAssertNotNil(toolResultAudit, "expected a 'tool result' audit after Screenshot executor finishes")
        XCTAssertTrue(
            toolResultAudit?.result.contains("Screenshot saved") == true,
            "audit must carry ScreenshotToolExecutor's summary marker; got: \(toolResultAudit?.result ?? "<nil>")"
        )
        XCTAssertFalse(
            toolResultAudit?.result.contains("demo executor completed") == true,
            "audit must not show the NoOp executor's marker; got: \(toolResultAudit?.result ?? "<nil>")"
        )
    }

    /// Pins the executor dispatch contract for accessibility queries: a
    /// `name == "ax_query"` request with `sideEffect == .read` and a bundle-ID
    /// target must reach the `AccessibilityQueryToolExecutor` when one is
    /// installed. The mock closure returns a distinctive tree string so we can
    /// detect fall-through to a different executor (the NoOpToolExecutor would
    /// produce "demo executor completed"). The bundle ID is allowlisted in the
    /// Fixture's `PolicyConfig.applicationBundleIDs`, so the read-side policy
    /// gate allows the request without approval.
    func testAccessibilityQueryRoutesToExecutor() async throws {
        let executor = AccessibilityQueryToolExecutor(query: { _ in "mock accessibility tree" })
        let fixture = try Fixture(accessibility: executor)
        let task = try await fixture.service.createTask(title: "AX query through service")
        let request = ToolRequest(
            taskID: task.id,
            name: "ax_query",
            sideEffect: .read,
            target: "com.apple.finder",
            payload: ""
        )

        let decision = try await fixture.service.submit(request: request)
        XCTAssertEqual(decision, .allow,
            "ax_query is a .read action against an allowlisted bundle ID; policy should allow without approval")

        for _ in 0..<100 {
            if try fixture.requests.fetch(id: request.id)?.1 == .completed { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(try fixture.tasks.fetch(id: task.id)?.status, .running,
            "Task stays .running after AccessibilityQueryToolExecutor finishes; call complete(taskID:) to finish")
        XCTAssertEqual(try fixture.requests.fetch(id: request.id)?.1, .completed)
        let toolResultAudit = try fixture.audit.events(for: task.id).first { $0.summary == "tool result" }
        XCTAssertNotNil(toolResultAudit, "expected a 'tool result' audit after the AX executor finishes")
        XCTAssertTrue(
            toolResultAudit?.result.contains("mock accessibility tree") == true,
            "audit must carry the accessibility tree so the user can see it; got: \(toolResultAudit?.result ?? "<nil>")"
        )
        XCTAssertFalse(
            toolResultAudit?.result.contains("demo executor completed") == true,
            "audit must not show the NoOp executor's marker; got: \(toolResultAudit?.result ?? "<nil>")"
        )
    }

    /// Drives a single executor run to completion and then verifies that
    /// `complete(taskID:)` is the only path that moves the task to
    /// `.completed`. After the executor finishes the task must be `.running`;
    /// the new action emits a "task completed" audit event so the user can
    /// see the call in the timeline.
    func testCompleteTransitionsRunningTaskToCompleted() async throws {
        let fixture = try Fixture()
        let task = try await fixture.service.createTask(title: "Complete happy path")
        let request = ToolRequest(taskID: task.id, name: "read_file", sideEffect: .read,
            target: "/tmp/jarvis-service/anything", payload: "")
        _ = try await fixture.service.submit(request: request)

        for _ in 0..<50 {
            if try fixture.requests.fetch(id: request.id)?.1 == .completed { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }

        XCTAssertEqual(try fixture.tasks.fetch(id: task.id)?.status, .running,
            "executor success leaves the task in .running; complete(taskID:) is the only path to .completed")

        try await fixture.service.complete(taskID: task.id)
        XCTAssertEqual(try fixture.tasks.fetch(id: task.id)?.status, .completed,
            "complete(taskID:) must transition .running -> .completed")
        XCTAssertTrue(try fixture.audit.events(for: task.id).contains { $0.summary == "task completed" },
            "complete(taskID:) must record a 'task completed' audit event")
    }

    /// `complete(taskID:)` must reject calls made on a task that has already
    /// reached a terminal state (`.completed`, `.cancelled`, `.failed`) with
    /// `illegalTransition`. The test exercises each terminal state in turn.
    func testCompleteRejectsAlreadyTerminalTask() async throws {
        // .completed: drive a successful run then complete() twice
        let fixture = try Fixture()
        let completedTask = try await fixture.service.createTask(title: "Already completed")
        let completedRequest = ToolRequest(taskID: completedTask.id, name: "read_file", sideEffect: .read,
            target: "/tmp/jarvis-service/anything", payload: "")
        _ = try await fixture.service.submit(request: completedRequest)
        for _ in 0..<50 {
            if try fixture.requests.fetch(id: completedRequest.id)?.1 == .completed { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        try await fixture.service.complete(taskID: completedTask.id)
        XCTAssertEqual(try fixture.tasks.fetch(id: completedTask.id)?.status, .completed)

        await XCTAssertThrowsErrorAsync(try await fixture.service.complete(taskID: completedTask.id)) {
            XCTAssertEqual($0 as? TaskServiceError, .illegalTransition(from: .completed, to: .completed))
        }

        // .cancelled: cancel and try to complete
        let cancelledTask = try await fixture.service.createTask(title: "Already cancelled")
        try await fixture.service.cancel(taskID: cancelledTask.id)
        XCTAssertEqual(try fixture.tasks.fetch(id: cancelledTask.id)?.status, .cancelled)
        await XCTAssertThrowsErrorAsync(try await fixture.service.complete(taskID: cancelledTask.id)) {
            XCTAssertEqual($0 as? TaskServiceError, .illegalTransition(from: .cancelled, to: .completed))
        }

        // .failed: trigger an executor failure then try to complete
        let failingFixture = try Fixture(executor: ThrowingExecutor())
        let failedTask = try await failingFixture.service.createTask(title: "Already failed")
        let failedRequest = ToolRequest(taskID: failedTask.id, name: "read_file", sideEffect: .read,
            target: "/tmp/jarvis-service/anything", payload: "")
        await XCTAssertThrowsErrorAsync(try await failingFixture.service.submit(request: failedRequest))
        XCTAssertEqual(try failingFixture.tasks.fetch(id: failedTask.id)?.status, .failed)
        await XCTAssertThrowsErrorAsync(try await failingFixture.service.complete(taskID: failedTask.id)) {
            XCTAssertEqual($0 as? TaskServiceError, .illegalTransition(from: .failed, to: .completed))
        }
    }

    /// Pins the multi-request behaviour: a single task carries two sequential
    /// tool requests, both run to completion, the task stays in `.running`
    /// throughout, and only the explicit `complete(taskID:)` call moves it
    /// to `.completed`. This is the core contract that the rest of the
    /// multi-request workflow depends on.
    func testMultiRequestWorkflowExecutesSequentially() async throws {
        let fixture = try Fixture()
        let task = try await fixture.service.createTask(title: "Multi-request workflow")

        // First request: .read action, allowed by policy, runs to completion.
        let first = ToolRequest(taskID: task.id, name: "read_file", sideEffect: .read,
            target: "/tmp/jarvis-service/first.txt", payload: "")
        let firstDecision = try await fixture.service.submit(request: first)
        XCTAssertEqual(firstDecision, .allow, "first .read request must be allowed without approval")

        for _ in 0..<50 {
            if try fixture.requests.fetch(id: first.id)?.1 == .completed { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertEqual(try fixture.requests.fetch(id: first.id)?.1, .completed,
            "first request must reach .completed")
        XCTAssertEqual(try fixture.tasks.fetch(id: task.id)?.status, .running,
            "after first request the task stays in .running; submit() can drive another request")

        // Second request on the SAME task: .localWrite requires approval, lands in
        // .awaitingApproval. Without explicit complete() the task must remain
        // .running throughout.
        let second = ToolRequest(taskID: task.id, name: "write_file", sideEffect: .localWrite,
            target: "/tmp/jarvis-service/second.txt", payload: "second-step")
        let secondDecision = try await fixture.service.submit(request: second)
        XCTAssertEqual(secondDecision, .requireApproval(reason: "local write changes local state"),
            "second request must require approval before the executor runs")
        XCTAssertEqual(try fixture.tasks.fetch(id: task.id)?.status, .awaitingApproval,
            "task moves to .awaitingApproval when the second request needs approval")
        XCTAssertEqual(try fixture.requests.fetch(id: second.id)?.1, .pending)

        // Approve the second request and wait for the executor to finish.
        try await fixture.service.approve(requestID: second.id, digest: second.payloadDigest)
        for _ in 0..<50 {
            if try fixture.requests.fetch(id: second.id)?.1 == .completed { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertEqual(try fixture.requests.fetch(id: second.id)?.1, .completed,
            "second request must reach .completed after approval")
        XCTAssertEqual(try fixture.tasks.fetch(id: task.id)?.status, .running,
            "task stays in .running after second executor finishes")

        // Now both requests have run; explicit complete() must move the task to .completed.
        try await fixture.service.complete(taskID: task.id)
        XCTAssertEqual(try fixture.tasks.fetch(id: task.id)?.status, .completed,
            "complete(taskID:) must transition the task to .completed after both requests ran")

        // Audit log must show both tool results and the explicit completion.
        let summaries = try fixture.audit.events(for: task.id).map(\.summary)
        XCTAssertEqual(summaries.filter { $0 == "tool result" }.count, 2,
            "audit must record a 'tool result' event for each of the two executor runs")
        XCTAssertTrue(summaries.contains("task completed"),
            "audit must record the explicit complete(taskID:) call")
    }

    // MARK: - Concurrent pending approvals

    /// Pins the core capability of this change: a single task may hold more than
    /// one `.pending` approval at a time. Submitting a second `.localWrite`
    /// request while the first is still pending must succeed, leave the task in
    /// `.awaitingApproval`, and expose both requests through
    /// `listPendingApprovalRequests(taskID:)`.
    func testTwoPendingApprovalsCoexistOnOneTask() async throws {
        let fixture = try Fixture()
        let (task, first, second) = try await fixture.makeTaskWithTwoPendingApprovals(title: "Two pending approvals")

        XCTAssertEqual(try fixture.tasks.fetch(id: task.id)?.status, .awaitingApproval,
            "the task stays in .awaitingApproval while any request is pending")
        XCTAssertEqual(try fixture.requests.fetch(id: first.id)?.1, .pending)
        XCTAssertEqual(try fixture.requests.fetch(id: second.id)?.1, .pending)

        let pending = try await fixture.service.listPendingApprovalRequests(taskID: task.id)
        XCTAssertEqual(Set(pending.map(\.id)), Set([first.id, second.id]),
            "both pending approvals must be visible to the approver UI")
    }

    /// Approving one of two pending requests must not clear `.awaitingApproval`:
    /// the second request still needs a decision, so the task status is
    /// aggregated from the outstanding requests rather than hard-coded.
    func testApprovingOneOfTwoPendingsKeepsTaskAwaitingApproval() async throws {
        let fixture = try Fixture()
        let (task, first, second) = try await fixture.makeTaskWithTwoPendingApprovals(title: "Approve one of two")

        try await fixture.service.approve(requestID: first.id, digest: first.payloadDigest)
        try await fixture.waitForRequest(id: first.id, status: .completed)

        XCTAssertEqual(try fixture.tasks.fetch(id: task.id)?.status, .awaitingApproval,
            "the second pending request keeps the task in .awaitingApproval after the first is approved")
        XCTAssertEqual(try fixture.requests.fetch(id: second.id)?.1, .pending,
            "the untouched request must remain pending")
    }

    /// Approving the last outstanding pending request runs it and, because no
    /// request is left outstanding, returns the task to `.running` — the same
    /// resting state a single-request approval produces.
    func testApprovingBothPendingsRunsBothAndReturnsToRunning() async throws {
        let fixture = try Fixture()
        let (task, first, second) = try await fixture.makeTaskWithTwoPendingApprovals(title: "Approve both")

        try await fixture.service.approve(requestID: first.id, digest: first.payloadDigest)
        try await fixture.waitForRequest(id: first.id, status: .completed)
        XCTAssertEqual(try fixture.tasks.fetch(id: task.id)?.status, .awaitingApproval,
            "the task waits for the second decision")

        try await fixture.service.approve(requestID: second.id, digest: second.payloadDigest)
        try await fixture.waitForRequest(id: second.id, status: .completed)

        XCTAssertEqual(try fixture.requests.fetch(id: first.id)?.1, .completed)
        XCTAssertEqual(try fixture.requests.fetch(id: second.id)?.1, .completed)
        XCTAssertEqual(try fixture.tasks.fetch(id: task.id)?.status, .running,
            "with nothing outstanding the task returns to .running after the executor finishes")
        XCTAssertEqual(try fixture.audit.events(for: task.id).filter { $0.summary == "tool result" }.count, 2,
            "each approved request must record its own 'tool result' audit event")
    }

    /// Rejecting one of two pendings leaves the task `.awaitingApproval` and
    /// keeps the other request actionable: the surviving request can still be
    /// approved and run to completion.
    func testRejectingOneOfTwoPendingsKeepsOtherActionable() async throws {
        let fixture = try Fixture()
        let (task, first, second) = try await fixture.makeTaskWithTwoPendingApprovals(title: "Reject one of two")

        try await fixture.service.reject(requestID: first.id)

        XCTAssertEqual(try fixture.requests.fetch(id: first.id)?.1, .rejected)
        XCTAssertEqual(try fixture.tasks.fetch(id: task.id)?.status, .awaitingApproval,
            "the surviving pending request keeps the task in .awaitingApproval")
        XCTAssertEqual(try fixture.requests.fetch(id: second.id)?.1, .pending)

        try await fixture.service.approve(requestID: second.id, digest: second.payloadDigest)
        try await fixture.waitForRequest(id: second.id, status: .completed)

        XCTAssertEqual(try fixture.requests.fetch(id: second.id)?.1, .completed,
            "the request that outlived the rejection must still be approvable")
        XCTAssertEqual(try fixture.tasks.fetch(id: task.id)?.status, .running)
    }

    /// Rejecting the *last* outstanding pending request preserves the original
    /// single-request semantics: the task lands in `.blocked`.
    func testRejectingLastPendingBlocksTask() async throws {
        let fixture = try Fixture()
        let (task, first, second) = try await fixture.makeTaskWithTwoPendingApprovals(title: "Reject both")

        try await fixture.service.reject(requestID: first.id)
        XCTAssertEqual(try fixture.tasks.fetch(id: task.id)?.status, .awaitingApproval,
            "one pending request remains after the first rejection")

        try await fixture.service.reject(requestID: second.id)

        XCTAssertEqual(try fixture.requests.fetch(id: first.id)?.1, .rejected)
        XCTAssertEqual(try fixture.requests.fetch(id: second.id)?.1, .rejected)
        XCTAssertEqual(try fixture.tasks.fetch(id: task.id)?.status, .blocked,
            "rejecting the last pending request blocks the task, as before")
    }

    /// A task that is `.awaitingApproval` is still alive, so an `.allow`
    /// request may be submitted and executed without disturbing the pending
    /// approval. Once the executor finishes, the task must fall back to
    /// `.awaitingApproval` because a decision is still owed.
    func testSubmittingWhileAwaitingApprovalIsAllowed() async throws {
        let fixture = try Fixture()
        let task = try await fixture.service.createTask(title: "Submit while awaiting approval")
        let pendingRequest = ToolRequest(taskID: task.id, name: "write_file", sideEffect: .localWrite,
            target: "/tmp/jarvis-service/needs-approval.txt", payload: "gated contents")
        let pendingDecision = try await fixture.service.submit(request: pendingRequest)
        XCTAssertEqual(pendingDecision, .requireApproval(reason: "local write changes local state"))
        XCTAssertEqual(try fixture.tasks.fetch(id: task.id)?.status, .awaitingApproval)

        let readRequest = ToolRequest(taskID: task.id, name: "read_file", sideEffect: .read,
            target: "/tmp/jarvis-service/reads-freely.txt", payload: "")
        let decision = try await fixture.service.submit(request: readRequest)

        XCTAssertEqual(decision, .allow, "a .read request is allowed even while an approval is pending")
        XCTAssertEqual(try fixture.requests.fetch(id: readRequest.id)?.1, .completed,
            "the allowed request executes immediately")
        XCTAssertEqual(try fixture.requests.fetch(id: pendingRequest.id)?.1, .pending,
            "the pending approval is untouched by the allowed request")
        XCTAssertEqual(try fixture.tasks.fetch(id: task.id)?.status, .awaitingApproval,
            "the outstanding pending approval keeps the task in .awaitingApproval")
    }

    /// Cancelling a task must sweep up every outstanding request, not just the
    /// first one, and record the task as `.cancelled`.
    func testCancelWithMultiplePendingsCancelsAll() async throws {
        let fixture = try Fixture()
        let (task, first, second) = try await fixture.makeTaskWithTwoPendingApprovals(title: "Cancel multiple pendings")

        try await fixture.service.cancel(taskID: task.id)

        XCTAssertEqual(try fixture.tasks.fetch(id: task.id)?.status, .cancelled)
        XCTAssertEqual(try fixture.requests.fetch(id: first.id)?.1, .cancelled)
        XCTAssertEqual(try fixture.requests.fetch(id: second.id)?.1, .cancelled,
            "every pending request must be cancelled alongside the task")
    }

    /// Regression guard for the already-working `.allow` path: two concurrent
    /// allowed requests on one task both run to completion — unlike
    /// `testCancellationCancelsMultipleExecutionsForOneTask`, nothing cancels
    /// them. This is the behaviour the approval changes must not disturb.
    func testConcurrentAllowRequestsRunInParallel() async throws {
        let executor = MultiSuspendingExecutor()
        let fixture = try Fixture(executor: executor)
        let task = try await fixture.service.createTask(title: "Parallel allow requests")
        let requests = (0..<2).map { ToolRequest(taskID: task.id, name: "read_file", sideEffect: .read,
            target: "/tmp/jarvis-service/\($0)", payload: "") }
        let submissions = requests.map { request in Task.detached { try? await fixture.service.submit(request: request) } }
        await executor.started(ids: Set(requests.map(\.id)))

        requests.forEach { executor.resume(id: $0.id) }
        for submission in submissions { _ = await submission.result }

        for request in requests {
            XCTAssertEqual(try fixture.requests.fetch(id: request.id)?.1, .completed,
                "both allowed requests must reach .completed when nothing cancels them")
        }
        XCTAssertEqual(try fixture.tasks.fetch(id: task.id)?.status, .running)
        XCTAssertEqual(try fixture.audit.events(for: task.id).filter { $0.summary == "tool result" }.count, 2)
    }

    /// The state machine must tolerate status-preserving writes. Approving or
    /// submitting while the task is already `.running` or `.awaitingApproval`
    /// rewrites the same value, which would otherwise be an illegal transition.
    func testStateMachineAllowsSelfTransitions() throws {
        XCTAssertNoThrow(try TaskStateMachine.validate(from: .running, to: .running))
        XCTAssertNoThrow(try TaskStateMachine.validate(from: .awaitingApproval, to: .awaitingApproval))
        XCTAssertTrue(TaskStateMachine.allowedDestinations(for: .running).contains(.running))
        XCTAssertTrue(TaskStateMachine.allowedDestinations(for: .awaitingApproval).contains(.awaitingApproval))
    }

    // MARK: - Failure path aggregation

    /// Pins the fix for the failure-path aggregation bug: when one of two
    /// pending requests is approved and its executor throws, the surviving
    /// pending request must keep the task in `.awaitingApproval`. The task
    /// must NOT be hard-coded to `.failed` — that would orphan the second
    /// pending request because the state machine has no exit from `.failed`.
    /// Approving and running the surviving request must still work after the
    /// failure.
    func testFailurePathAggregatesWithPendingRequest() async throws {
        let fixture = try Fixture(executor: ThrowingExecutor())
        let (task, first, second) = try await fixture.makeTaskWithTwoPendingApprovals(title: "Failure with survivor")

        try await fixture.service.approve(requestID: first.id, digest: first.payloadDigest)
        try await fixture.waitForRequest(id: first.id, status: .failed)

        XCTAssertEqual(try fixture.tasks.fetch(id: task.id)?.status, .awaitingApproval,
            "the surviving pending request must keep the task in .awaitingApproval after the first fails")
        XCTAssertEqual(try fixture.requests.fetch(id: first.id)?.1, .failed)
        XCTAssertEqual(try fixture.requests.fetch(id: second.id)?.1, .pending,
            "the untouched request must remain pending")

        // The surviving request must still be actionable after the failure.
        try await fixture.service.approve(requestID: second.id, digest: second.payloadDigest)
        try await fixture.waitForRequest(id: second.id, status: .failed)
        XCTAssertEqual(try fixture.requests.fetch(id: second.id)?.1, .failed,
            "the surviving request must still be approvable after its sibling failed")
    }

    /// Pins the failure-path fallback: when the only outstanding request is the
    /// one that failed, the task lands in `.failed`. This is the unchanged
    /// single-request semantics — the new aggregation rule only diverges when
    /// another request is still outstanding.
    func testFailurePathWithNoPendingMarksTaskFailed() async throws {
        let fixture = try Fixture(executor: ThrowingExecutor())
        let task = try await fixture.service.createTask(title: "Failure with no survivors")
        let request = ToolRequest(taskID: task.id, name: "write_file", sideEffect: .localWrite,
            target: "/tmp/jarvis-service/alone.txt", payload: "only payload")
        _ = try await fixture.service.submit(request: request)
        XCTAssertEqual(try fixture.tasks.fetch(id: task.id)?.status, .awaitingApproval,
            "submitting a .localWrite lands the task in .awaitingApproval before approval")

        try await fixture.service.approve(requestID: request.id, digest: request.payloadDigest)
        try await fixture.waitForRequest(id: request.id, status: .failed)

        XCTAssertEqual(try fixture.tasks.fetch(id: task.id)?.status, .failed,
            "with no other outstanding requests, failure falls back to .failed")
        XCTAssertEqual(try fixture.requests.fetch(id: request.id)?.1, .failed)
    }
}

private final class Fixture: @unchecked Sendable {
    let database: Database
    let tasks: SQLiteTaskRepository
    let audit: SQLiteAuditRepository
    let requests: SQLiteToolRequestRepository
    let approvals: SQLiteApprovalRepository
    let service: TaskService

    init(path: String = ":memory:", executor: any ToolExecutor = NoOpToolExecutor(), terminal: TerminalToolExecutor? = nil, webFetch: WebFetchToolExecutor? = nil, screenshot: ScreenshotToolExecutor? = nil, accessibility: AccessibilityQueryToolExecutor? = nil, browserOpen: BrowserOpenExecutor? = nil, exactBrowserEnabled: Bool = false, browserTicketLifetime: TimeInterval = 300) throws {
        database = try Database(path: path)
        try database.migrate()
        tasks = SQLiteTaskRepository(database: database)
        audit = SQLiteAuditRepository(database: database)
        requests = SQLiteToolRequestRepository(database: database)
        approvals = SQLiteApprovalRepository(database: database)
        let policyConfig = PolicyConfig(
            approvedDirectories: ["/tmp/jarvis-service"],
            commandNames: ["shell", "swift", "xcodebuild"],
            browserProfiles: ["default"],
            sites: ["example.com"],
            applicationBundleIDs: ["com.apple.Safari", "com.apple.finder"]
        )
        service = try TaskService(
            taskRepository: tasks,
            auditRepository: audit,
            policy: Policy(),
            policyConfig: policyConfig, executor: executor, terminal: terminal, webFetch: webFetch, screenshot: screenshot, accessibility: accessibility, browserOpen: browserOpen,
            requestRepository: requests, approvalRepository: approvals, unitOfWork: SQLitePersistenceUnitOfWork(database: database), exactBrowserEnabled: exactBrowserEnabled, browserTicketLifetime: browserTicketLifetime
        )
    }

    func makeService() throws -> TaskService {
        try TaskService(taskRepository: tasks, auditRepository: audit, policy: Policy(), policyConfig: PolicyConfig(approvedDirectories: ["/tmp/jarvis-service"]), requestRepository: requests, approvalRepository: approvals, unitOfWork: SQLitePersistenceUnitOfWork(database: database))
    }

    /// Creates a task and submits two `.localWrite` requests. The deterministic
    /// policy routes both to `.requireApproval`, so the task ends up in
    /// `.awaitingApproval` holding two `.pending` requests — the concurrent
    /// pending-approval state this suite exercises. Returns the task and both
    /// requests in submission order.
    func makeTaskWithTwoPendingApprovals(title: String) async throws -> (JarvisTask, ToolRequest, ToolRequest) {
        let task = try await service.createTask(title: title)
        let first = ToolRequest(taskID: task.id, name: "write_file", sideEffect: .localWrite,
            target: "/tmp/jarvis-service/first.txt", payload: "first payload")
        let second = ToolRequest(taskID: task.id, name: "write_file", sideEffect: .localWrite,
            target: "/tmp/jarvis-service/second.txt", payload: "second payload")
        let firstDecision = try await service.submit(request: first)
        let secondDecision = try await service.submit(request: second)
        XCTAssertEqual(firstDecision, .requireApproval(reason: "local write changes local state"))
        XCTAssertEqual(secondDecision, .requireApproval(reason: "local write changes local state"))
        XCTAssertEqual(try tasks.fetch(id: task.id)?.status, .awaitingApproval)
        return (task, first, second)
    }

    /// Polls until the request reaches `status`, matching the wait loops the
    /// rest of the suite uses for executor-backed work. A timeout simply
    /// returns, letting the caller's assertion report the mismatch.
    func waitForRequest(id: UUID, status: ToolRequestStatus, iterations: Int = 100) async throws {
        for _ in 0..<iterations {
            if try requests.fetch(id: id)?.1 == status { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

private struct ThrowingExecutor: ToolExecutor { func execute(_ request: ToolRequest) async throws -> ToolResult { struct Expected: Error {}; throw Expected() } }

private final class SuspendingExecutor: ToolExecutor, @unchecked Sendable {
    private let lock = NSLock(); private var continuation: CheckedContinuation<ToolResult, Never>?
    func execute(_ request: ToolRequest) async throws -> ToolResult { await withCheckedContinuation { continuation in lock.withLock { self.continuation = continuation } } }
    func started() async { for _ in 0..<100 { if lock.withLock({ continuation != nil }) { return }; try? await Task.sleep(nanoseconds: 1_000_000) } }
    func resume() { lock.withLock { continuation?.resume(returning: ToolResult(summary: "late")); continuation = nil } }
}

private final class MultiSuspendingExecutor: ToolExecutor, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: CheckedContinuation<ToolResult, Never>] = [:]
    func execute(_ request: ToolRequest) async throws -> ToolResult {
        await withCheckedContinuation { continuation in lock.withLock { continuations[request.id] = continuation } }
    }
    func started(ids: Set<UUID>) async {
        for _ in 0..<100 {
            if lock.withLock({ Set(continuations.keys).isSuperset(of: ids) }) { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }
    func resume(id: UUID) {
        lock.withLock { continuations.removeValue(forKey: id)?.resume(returning: ToolResult(summary: "late")) }
    }
}

private final class BlockingAllowPolicy: PolicyEvaluator, @unchecked Sendable {
    private let condition = NSCondition()
    private var entered = false
    private var isOpen = false

    func evaluate(_ request: ToolRequest, config: PolicyConfig) -> PolicyDecision {
        condition.lock()
        entered = true
        condition.broadcast()
        while !isOpen { condition.wait() }
        condition.unlock()
        return .allow
    }

    func waitForEvaluation(timeout: TimeInterval = 1) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while !entered {
            guard condition.wait(until: deadline) else { return false }
        }
        return true
    }

    func open() {
        condition.lock()
        isOpen = true
        condition.broadcast()
        condition.unlock()
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw")
    } catch {
        errorHandler(error)
    }
}

private final class BrowserRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded = 0
    var count: Int { lock.withLock { recorded } }
    func record(_ url: URL) { lock.withLock { recorded += 1 } }
}

private struct AllowTestSafariPolicy: PolicyEvaluator {
    func evaluate(_ request: ToolRequest, config: PolicyConfig) -> PolicyDecision {
        request.name == "safari_read" ? .requireApproval(reason: "test only") : .deny(reason: "not used")
    }
}

extension TaskServiceTests {
    func testSafariResultIsSingleUseAndNeverWrittenToAudit() async throws {
        #if !JARVIS_SAFARI_EXPERIMENT_BUILD && !JARVIS_COMBINED_EXPERIMENT
        throw XCTSkip("Safari service is unavailable in ordinary builds")
        #endif
        let fixture = try Fixture()
        let secret = "private-page-unique-contents"
        let capture = SafariStaticFixture(text: secret)
        let service = try TaskService(taskRepository: fixture.tasks, auditRepository: fixture.audit, policy: AllowTestSafariPolicy(), enableSafariRead: true, requestRepository: fixture.requests, approvalRepository: fixture.approvals, unitOfWork: SQLitePersistenceUnitOfWork(database: fixture.database))
        service.safariCaptureFactory = { capture }
        let task = try await service.createTask(title: "read page")
        let request = try await service.prepareSafariRead(taskID: task.id)
        _ = try await service.submit(request: request)
        try await service.approve(requestID: request.id, digest: request.payloadDigest)
        try await fixture.waitForRequest(id: request.id, status: .completed)
        let audit = try fixture.audit.events(for: task.id)
        XCTAssertTrue(audit.contains { $0.summary == "ephemeral tool result" && $0.result == request.id.uuidString && $0.requestID == request.id })
        XCTAssertTrue(audit.allSatisfy { !$0.result.contains(secret) && !$0.target.contains(secret) })
        let wrong = try await service.takeEphemeralToolResult(taskID: task.id, requestID: request.id, digest: "wrong")
        XCTAssertNil(wrong)
        let result = try await service.takeEphemeralToolResult(taskID: task.id, requestID: request.id, digest: request.payloadDigest)
        XCTAssertEqual(result, secret)
        let again = try await service.takeEphemeralToolResult(taskID: task.id, requestID: request.id, digest: request.payloadDigest)
        XCTAssertNil(again)
    }
}

private actor DelayedPage {
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func hasStarted() -> Bool { continuation != nil }
    func release() { continuation?.resume(); continuation = nil }
}

extension TaskServiceTests {
    func testCancellationWhileSafariResultPendingDoesNotStoreOrPublishIt() async throws {
        #if !JARVIS_SAFARI_EXPERIMENT_BUILD && !JARVIS_COMBINED_EXPERIMENT
        throw XCTSkip("Safari service is unavailable in ordinary builds")
        #endif
        let fixture = try Fixture(), page = DelayedPage()
        let capture = SafariStaticFixture(text: "private-cancelled-page", page: page)
        let service = try TaskService(taskRepository: fixture.tasks, auditRepository: fixture.audit, policy: AllowTestSafariPolicy(), enableSafariRead: true, requestRepository: fixture.requests, approvalRepository: fixture.approvals, unitOfWork: SQLitePersistenceUnitOfWork(database: fixture.database))
        service.safariCaptureFactory = { capture }
        let task = try await service.createTask(title: "read page")
        let request = try await service.prepareSafariRead(taskID: task.id)
        _ = try await service.submit(request: request)
        try await service.approve(requestID: request.id, digest: request.payloadDigest)
        for _ in 0..<100 { if await page.hasStarted() { break }; try await Task.sleep(for: .milliseconds(10)) }
        let started = await page.hasStarted()
        XCTAssertTrue(started)
        try await service.cancel(taskID: task.id)
        await page.release()
        await service.waitForTrackedExecution(request.id)
        let result = try await service.takeEphemeralToolResult(taskID: task.id, requestID: request.id, digest: request.payloadDigest)
        XCTAssertNil(result)
        let events = try fixture.audit.events(for: task.id)
        XCTAssertFalse(events.contains { $0.summary == "ephemeral tool result" || $0.result.contains("private-cancelled-page") })
    }
}

private actor SafariCaptureFixture: SafariTargetCapturing {
    let target = SafariCapturedTarget(url: "https://example.com/private?token=supersecret", processID: 77, windowIdentity: UUID())
    func capture() async throws -> SafariCapturedTarget { target }
    func verify(_ target: SafariCapturedTarget) async throws { guard target == self.target else { throw SafariAXReadError.targetChanged } }
    func read(_ target: SafariCapturedTarget) async throws -> String { "private page text" }
}

extension TaskServiceTests {
    func testSafariCapturePreviewApprovalAndReadRemainPrivate() async throws {
        #if !JARVIS_SAFARI_EXPERIMENT_BUILD && !JARVIS_COMBINED_EXPERIMENT
        throw XCTSkip("Safari service is unavailable in ordinary builds")
        #endif
        let fixture = try Fixture()
        let capture = SafariCaptureFixture()
        let service = try TaskService(taskRepository: fixture.tasks, auditRepository: fixture.audit, policy: Policy(allowSafariRead: true), enableSafariRead: true, requestRepository: fixture.requests, approvalRepository: fixture.approvals, unitOfWork: SQLitePersistenceUnitOfWork(database: fixture.database))
        service.safariCaptureFactory = { capture }
        let task = try await service.createTask(title: "read current page")
        let request = try await service.prepareSafariRead(taskID: task.id)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(request), as: UTF8.self).contains("supersecret"))
        let decision = try await service.submit(request: request)
        guard case .requireApproval = decision else { return XCTFail("explicit approval is required") }
        let persisted = try XCTUnwrap(fixture.requests.fetch(id: request.id)?.0)
        XCTAssertFalse(persisted.target.contains("supersecret"))
        XCTAssertFalse(persisted.payload.contains("supersecret"))
        let pending = try await service.listPendingApprovalRequests(taskID: task.id)
        XCTAssertEqual(pending.first?.target, "https://example.com/private?token=supersecret")
        XCTAssertTrue(pending.first?.reason.contains("not an atomic snapshot") == true)
        try await service.approve(requestID: request.id, digest: request.payloadDigest)
        try await fixture.waitForRequest(id: request.id, status: .completed)
        let result = try await service.takeEphemeralToolResult(taskID: task.id, requestID: request.id, digest: request.payloadDigest)
        XCTAssertEqual(result, "private page text")
        let events = try fixture.audit.events(for: task.id)
        XCTAssertTrue(events.allSatisfy { !$0.target.contains("supersecret") && !$0.result.contains("supersecret") && !$0.result.contains("private page text") })
    }
}

private actor SafariStaticFixture: SafariTargetCapturing {
    let target = SafariCapturedTarget(url: "https://example.com/", processID: 77, windowIdentity: UUID())
    let text: String
    let page: DelayedPage?
    init(text: String, page: DelayedPage? = nil) { self.text = text; self.page = page }
    func capture() async throws -> SafariCapturedTarget { target }
    func verify(_ target: SafariCapturedTarget) async throws { guard target == self.target else { throw SafariAXReadError.targetChanged } }
    func read(_ target: SafariCapturedTarget) async throws -> String { if let page { await page.wait() }; return text }
}

extension TaskServiceTests {
    func testSafariFeatureIsDisabledByDefault() async throws {
        let fixture = try Fixture()
        let task = try await fixture.service.createTask(title: "read page")
        let available = await fixture.service.isSafariReadAvailable()
        XCTAssertFalse(available)
        await XCTAssertThrowsErrorAsync(try await fixture.service.prepareSafariRead(taskID: task.id))
    }

    func testSafariApprovalCannotBeReplayedAfterRestartOrChangedDigest() async throws {
        #if !JARVIS_SAFARI_EXPERIMENT_BUILD && !JARVIS_COMBINED_EXPERIMENT
        throw XCTSkip("Safari service is unavailable in ordinary builds")
        #endif
        let fixture = try Fixture()
        let capture = SafariCaptureFixture()
        let service = try TaskService(taskRepository: fixture.tasks, auditRepository: fixture.audit, policy: Policy(allowSafariRead: true), enableSafariRead: true, requestRepository: fixture.requests, approvalRepository: fixture.approvals, unitOfWork: SQLitePersistenceUnitOfWork(database: fixture.database))
        service.safariCaptureFactory = { capture }
        let task = try await service.createTask(title: "read page")
        let request = try await service.prepareSafariRead(taskID: task.id)
        _ = try await service.submit(request: request)
        await XCTAssertThrowsErrorAsync(try await service.approve(requestID: request.id, digest: "wrong"))
        let restarted = try TaskService(taskRepository: fixture.tasks, auditRepository: fixture.audit, policy: Policy(allowSafariRead: true), enableSafariRead: true, requestRepository: fixture.requests, approvalRepository: fixture.approvals, unitOfWork: SQLitePersistenceUnitOfWork(database: fixture.database))
        let pending = try await restarted.listPendingApprovalRequests(taskID: task.id)
        XCTAssertTrue(pending.first?.target.contains("expired") == true)
        await XCTAssertThrowsErrorAsync(try await restarted.approve(requestID: request.id, digest: request.payloadDigest))
        let audit = try fixture.audit.events(for: task.id)
        XCTAssertTrue(audit.allSatisfy { !$0.result.contains("supersecret") && !$0.target.contains("supersecret") })
    }

    func testRejectedSafariPreviewCannotBeApprovedAgain() async throws {
        #if !JARVIS_SAFARI_EXPERIMENT_BUILD && !JARVIS_COMBINED_EXPERIMENT
        throw XCTSkip("Safari service is unavailable in ordinary builds")
        #endif
        let fixture = try Fixture(), capture = SafariCaptureFixture()
        let service = try TaskService(taskRepository: fixture.tasks, auditRepository: fixture.audit, policy: Policy(allowSafariRead: true), enableSafariRead: true, requestRepository: fixture.requests, approvalRepository: fixture.approvals, unitOfWork: SQLitePersistenceUnitOfWork(database: fixture.database))
        service.safariCaptureFactory = { capture }
        let task = try await service.createTask(title: "read page")
        let request = try await service.prepareSafariRead(taskID: task.id)
        _ = try await service.submit(request: request)
        try await service.reject(requestID: request.id)
        await XCTAssertThrowsErrorAsync(try await service.approve(requestID: request.id, digest: request.payloadDigest))
        let pending = try await service.listPendingApprovalRequests(taskID: task.id)
        XCTAssertTrue(pending.isEmpty)
    }
}

private struct UnsafeAllowSafariPolicy: PolicyEvaluator {
    func evaluate(_ request: ToolRequest, config: PolicyConfig) -> PolicyDecision { .allow }
}

extension TaskServiceTests {
    func testSafariCannotExecuteWhenInjectedPolicyWouldAllowWithoutApproval() async throws {
        #if !JARVIS_SAFARI_EXPERIMENT_BUILD && !JARVIS_COMBINED_EXPERIMENT
        throw XCTSkip("Safari service is unavailable in ordinary builds")
        #endif
        let fixture = try Fixture(), capture = SafariCaptureFixture()
        let service = try TaskService(taskRepository: fixture.tasks, auditRepository: fixture.audit, policy: UnsafeAllowSafariPolicy(), enableSafariRead: true, requestRepository: fixture.requests, approvalRepository: fixture.approvals, unitOfWork: SQLitePersistenceUnitOfWork(database: fixture.database))
        service.safariCaptureFactory = { capture }
        let task = try await service.createTask(title: "read page")
        let request = try await service.prepareSafariRead(taskID: task.id)
        let decision = try await service.submit(request: request)
        XCTAssertEqual(decision, .deny(reason: "Safari reading requires explicit approval"))
        XCTAssertNil(try fixture.requests.fetch(id: request.id))
    }

    func testSafariRejectedOrCancelledPreviewCannotBeUsed() async throws {
        #if !JARVIS_SAFARI_EXPERIMENT_BUILD && !JARVIS_COMBINED_EXPERIMENT
        throw XCTSkip("Safari service is unavailable in ordinary builds")
        #endif
        for cancel in [false, true] {
            let fixture = try Fixture(), capture = SafariCaptureFixture()
            let service = try TaskService(taskRepository: fixture.tasks, auditRepository: fixture.audit, policy: Policy(allowSafariRead: true), enableSafariRead: true, requestRepository: fixture.requests, approvalRepository: fixture.approvals, unitOfWork: SQLitePersistenceUnitOfWork(database: fixture.database))
            service.safariCaptureFactory = { capture }
            let task = try await service.createTask(title: "read page")
            let request = try await service.prepareSafariRead(taskID: task.id)
            _ = try await service.submit(request: request)
            if cancel { try await service.cancel(taskID: task.id) }
            else { try await service.reject(requestID: request.id) }
            await XCTAssertThrowsErrorAsync(try await service.approve(requestID: request.id, digest: request.payloadDigest))
            let result = try await service.takeEphemeralToolResult(taskID: task.id, requestID: request.id, digest: request.payloadDigest)
            XCTAssertNil(result)
        }
    }
}

extension TaskServiceTests {
    func testDisablingSafariRevokesUndeliveredResultAcrossReenable() async throws {
        #if !JARVIS_SAFARI_EXPERIMENT_BUILD && !JARVIS_COMBINED_EXPERIMENT
        throw XCTSkip("Safari service is unavailable in ordinary builds")
        #endif
        let fixture = try Fixture(), capture = SafariCaptureFixture()
        let service = try TaskService(taskRepository: fixture.tasks, auditRepository: fixture.audit, policy: Policy(allowSafariRead: true), enableSafariRead: true, requestRepository: fixture.requests, approvalRepository: fixture.approvals, unitOfWork: SQLitePersistenceUnitOfWork(database: fixture.database))
        service.safariCaptureFactory = { capture }
        let task = try await service.createTask(title: "read page")
        let request = try await service.prepareSafariRead(taskID: task.id)
        _ = try await service.submit(request: request)
        try await service.approve(requestID: request.id, digest: request.payloadDigest)
        try await fixture.waitForRequest(id: request.id, status: .completed)
        try service.setSafariReadEnabled(false)
        try service.setSafariReadEnabled(true)
        let result = try await service.takeEphemeralToolResult(taskID: task.id, requestID: request.id, digest: request.payloadDigest)
        XCTAssertNil(result)
    }

    func testUnregisteredExperimentalClickCannotBeSubmittedOrApprovedAfterRestart() async throws {
        let fixture = try Fixture()
        let service = try TaskService(taskRepository: fixture.tasks, auditRepository: fixture.audit, policy: UnsafeAllowSafariPolicy(), requestRepository: fixture.requests, approvalRepository: fixture.approvals, unitOfWork: SQLitePersistenceUnitOfWork(database: fixture.database))
        let task = try await service.createTask(title: "click")
        let request = ToolRequest(taskID: task.id, name: "safari_click_experiment", sideEffect: .localWrite, target: "redacted", payload: UUID().uuidString)
        await XCTAssertThrowsErrorAsync(try await service.submit(request: request))
        XCTAssertNil(try fixture.requests.fetch(id: request.id))
        try service.transition(taskID: task.id, to: .planning)
        try service.transition(taskID: task.id, to: .running)
        try SQLitePersistenceUnitOfWork(database: fixture.database).submitRequest(request, status: .pending, taskStatus: .awaitingApproval, audits: [])
        let restarted = try fixture.makeService()
        await XCTAssertThrowsErrorAsync(try await restarted.approve(requestID: request.id, digest: request.payloadDigest))
        XCTAssertEqual(try fixture.requests.fetch(id: request.id)?.1, .pending)
        XCTAssertTrue(try fixture.approvals.list().isEmpty)
    }
}

extension TaskServiceTests {
    func testDisablingSafariDuringReadSuppressesOldGenerationResult() async throws {
        #if !JARVIS_SAFARI_EXPERIMENT_BUILD && !JARVIS_COMBINED_EXPERIMENT
        throw XCTSkip("Safari service is unavailable in ordinary builds")
        #endif
        let fixture = try Fixture(), page = DelayedPage()
        let capture = SafariStaticFixture(text: "private-in-flight", page: page)
        let service = try TaskService(taskRepository: fixture.tasks, auditRepository: fixture.audit, policy: Policy(allowSafariRead: true), enableSafariRead: true, requestRepository: fixture.requests, approvalRepository: fixture.approvals, unitOfWork: SQLitePersistenceUnitOfWork(database: fixture.database))
        service.safariCaptureFactory = { capture }
        let task = try await service.createTask(title: "read page")
        let request = try await service.prepareSafariRead(taskID: task.id)
        _ = try await service.submit(request: request)
        try await service.approve(requestID: request.id, digest: request.payloadDigest)
        for _ in 0..<100 where !(await page.hasStarted()) { try await Task.sleep(for: .milliseconds(10)) }
        let started = await page.hasStarted()
        XCTAssertTrue(started)
        try service.setSafariReadEnabled(false)
        try service.setSafariReadEnabled(true)
        await page.release()
        await service.waitForTrackedExecution(request.id)
        let result = try await service.takeEphemeralToolResult(taskID: task.id, requestID: request.id, digest: request.payloadDigest)
        XCTAssertNil(result)
        let events = try fixture.audit.events(for: task.id)
        XCTAssertFalse(events.contains { $0.result.contains("private-in-flight") || $0.summary == "ephemeral tool result" })
    }
}

extension TaskServiceTests {
    func testSafariToggleFailsClosedUnlessExplicitlyAllowed() throws {
        let fixture = try Fixture()
        XCTAssertThrowsError(try fixture.service.setSafariReadEnabled(true))
        XCTAssertFalse(fixture.service.isSafariReadEnabled())
    }
}

extension TaskServiceTests {
    #if !JARVIS_SAFARI_EXPERIMENT_BUILD && !JARVIS_COMBINED_EXPERIMENT
    func testOrdinaryBuildCannotEnableSafariEvenWithExplicitArguments() async throws {
        let fixture = try Fixture()
        let service = try TaskService(taskRepository: fixture.tasks, auditRepository: fixture.audit, policy: Policy(allowSafariRead: true), enableSafariRead: true, allowSafariReadToggle: true)
        XCTAssertFalse(service.isSafariReadEnabled())
        XCTAssertThrowsError(try service.setSafariReadEnabled(true))
        let task = try await service.createTask(title: "read page")
        await XCTAssertThrowsErrorAsync(try await service.prepareSafariRead(taskID: task.id))
    }
    #endif

    func testUnregisteredExperimentalClickIsDeniedAtExecutionBoundary() throws {
        let request = ToolRequest(taskID: UUID(), name: "safari_click_experiment", sideEffect: .localWrite, target: "redacted", payload: "opaque")
        XCTAssertThrowsError(try TaskService.validateExecutionCapability(request))
    }
}

#if os(macOS)
import ApplicationServices
import SQLite3
extension TaskServiceTests {
    func testExperimentalClickCommitsApprovalBeforeFakeAction() async throws {
        let fixture = try Fixture()
        let service = fixture.service
        let task = try await service.createTask(title: "experimental click")
        let ref = AXUIElementCreateSystemWide()
        let identity = SafariClickIdentity(pid: 42, window: "window", url: "https://example.com/private", role: "AXButton", title: "Secret title", enabled: true, requestDigest: "")
        let candidate = SafariClickCandidate(element: ref, window: ref, launchDate: Date(timeIntervalSince1970: 1), identity: identity)
        let capture = SafariClickCapture { [candidate] }
        let action = ExperimentalClickActionCounter()
        await service.installExperimentalClickForTesting(action: { _, _ in
            if (try? fixture.approvals.list().contains { $0.decision == .approved }) == true { action.increment() }
            return .success
        })
        let request = try await service.submitExperimentalClick(taskID: task.id, identity: identity, capture: capture)
        XCTAssertEqual(try fixture.requests.fetch(id: request.id)?.1, .pending)
        XCTAssertEqual(action.value, 0)
        try await service.approveExperimentalClick(requestID: request.id, digest: request.payloadDigest)
        XCTAssertEqual(action.value, 1)
        XCTAssertEqual(try fixture.requests.fetch(id: request.id)?.1, .completed)
        let audits = try fixture.audit.events(for: task.id)
        XCTAssertFalse(String(describing: audits).contains("Secret title"))
        XCTAssertFalse(String(describing: audits).contains("example.com/private"))
    }
}
extension TaskServiceTests {
    private func experimentalFixture() async throws -> (Fixture, JarvisTask, ToolRequest, ExperimentalClickActionCounter) {
        let fixture = try Fixture(), action = ExperimentalClickActionCounter()
        let task = try await fixture.service.createTask(title: "click")
        let ref = AXUIElementCreateSystemWide()
        let identity = SafariClickIdentity(pid: 42, window: "window", url: "https://example.com/private", role: "AXButton", title: "Secret", enabled: true, requestDigest: "")
        let candidate = SafariClickCandidate(element: ref, window: ref, launchDate: Date(timeIntervalSince1970: 1), identity: identity)
        await fixture.service.installExperimentalClickForTesting(action: { _, _ in action.increment(); return .success })
        let request = try await fixture.service.submitExperimentalClick(taskID: task.id, identity: identity, capture: SafariClickCapture { [candidate] })
        return (fixture, task, request, action)
    }
    func testExperimentalClickActionFailureRecordsUnknownOutcome() async throws {
        let fixture = try Fixture(), action = ExperimentalClickActionCounter()
        let task = try await fixture.service.createTask(title: "click")
        let ref = AXUIElementCreateSystemWide()
        let identity = SafariClickIdentity(pid: 42, window: "window", url: "https://example.com/private", role: "AXButton", title: "Secret", enabled: true, requestDigest: "")
        let candidate = SafariClickCandidate(element: ref, window: ref, launchDate: Date(timeIntervalSince1970: 1), identity: identity)
        await fixture.service.installExperimentalClickForTesting(action: { _, _ in action.increment(); return .failure })
        let request = try await fixture.service.submitExperimentalClick(taskID: task.id, identity: identity, capture: SafariClickCapture { [candidate] })
        await XCTAssertThrowsErrorAsync(try await fixture.service.approveExperimentalClick(requestID: request.id, digest: request.payloadDigest))
        XCTAssertEqual(action.value, 1)
        let events = try fixture.audit.events(for: task.id)
        XCTAssertTrue(events.contains { $0.result == "action outcome unknown; do not retry automatically" })
        XCTAssertFalse(String(describing: events).contains("Secret"))
    }
    func testExperimentalClickSubmitTransactionFailureReleasesCapture() async throws {
        let fixture = try Fixture(), action = ExperimentalClickActionCounter()
        let task = try await fixture.service.createTask(title: "click")
        let ref = AXUIElementCreateSystemWide()
        let identity = SafariClickIdentity(pid: 42, window: "window", url: "https://example.com/private", role: "AXButton", title: "Secret", enabled: true, requestDigest: "")
        let candidate = SafariClickCandidate(element: ref, window: ref, launchDate: Date(timeIntervalSince1970: 1), identity: identity)
        let capture = SafariClickCapture { [candidate] }
        await fixture.service.installExperimentalClickForTesting(action: { _, _ in action.increment(); return .success })
        try fixture.database.write { db in try db.execute(sql: "CREATE TRIGGER reject_click_request BEFORE INSERT ON tool_requests BEGIN SELECT RAISE(ABORT, 'test failure'); END") }
        await XCTAssertThrowsErrorAsync(try await fixture.service.submitExperimentalClick(taskID: task.id, identity: identity, capture: capture))
        do { try await capture.verify(expected: identity); XCTFail("failed transaction retained capture") } catch { }
        XCTAssertEqual(action.value, 0)
    }
    func testExperimentalClickExpiredTicketNeverActs() async throws {
        let fixture = try Fixture(), action = ExperimentalClickActionCounter(), clock = ExperimentalClickClock()
        let task = try await fixture.service.createTask(title: "click")
        let ref = AXUIElementCreateSystemWide()
        let identity = SafariClickIdentity(pid: 42, window: "window", url: "https://example.com/private", role: "AXButton", title: "Secret", enabled: true, requestDigest: "")
        let candidate = SafariClickCandidate(element: ref, window: ref, launchDate: Date(timeIntervalSince1970: 1), identity: identity)
        await fixture.service.installExperimentalClickForTesting(lifetime: 5, clock: { clock.read() }, action: { _, _ in action.increment(); return .success })
        let request = try await fixture.service.submitExperimentalClick(taskID: task.id, identity: identity, capture: SafariClickCapture { [candidate] })
        clock.advance()
        await XCTAssertThrowsErrorAsync(try await fixture.service.approveExperimentalClick(requestID: request.id, digest: request.payloadDigest))
        XCTAssertEqual(action.value, 0)
    }
    func testExperimentalClickCancelDuringVerificationNeverActs() async throws {
        let fixture = try Fixture(), action = ExperimentalClickActionCounter()
        let task = try await fixture.service.createTask(title: "click")
        let ref = AXUIElementCreateSystemWide()
        let identity = SafariClickIdentity(pid: 42, window: "window", url: "https://example.com/private", role: "AXButton", title: "Secret", enabled: true, requestDigest: "")
        let candidate = SafariClickCandidate(element: ref, window: ref, launchDate: Date(timeIntervalSince1970: 1), identity: identity)
        let entered = expectation(description: "verification")
        let gate = ExperimentalClickVerificationGate(entered: entered)
        let capture = SafariClickCapture { await gate.visit(); return [candidate] }
        await fixture.service.installExperimentalClickForTesting(action: { _, _ in action.increment(); return .success })
        let request = try await fixture.service.submitExperimentalClick(taskID: task.id, identity: identity, capture: capture)
        let approval = Task { try await fixture.service.approveExperimentalClick(requestID: request.id, digest: request.payloadDigest) }
        await fulfillment(of: [entered], timeout: 2)
        try await fixture.service.cancel(taskID: task.id)
        await gate.release()
        do { try await approval.value; XCTFail("cancelled click succeeded") } catch { }
        XCTAssertEqual(action.value, 0)
        XCTAssertEqual(try fixture.requests.fetch(id: request.id)?.1, .cancelled)
    }
    func testExperimentalClickCancelAfterActionStartsRecordsUnknownOutcome() async throws {
        let fixture = try Fixture()
        let task = try await fixture.service.createTask(title: "click")
        let ref = AXUIElementCreateSystemWide()
        let identity = SafariClickIdentity(pid: 42, window: "window", url: "https://example.com/private", role: "AXButton", title: "Secret", enabled: true, requestDigest: "")
        let candidate = SafariClickCandidate(element: ref, window: ref, launchDate: Date(timeIntervalSince1970: 1), identity: identity)
        let entered = expectation(description: "action started")
        let block = ExperimentalClickBlockingAction(entered)
        await fixture.service.installExperimentalClickForTesting(action: { _, _ in block.run(); return .success })
        let request = try await fixture.service.submitExperimentalClick(taskID: task.id, identity: identity, capture: SafariClickCapture { [candidate] })
        let approval = Task { try await fixture.service.approveExperimentalClick(requestID: request.id, digest: request.payloadDigest) }
        await fulfillment(of: [entered], timeout: 2)
        try await fixture.service.cancel(taskID: task.id)
        let events = try fixture.audit.events(for: task.id)
        XCTAssertTrue(events.contains { $0.result == "action outcome unknown; do not retry automatically" })
        block.release.signal()
        _ = try? await approval.value
    }
    func testExperimentalClickCancelAuditTransactionFailureKeepsUnknownForRetry() async throws {
        let fixture = try Fixture()
        let task = try await fixture.service.createTask(title: "click")
        let ref = AXUIElementCreateSystemWide()
        let identity = SafariClickIdentity(pid: 42, window: "window", url: "https://example.com/private", role: "AXButton", title: "Secret", enabled: true, requestDigest: "")
        let candidate = SafariClickCandidate(element: ref, window: ref, launchDate: Date(timeIntervalSince1970: 1), identity: identity)
        let entered = expectation(description: "action started")
        let block = ExperimentalClickBlockingAction(entered)
        await fixture.service.installExperimentalClickForTesting(action: { _, _ in block.run(); return .success })
        let request = try await fixture.service.submitExperimentalClick(taskID: task.id, identity: identity, capture: SafariClickCapture { [candidate] })
        let approval = Task { try await fixture.service.approveExperimentalClick(requestID: request.id, digest: request.payloadDigest) }
        await fulfillment(of: [entered], timeout: 2)
        try fixture.database.write { db in try db.execute(sql: "CREATE TRIGGER reject_cancel_audit BEFORE INSERT ON audit_events WHEN NEW.summary = 'task cancelled' BEGIN SELECT RAISE(ABORT, 'test'); END") }
        await XCTAssertThrowsErrorAsync(try await fixture.service.cancel(taskID: task.id))
        try fixture.database.write { db in try db.execute(sql: "DROP TRIGGER reject_cancel_audit") }
        try await fixture.service.cancel(taskID: task.id)
        let events = try fixture.audit.events(for: task.id)
        XCTAssertTrue(events.contains { $0.result == "action outcome unknown; do not retry automatically" })
        block.release.signal()
        _ = try? await approval.value
    }
    func testExperimentalClickTaskCancellationAfterCommitClosesPendingRequest() async throws {
        let fixture = try Fixture(), action = ExperimentalClickActionCounter()
        let task = try await fixture.service.createTask(title: "click")
        let ref = AXUIElementCreateSystemWide()
        let identity = SafariClickIdentity(pid: 42, window: "window", url: "https://example.com/private", role: "AXButton", title: "Secret", enabled: true, requestDigest: "")
        let candidate = SafariClickCandidate(element: ref, window: ref, launchDate: Date(timeIntervalSince1970: 1), identity: identity)
        let entered = expectation(description: "committed")
        let gate = ExperimentalClickVerificationGate(entered: entered, blockAt: 1)
        await fixture.service.installExperimentalClickForTesting(afterSubmit: { await gate.visit() }, action: { _, _ in action.increment(); return .success })
        let submission = Task { try await fixture.service.submitExperimentalClick(taskID: task.id, identity: identity, capture: SafariClickCapture { [candidate] }) }
        await fulfillment(of: [entered], timeout: 2)
        submission.cancel()
        await gate.release()
        do { _ = try await submission.value; XCTFail("cancelled submission succeeded") } catch { }
        let pending = try fixture.requests.list(status: .pending).filter { $0.0.taskID == task.id }
        XCTAssertTrue(pending.isEmpty)
        XCTAssertEqual(action.value, 0)
    }
    func testExperimentalClickCompletionTransactionFailureRecordsUnknownOutcome() async throws {
        let (fixture, task, request, action) = try await experimentalFixture()
        try fixture.database.write { db in try db.execute(sql: "CREATE TRIGGER reject_click_complete BEFORE UPDATE ON tool_requests WHEN NEW.status = 'completed' BEGIN SELECT RAISE(ABORT, 'test'); END") }
        await XCTAssertThrowsErrorAsync(try await fixture.service.approveExperimentalClick(requestID: request.id, digest: request.payloadDigest))
        XCTAssertEqual(action.value, 1)
        let events = try fixture.audit.events(for: task.id)
        XCTAssertTrue(events.contains { $0.result == "action outcome unknown; do not retry automatically" })
        XCTAssertFalse(String(describing: events).contains("Secret"))
    }
    func testExperimentalClickCompletionAndFailureWritesBothFailReturnsUnknown() async throws {
        let (fixture, _, request, action) = try await experimentalFixture()
        try fixture.database.write { db in try db.execute(sql: "CREATE TRIGGER reject_finish BEFORE UPDATE ON tool_requests WHEN NEW.status IN ('completed', 'failed') BEGIN SELECT RAISE(ABORT, 'test'); END") }
        do {
            try await fixture.service.approveExperimentalClick(requestID: request.id, digest: request.payloadDigest)
            XCTFail("persistence failures accepted")
        } catch SafariPressFailure.actionOutcomeUnknown { }
        catch { XCTFail("expected unknown outcome, got \(error)") }
        XCTAssertEqual(action.value, 1)
        await XCTAssertThrowsErrorAsync(try await fixture.service.approveExperimentalClick(requestID: request.id, digest: request.payloadDigest))
        XCTAssertEqual(action.value, 1)
    }
    func testExperimentalClickCompensationFailureShowsRecoveryInstruction() async throws {
        let fixture = try Fixture(), action = ExperimentalClickActionCounter()
        let task = try await fixture.service.createTask(title: "click")
        let ref = AXUIElementCreateSystemWide()
        let identity = SafariClickIdentity(pid: 42, window: "window", url: "https://example.com/private", role: "AXButton", title: "Secret", enabled: true, requestDigest: "")
        let candidate = SafariClickCandidate(element: ref, window: ref, launchDate: Date(timeIntervalSince1970: 1), identity: identity)
        let gate = ExperimentalClickVerificationGate(entered: expectation(description: "committed"), blockAt: 1)
        let entered = gate.entered
        await fixture.service.installExperimentalClickForTesting(afterSubmit: { await gate.visit() }, action: { _, _ in action.increment(); return .success })
        let submission = Task { try await fixture.service.submitExperimentalClick(taskID: task.id, identity: identity, capture: SafariClickCapture { [candidate] }) }
        await fulfillment(of: [entered], timeout: 2)
        try fixture.database.write { db in try db.execute(sql: "CREATE TRIGGER reject_compensation BEFORE INSERT ON approvals BEGIN SELECT RAISE(ABORT, 'test'); END") }
        submission.cancel()
        await gate.release()
        do { _ = try await submission.value; XCTFail("cancelled submission succeeded") } catch { }
        let pending = try await fixture.service.listPendingApprovalRequests(taskID: task.id)
        XCTAssertEqual(pending.count, 1)
        XCTAssertTrue(pending[0].payload.contains("拒绝"))
        XCTAssertTrue(pending[0].payload.contains("重新发起"))
        XCTAssertEqual(action.value, 0)
    }
    func testExperimentalClickPreviewIsBoundAndNeverPersisted() async throws {
        let (fixture, task, request, _) = try await experimentalFixture()
        let previews = try await fixture.service.listPendingApprovalRequests(taskID: task.id)
        let preview = try XCTUnwrap(previews.first)
        XCTAssertEqual(preview.target, "https://example.com/private")
        XCTAssertTrue(preview.payload.contains("AXButton"))
        XCTAssertTrue(preview.payload.contains("Secret"))
        XCTAssertTrue(preview.payload.contains("启用"))
        XCTAssertTrue(preview.payload.contains("风险"))
        XCTAssertTrue(preview.payload.contains("非原子"))
        XCTAssertTrue(preview.payload.contains("不可撤销"))
        let persisted = try XCTUnwrap(fixture.requests.fetch(id: request.id)?.0)
        XCTAssertFalse(String(describing: persisted).contains("Secret"))
        XCTAssertFalse(String(describing: persisted).contains("example.com/private"))
        XCTAssertFalse(String(describing: try fixture.audit.events(for: task.id)).contains("Secret"))
        let forged = ToolRequest(id: request.id, taskID: task.id, name: request.name, sideEffect: request.sideEffect, target: request.target, payload: UUID().uuidString)
        try fixture.database.write { db in try db.execute(sql: "UPDATE tool_requests SET payload = ?, payload_digest = ? WHERE id = ?", arguments: [forged.payload, forged.payloadDigest, request.id.uuidString]) }
        let tampered = try await fixture.service.listPendingApprovalRequests(taskID: task.id)
        XCTAssertFalse(tampered[0].payload.contains("Secret"))
        XCTAssertTrue(tampered[0].payload.contains("失效"))
    }
    func testExperimentalClickPreviewDisappearsOnExpiryRestartAndReject() async throws {
        let fixture = try Fixture(), action = ExperimentalClickActionCounter(), clock = ExperimentalClickClock()
        let task = try await fixture.service.createTask(title: "click")
        let ref = AXUIElementCreateSystemWide()
        let identity = SafariClickIdentity(pid: 42, window: "window", url: "https://example.com:8443/private", role: "AXButton", title: "Secret", enabled: true, requestDigest: "")
        let candidate = SafariClickCandidate(element: ref, window: ref, launchDate: Date(timeIntervalSince1970: 1), identity: identity)
        await fixture.service.installExperimentalClickForTesting(lifetime: 5, clock: { clock.read() }, action: { _, _ in action.increment(); return .success })
        let request = try await fixture.service.submitExperimentalClick(taskID: task.id, identity: identity, capture: SafariClickCapture { [candidate] })
        let previews = try await fixture.service.listPendingApprovalRequests(taskID: task.id)
        XCTAssertEqual(previews[0].target, "https://example.com:8443/private")
        let restarted = try fixture.makeService()
        let afterRestart = try await restarted.listPendingApprovalRequests(taskID: task.id)
        XCTAssertTrue(afterRestart[0].payload.contains("失效"))
        clock.advance()
        let afterExpiry = try await fixture.service.listPendingApprovalRequests(taskID: task.id)
        XCTAssertTrue(afterExpiry[0].payload.contains("失效"))
        XCTAssertFalse(afterExpiry[0].payload.contains("Secret"))
        try await fixture.service.reject(requestID: request.id)
        let afterRejection = try await fixture.service.listPendingApprovalRequests(taskID: task.id)
        XCTAssertTrue(afterRejection.isEmpty)
    }
    func testExperimentalClickPreviewShowsExactDistinctURLsAndEscapesControls() async throws {
        let fixture = try Fixture()
        let actualTask = try await fixture.service.createTask(title: "click")
        let ref = AXUIElementCreateSystemWide()
        let url = "https://example.com/a?secret=one"
        let identity = SafariClickIdentity(pid: 42, window: "window", url: url, role: "AXButton", title: "Safe\u{202E}Danger\nNext", enabled: true, requestDigest: "")
        let candidate = SafariClickCandidate(element: ref, window: ref, launchDate: Date(timeIntervalSince1970: 1), identity: identity)
        await fixture.service.installExperimentalClickForTesting(action: { _, _ in .success })
        _ = try await fixture.service.submitExperimentalClick(taskID: actualTask.id, identity: identity, capture: SafariClickCapture { [candidate] })
        var other = identity
        other.url = "https://example.com/b?secret=two"
        let otherCandidate = SafariClickCandidate(element: ref, window: ref, launchDate: Date(timeIntervalSince1970: 1), identity: other)
        _ = try await fixture.service.submitExperimentalClick(taskID: actualTask.id, identity: other, capture: SafariClickCapture { [otherCandidate] })
        let previews = try await fixture.service.listPendingApprovalRequests(taskID: actualTask.id)
        XCTAssertEqual(Set(previews.map(\.target)), Set([url, other.url]))
        XCTAssertTrue(previews[0].payload.contains("\\u{202E}"))
        XCTAssertTrue(previews[0].payload.contains("\\u{000A}"))
        XCTAssertFalse(previews[0].payload.contains("\u{202E}"))
        let allStored = String(describing: try fixture.requests.list(status: .pending)) + String(describing: try fixture.audit.events(for: actualTask.id))
        XCTAssertFalse(allStored.contains("secret=one"))
        XCTAssertFalse(allStored.contains("secret=two"))
        XCTAssertFalse(allStored.contains("Danger"))
    }
    func testExperimentalClickPreviewRejectsOverlongTitle() async throws {
        let fixture = try Fixture()
        let actualTask = try await fixture.service.createTask(title: "click")
        let ref = AXUIElementCreateSystemWide()
        let identity = SafariClickIdentity(pid: 42, window: "window", url: "https://example.com/a", role: "AXButton", title: String(repeating: "x", count: 600), enabled: true, requestDigest: "")
        let candidate = SafariClickCandidate(element: ref, window: ref, launchDate: Date(timeIntervalSince1970: 1), identity: identity)
        await fixture.service.installExperimentalClickForTesting(action: { _, _ in .success })
        let request = try await fixture.service.submitExperimentalClick(taskID: actualTask.id, identity: identity, capture: SafariClickCapture { [candidate] })
        let previews = try await fixture.service.listPendingApprovalRequests(taskID: actualTask.id)
        XCTAssertTrue(previews[0].payload.contains("失效"))
        await XCTAssertThrowsErrorAsync(try await fixture.service.approveExperimentalClick(requestID: request.id, digest: request.payloadDigest))
    }
    func testExperimentalClickRejectsLongURLAndRole() async throws {
        for isURL in [true, false] {
            let fixture = try Fixture(), task = try await fixture.service.createTask(title: "click")
            let ref = AXUIElementCreateSystemWide()
            let identity = SafariClickIdentity(pid: 42, window: "window", url: "https://example.com/" + (isURL ? String(repeating: "a", count: 2100) : "a"), role: isURL ? "AXButton" : String(repeating: "r", count: 129), title: "title", enabled: true, requestDigest: "")
            let candidate = SafariClickCandidate(element: ref, window: ref, launchDate: Date(timeIntervalSince1970: 1), identity: identity)
            await fixture.service.installExperimentalClickForTesting(action: { _, _ in XCTFail("oversized target executed"); return .success })
            let request = try await fixture.service.submitExperimentalClick(taskID: task.id, identity: identity, capture: SafariClickCapture { [candidate] })
            let pending = try await fixture.service.listPendingApprovalRequests(taskID: task.id)
            XCTAssertEqual(pending[0].previewAvailable, false)
            await XCTAssertThrowsErrorAsync(try await fixture.service.approveExperimentalClick(requestID: request.id, digest: request.payloadDigest))
        }
    }
    func testExperimentalClickSecretsNeverReachSQLiteOrWAL() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("jarvis-click-privacy-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("test.sqlite")
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &handle), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(handle, "PRAGMA journal_mode=WAL", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_close(handle), SQLITE_OK)
        let fixture = try Fixture(path: databaseURL.path)
        let task = try await fixture.service.createTask(title: "privacy")
        let ref = AXUIElementCreateSystemWide()
        let identity = SafariClickIdentity(pid: 42, window: "window", url: "https://example.com/path?token=JARVIS_URL_PRIVATE_3871", role: "AXButton", title: "JARVIS_TITLE_PRIVATE_9234", enabled: true, requestDigest: "")
        let candidate = SafariClickCandidate(element: ref, window: ref, launchDate: Date(timeIntervalSince1970: 1), identity: identity)
        await fixture.service.installExperimentalClickForTesting(action: { _, _ in .success })
        let request = try await fixture.service.submitExperimentalClick(taskID: task.id, identity: identity, capture: SafariClickCapture { [candidate] })
        let preview = try await fixture.service.listPendingApprovalRequests(taskID: task.id)
        XCTAssertTrue(preview[0].target.contains("JARVIS_URL_PRIVATE_3871"))
        try await fixture.service.approveExperimentalClick(requestID: request.id, digest: request.payloadDigest)
        let walURL = URL(fileURLWithPath: databaseURL.path + "-wal")
        XCTAssertTrue(FileManager.default.fileExists(atPath: walURL.path))
        for url in [databaseURL, walURL] {
            let data = try Data(contentsOf: url)
            XCTAssertNil(data.range(of: Data("JARVIS_URL_PRIVATE_3871".utf8)))
            XCTAssertNil(data.range(of: Data("JARVIS_TITLE_PRIVATE_9234".utf8)))
        }
    }
    func testExperimentalClickDoublePersistenceFailureCannotReplayAfterServiceRestart() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("jarvis-click-restart-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("test.sqlite").path
        let fixture = try Fixture(path: path), action = ExperimentalClickActionCounter()
        let task = try await fixture.service.createTask(title: "click")
        let ref = AXUIElementCreateSystemWide()
        let identity = SafariClickIdentity(pid: 42, window: "window", url: "https://example.com/a", role: "AXButton", title: "target", enabled: true, requestDigest: "")
        let candidate = SafariClickCandidate(element: ref, window: ref, launchDate: Date(timeIntervalSince1970: 1), identity: identity)
        await fixture.service.installExperimentalClickForTesting(action: { _, _ in action.increment(); return .success })
        let request = try await fixture.service.submitExperimentalClick(taskID: task.id, identity: identity, capture: SafariClickCapture { [candidate] })
        try fixture.database.write { db in try db.execute(sql: "CREATE TRIGGER reject_finish BEFORE UPDATE ON tool_requests WHEN NEW.status IN ('completed', 'failed') BEGIN SELECT RAISE(ABORT, 'test'); END") }
        do { try await fixture.service.approveExperimentalClick(requestID: request.id, digest: request.payloadDigest); XCTFail("write failure") }
        catch SafariPressFailure.actionOutcomeUnknown { }
        catch { XCTFail("expected unknown: \(error)") }
        XCTAssertEqual(action.value, 1)
        let restarted = try Fixture(path: path)
        await restarted.service.installExperimentalClickForTesting(action: { _, _ in action.increment(); return .success })
        await XCTAssertThrowsErrorAsync(try await restarted.service.approveExperimentalClick(requestID: request.id, digest: request.payloadDigest))
        XCTAssertEqual(action.value, 1)
        XCTAssertEqual(try restarted.requests.fetch(id: request.id)?.1, .executing)
        let second = try await restarted.service.submitExperimentalClick(taskID: task.id, identity: identity, capture: SafariClickCapture { [candidate] })
        await XCTAssertThrowsErrorAsync(try await restarted.service.approveExperimentalClick(requestID: second.id, digest: second.payloadDigest))
        XCTAssertEqual(action.value, 1, "an unresolved earlier click must block a fresh request ID")
    }
    func testExperimentalClickBarrierBlocksConcurrentApprovalAndClearsOnSuccess() async throws {
        let fixture = try Fixture(), other = try fixture.makeService(), counter = ExperimentalClickActionCounter()
        let firstTask = try await fixture.service.createTask(title: "first")
        let secondTask = try await other.createTask(title: "second")
        let ref = AXUIElementCreateSystemWide()
        let identity = SafariClickIdentity(pid: 42, window: "window", url: "https://example.com/a", role: "AXButton", title: "Open", enabled: true, requestDigest: "")
        let candidate = SafariClickCandidate(element: ref, window: ref, launchDate: Date(timeIntervalSince1970: 1), identity: identity)
        let entered = expectation(description: "first click started"), block = ExperimentalClickBlockingAction(entered)
        await fixture.service.installExperimentalClickForTesting(action: { _, _ in block.run(); return .success })
        await other.installExperimentalClickForTesting(action: { _, _ in counter.increment(); return .success })
        let first = try await fixture.service.submitExperimentalClick(taskID: firstTask.id, identity: identity, capture: SafariClickCapture { [candidate] })
        let second = try await other.submitExperimentalClick(taskID: secondTask.id, identity: identity, capture: SafariClickCapture { [candidate] })
        let execution = Task { try await fixture.service.approveExperimentalClick(requestID: first.id, digest: first.payloadDigest) }
        await fulfillment(of: [entered], timeout: 2)
        await XCTAssertThrowsErrorAsync(try await other.approveExperimentalClick(requestID: second.id, digest: second.payloadDigest))
        XCTAssertEqual(counter.value, 0)
        block.release.signal()
        try await execution.value
        let third = try await other.submitExperimentalClick(taskID: secondTask.id, identity: identity, capture: SafariClickCapture { [candidate] })
        try await other.approveExperimentalClick(requestID: third.id, digest: third.payloadDigest)
        XCTAssertEqual(counter.value, 1)
    }
    func testExperimentalClickBarrierSurvivesCancellationAfterActionStart() async throws {
        let fixture = try Fixture(), counter = ExperimentalClickActionCounter()
        let task = try await fixture.service.createTask(title: "cancel first")
        let ref = AXUIElementCreateSystemWide()
        let identity = SafariClickIdentity(pid: 42, window: "window", url: "https://example.com/a", role: "AXButton", title: "Open", enabled: true, requestDigest: "")
        let candidate = SafariClickCandidate(element: ref, window: ref, launchDate: Date(timeIntervalSince1970: 1), identity: identity)
        let entered = expectation(description: "click started"), block = ExperimentalClickBlockingAction(entered)
        await fixture.service.installExperimentalClickForTesting(action: { _, _ in block.run(); return .success })
        let first = try await fixture.service.submitExperimentalClick(taskID: task.id, identity: identity, capture: SafariClickCapture { [candidate] })
        let execution = Task { try await fixture.service.approveExperimentalClick(requestID: first.id, digest: first.payloadDigest) }
        await fulfillment(of: [entered], timeout: 2)
        try await fixture.service.cancel(taskID: task.id)
        block.release.signal()
        _ = try? await execution.value
        let other = try fixture.makeService()
        await other.installExperimentalClickForTesting(action: { _, _ in counter.increment(); return .success })
        let otherTask = try await other.createTask(title: "new task")
        let second = try await other.submitExperimentalClick(taskID: otherTask.id, identity: identity, capture: SafariClickCapture { [candidate] })
        await XCTAssertThrowsErrorAsync(try await other.approveExperimentalClick(requestID: second.id, digest: second.payloadDigest))
        XCTAssertEqual(counter.value, 0)
    }
    func testExperimentalClickApprovalTransactionFailureLeavesNoBarrier() async throws {
        let fixture = try Fixture(), counter = ExperimentalClickActionCounter()
        let task = try await fixture.service.createTask(title: "rollback")
        let ref = AXUIElementCreateSystemWide()
        let identity = SafariClickIdentity(pid: 42, window: "window", url: "https://example.com/a", role: "AXButton", title: "Open", enabled: true, requestDigest: "")
        let candidate = SafariClickCandidate(element: ref, window: ref, launchDate: Date(timeIntervalSince1970: 1), identity: identity)
        await fixture.service.installExperimentalClickForTesting(action: { _, _ in counter.increment(); return .success })
        let first = try await fixture.service.submitExperimentalClick(taskID: task.id, identity: identity, capture: SafariClickCapture { [candidate] })
        try fixture.database.write { db in try db.execute(sql: "CREATE TRIGGER reject_click_approval2 BEFORE INSERT ON approvals BEGIN SELECT RAISE(ABORT, 'test failure'); END") }
        await XCTAssertThrowsErrorAsync(try await fixture.service.approveExperimentalClick(requestID: first.id, digest: first.payloadDigest))
        try fixture.database.write { db in try db.execute(sql: "DROP TRIGGER reject_click_approval2") }
        let second = try await fixture.service.submitExperimentalClick(taskID: task.id, identity: identity, capture: SafariClickCapture { [candidate] })
        try await fixture.service.approveExperimentalClick(requestID: second.id, digest: second.payloadDigest)
        XCTAssertEqual(counter.value, 1)
    }
    func testExperimentalClickBarrierMigrationImportsLegacyUnresolvedApproval() async throws {
        let fixture = try Fixture(), counter = ExperimentalClickActionCounter()
        let task = try await fixture.service.createTask(title: "legacy")
        let ref = AXUIElementCreateSystemWide()
        let identity = SafariClickIdentity(pid: 42, window: "window", url: "https://example.com/a", role: "AXButton", title: "Open", enabled: true, requestDigest: "")
        let candidate = SafariClickCandidate(element: ref, window: ref, launchDate: Date(timeIntervalSince1970: 1), identity: identity)
        await fixture.service.installExperimentalClickForTesting(action: { _, _ in counter.increment(); return .success })
        let legacy = try await fixture.service.submitExperimentalClick(taskID: task.id, identity: identity, capture: SafariClickCapture { [candidate] })
        let approval = Approval(toolRequestID: legacy.id, actionDigest: legacy.payloadDigest, decision: .approved)
        let uow = SQLitePersistenceUnitOfWork(database: fixture.database)
        try uow.approveRequest(legacy, approval: approval, taskStatus: .running, audits: [])
        try uow.finishRequest(legacy, status: .failed, taskStatus: .failed, audits: [])
        try fixture.database.write { db in
            try db.execute(sql: "DROP TABLE experimental_click_barriers")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'persist experimental click barriers'")
        }
        try fixture.database.migrate()
        let other = try fixture.makeService()
        await other.installExperimentalClickForTesting(action: { _, _ in counter.increment(); return .success })
        let nextTask = try await other.createTask(title: "new")
        let next = try await other.submitExperimentalClick(taskID: nextTask.id, identity: identity, capture: SafariClickCapture { [candidate] })
        await XCTAssertThrowsErrorAsync(try await other.approveExperimentalClick(requestID: next.id, digest: next.payloadDigest))
        XCTAssertEqual(counter.value, 0)
    }
    func testExperimentalClickBarrierIsSharedAcrossSeparateSQLiteConnections() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("jarvis-click-concurrency-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("test.sqlite").path
        let firstFixture = try Fixture(path: path), secondFixture = try Fixture(path: path), counter = ExperimentalClickActionCounter()
        let firstTask = try await firstFixture.service.createTask(title: "first")
        let secondTask = try await secondFixture.service.createTask(title: "second")
        let ref = AXUIElementCreateSystemWide()
        let identity = SafariClickIdentity(pid: 42, window: "window", url: "https://example.com/a", role: "AXButton", title: "Open", enabled: true, requestDigest: "")
        let candidate = SafariClickCandidate(element: ref, window: ref, launchDate: Date(timeIntervalSince1970: 1), identity: identity)
        let entered = expectation(description: "first click started"), block = ExperimentalClickBlockingAction(entered)
        await firstFixture.service.installExperimentalClickForTesting(action: { _, _ in block.run(); return .success })
        await secondFixture.service.installExperimentalClickForTesting(action: { _, _ in counter.increment(); return .success })
        let first = try await firstFixture.service.submitExperimentalClick(taskID: firstTask.id, identity: identity, capture: SafariClickCapture { [candidate] })
        let second = try await secondFixture.service.submitExperimentalClick(taskID: secondTask.id, identity: identity, capture: SafariClickCapture { [candidate] })
        let execution = Task { try await firstFixture.service.approveExperimentalClick(requestID: first.id, digest: first.payloadDigest) }
        await fulfillment(of: [entered], timeout: 2)
        await XCTAssertThrowsErrorAsync(try await secondFixture.service.approveExperimentalClick(requestID: second.id, digest: second.payloadDigest))
        XCTAssertEqual(counter.value, 0)
        block.release.signal()
        try await execution.value
    }
    func testExperimentalClickSimultaneousApprovalsCommitOnlyOneBarrier() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("jarvis-click-race-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("test.sqlite").path
        let a = try Fixture(path: path), b = try Fixture(path: path)
        let taskA = try await a.service.createTask(title: "a"), taskB = try await b.service.createTask(title: "b")
        let ref = AXUIElementCreateSystemWide()
        let identity = SafariClickIdentity(pid: 42, window: "window", url: "https://example.com/a", role: "AXButton", title: "Open", enabled: true, requestDigest: "")
        let candidate = SafariClickCandidate(element: ref, window: ref, launchDate: Date(timeIntervalSince1970: 1), identity: identity)
        let entered = expectation(description: "one action started"), rejected = expectation(description: "other approval rejected")
        let block = ExperimentalClickBlockingAction(entered)
        await a.service.installExperimentalClickForTesting(action: { _, _ in block.run(); return .success })
        await b.service.installExperimentalClickForTesting(action: { _, _ in block.run(); return .success })
        let requestA = try await a.service.submitExperimentalClick(taskID: taskA.id, identity: identity, capture: SafariClickCapture { [candidate] })
        let requestB = try await b.service.submitExperimentalClick(taskID: taskB.id, identity: identity, capture: SafariClickCapture { [candidate] })
        let first = Task { do { try await a.service.approveExperimentalClick(requestID: requestA.id, digest: requestA.payloadDigest) } catch { rejected.fulfill() } }
        let second = Task { do { try await b.service.approveExperimentalClick(requestID: requestB.id, digest: requestB.payloadDigest) } catch { rejected.fulfill() } }
        await fulfillment(of: [entered, rejected], timeout: 3)
        XCTAssertEqual(try a.approvals.list().filter { $0.decision == .approved }.count, 1)
        block.release.signal()
        await first.value
        await second.value
    }
    func testExperimentalClickFocusPreflightTimeoutClearsBarrier() async throws {
        let fixture = try Fixture(), counter = ExperimentalClickActionCounter()
        let task = try await fixture.service.createTask(title: "focus timeout")
        let ref = AXUIElementCreateSystemWide()
        let identity = SafariClickIdentity(pid: 42, window: "window", url: "https://example.com/a", role: "AXButton", title: "Open", enabled: true, requestDigest: "")
        let candidate = SafariClickCandidate(element: ref, window: ref, launchDate: Date(timeIntervalSince1970: 1), identity: identity)
        let provider = ExperimentalPreflightFailureProvider(candidate, unknown: false)
        await fixture.service.installExperimentalClickForTesting(focusTimeout: .zero, action: { _, _ in counter.increment(); return .success })
        let request = try await fixture.service.submitExperimentalClick(taskID: task.id, identity: identity, capture: SafariClickCapture { try await provider.next() })
        do { try await fixture.service.approveExperimentalClick(requestID: request.id, digest: request.payloadDigest); XCTFail("expected focus timeout") }
        catch SafariAXReadError.focusTimedOut { }
        catch { XCTFail("unexpected: \(error)") }
        XCTAssertFalse(try SQLitePersistenceUnitOfWork(database: fixture.database).hasExperimentalClickBarrier())
        XCTAssertEqual(counter.value, 0)
        let nextTask = try await fixture.service.createTask(title: "after focus timeout")
        let next = try await fixture.service.submitExperimentalClick(taskID: nextTask.id, identity: identity, capture: SafariClickCapture { [candidate] })
        try await fixture.service.approveExperimentalClick(requestID: next.id, digest: next.payloadDigest)
        XCTAssertEqual(counter.value, 1)
    }
    func testExperimentalClickFocusPreflightFailureWriteKeepsBarrier() async throws {
        let fixture = try Fixture(), counter = ExperimentalClickActionCounter()
        let task = try await fixture.service.createTask(title: "focus failure")
        let ref = AXUIElementCreateSystemWide()
        let identity = SafariClickIdentity(pid: 42, window: "window", url: "https://example.com/a", role: "AXButton", title: "Open", enabled: true, requestDigest: "")
        let candidate = SafariClickCandidate(element: ref, window: ref, launchDate: Date(timeIntervalSince1970: 1), identity: identity)
        let provider = ExperimentalPreflightFailureProvider(candidate, unknown: false)
        await fixture.service.installExperimentalClickForTesting(focusTimeout: .zero, action: { _, _ in counter.increment(); return .success })
        let request = try await fixture.service.submitExperimentalClick(taskID: task.id, identity: identity, capture: SafariClickCapture { try await provider.next() })
        try fixture.database.write { db in try db.execute(sql: "CREATE TRIGGER fail_preflight_finish BEFORE UPDATE ON tool_requests WHEN NEW.status = 'failed' BEGIN SELECT RAISE(ABORT, 'test'); END") }
        await XCTAssertThrowsErrorAsync(try await fixture.service.approveExperimentalClick(requestID: request.id, digest: request.payloadDigest))
        XCTAssertTrue(try SQLitePersistenceUnitOfWork(database: fixture.database).hasExperimentalClickBarrier())
        XCTAssertEqual(counter.value, 0)
    }
    func testExperimentalClickPreflightUnknownNeverClearsBarrier() async throws {
        let fixture = try Fixture(), counter = ExperimentalClickActionCounter()
        let task = try await fixture.service.createTask(title: "unknown")
        let ref = AXUIElementCreateSystemWide()
        let identity = SafariClickIdentity(pid: 42, window: "window", url: "https://example.com/a", role: "AXButton", title: "Open", enabled: true, requestDigest: "")
        let candidate = SafariClickCandidate(element: ref, window: ref, launchDate: Date(timeIntervalSince1970: 1), identity: identity)
        let provider = ExperimentalPreflightFailureProvider(candidate, unknown: true)
        await fixture.service.installExperimentalClickForTesting(focusTimeout: .zero, action: { _, _ in counter.increment(); return .success })
        let request = try await fixture.service.submitExperimentalClick(taskID: task.id, identity: identity, capture: SafariClickCapture { try await provider.next() })
        await XCTAssertThrowsErrorAsync(try await fixture.service.approveExperimentalClick(requestID: request.id, digest: request.payloadDigest))
        XCTAssertTrue(try SQLitePersistenceUnitOfWork(database: fixture.database).hasExperimentalClickBarrier())
        XCTAssertEqual(counter.value, 0)
    }
    func testExperimentalClickPreflightTaskCancellationRevokesGateBeforeClearingBarrier() async throws {
        let fixture = try Fixture(), counter = ExperimentalClickActionCounter()
        let task = try await fixture.service.createTask(title: "preflight cancellation")
        let ref = AXUIElementCreateSystemWide()
        let identity = SafariClickIdentity(pid: 42, window: "window", url: "https://example.com/a", role: "AXButton", title: "Open", enabled: true, requestDigest: "")
        let candidate = SafariClickCandidate(element: ref, window: ref, launchDate: Date(timeIntervalSince1970: 1), identity: identity)
        let entered = expectation(description: "verification waiting"), gate = ExperimentalClickVerificationGate(entered: entered)
        await fixture.service.installExperimentalClickForTesting(action: { _, _ in counter.increment(); return .success })
        let request = try await fixture.service.submitExperimentalClick(taskID: task.id, identity: identity, capture: SafariClickCapture { await gate.visit(); return [candidate] })
        let approval = Task { try await fixture.service.approveExperimentalClick(requestID: request.id, digest: request.payloadDigest) }
        await fulfillment(of: [entered], timeout: 2)
        approval.cancel()
        await gate.release()
        do { try await approval.value; XCTFail("cancelled approval succeeded") } catch { }
        XCTAssertFalse(try SQLitePersistenceUnitOfWork(database: fixture.database).hasExperimentalClickBarrier())
        XCTAssertEqual(counter.value, 0)
    }
    func testExperimentalClickPreflightCancelledTaskKeepsBarrier() async throws {
        let fixture = try Fixture(), counter = ExperimentalClickActionCounter()
        let task = try await fixture.service.createTask(title: "cancel task")
        let ref = AXUIElementCreateSystemWide()
        let identity = SafariClickIdentity(pid: 42, window: "window", url: "https://example.com/a", role: "AXButton", title: "Open", enabled: true, requestDigest: "")
        let candidate = SafariClickCandidate(element: ref, window: ref, launchDate: Date(timeIntervalSince1970: 1), identity: identity)
        let entered = expectation(description: "verification waiting"), gate = ExperimentalClickVerificationGate(entered: entered)
        await fixture.service.installExperimentalClickForTesting(action: { _, _ in counter.increment(); return .success })
        let request = try await fixture.service.submitExperimentalClick(taskID: task.id, identity: identity, capture: SafariClickCapture { await gate.visit(); return [candidate] })
        let approval = Task { try await fixture.service.approveExperimentalClick(requestID: request.id, digest: request.payloadDigest) }
        await fulfillment(of: [entered], timeout: 2)
        try await fixture.service.cancel(taskID: task.id)
        await gate.release()
        do { try await approval.value; XCTFail("cancelled task succeeded") } catch { }
        XCTAssertTrue(try SQLitePersistenceUnitOfWork(database: fixture.database).hasExperimentalClickBarrier())
        XCTAssertEqual(counter.value, 0)
    }
    func testExperimentalClickWrongDigestRevokesTicket() async throws {
        let (fixture, _, request, action) = try await experimentalFixture()
        await XCTAssertThrowsErrorAsync(try await fixture.service.approveExperimentalClick(requestID: request.id, digest: "wrong"))
        await XCTAssertThrowsErrorAsync(try await fixture.service.approveExperimentalClick(requestID: request.id, digest: request.payloadDigest))
        XCTAssertTrue(try fixture.approvals.list().isEmpty)
        XCTAssertEqual(action.value, 0)
    }
    func testExperimentalClickRejectCancelAndRestartFailClosed() async throws {
        for scenario in 0..<3 {
            let (fixture, task, request, action) = try await experimentalFixture()
            if scenario == 0 { try await fixture.service.reject(requestID: request.id) }
            if scenario == 1 { try await fixture.service.cancel(taskID: task.id) }
            let service = scenario == 2 ? try fixture.makeService() : fixture.service
            await XCTAssertThrowsErrorAsync(try await service.approveExperimentalClick(requestID: request.id, digest: request.payloadDigest))
            XCTAssertEqual(action.value, 0)
        }
    }
    func testExperimentalClickApprovalTransactionFailureRevokesTicket() async throws {
        let (fixture, _, request, action) = try await experimentalFixture()
        try fixture.database.write { db in try db.execute(sql: "CREATE TRIGGER reject_click_approval BEFORE INSERT ON approvals BEGIN SELECT RAISE(ABORT, 'test failure'); END") }
        await XCTAssertThrowsErrorAsync(try await fixture.service.approveExperimentalClick(requestID: request.id, digest: request.payloadDigest))
        XCTAssertEqual(try fixture.requests.fetch(id: request.id)?.1, .pending)
        XCTAssertTrue(try fixture.approvals.list().isEmpty)
        try fixture.database.write { db in try db.execute(sql: "DROP TRIGGER reject_click_approval") }
        await XCTAssertThrowsErrorAsync(try await fixture.service.approveExperimentalClick(requestID: request.id, digest: request.payloadDigest))
        XCTAssertEqual(action.value, 0)
    }
}
private actor ExperimentalPreflightFailureProvider {
    let candidate: SafariClickCandidate
    let unknown: Bool
    var calls = 0
    init(_ candidate: SafariClickCandidate, unknown: Bool) { self.candidate = candidate; self.unknown = unknown }
    func next() throws -> [SafariClickCandidate] {
        calls += 1
        if calls == 1 { return [candidate] }
        if unknown { throw SafariPressFailure.actionOutcomeUnknown }
        throw SafariAXReadError.notFocused
    }
}
private actor ExperimentalClickVerificationGate {
    let entered: XCTestExpectation
    var count = 0
    var continuation: CheckedContinuation<Void, Never>?
    let blockAt: Int
    init(entered: XCTestExpectation, blockAt: Int = 2) { self.entered = entered; self.blockAt = blockAt }
    func visit() async {
        count += 1
        if count == blockAt { await withCheckedContinuation { continuation = $0; entered.fulfill() } }
    }
    func release() { continuation?.resume(); continuation = nil }
}
private final class ExperimentalClickBlockingAction: @unchecked Sendable {
    let entered: XCTestExpectation
    let release = DispatchSemaphore(value: 0)
    init(_ entered: XCTestExpectation) { self.entered = entered }
    func run() { entered.fulfill(); _ = release.wait(timeout: .now() + 5) }
}
private final class ExperimentalClickClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0
    func read() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return value }
    func advance() { lock.lock(); defer { lock.unlock() }; value = 6 }
}
private final class ExperimentalClickActionCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); defer { lock.unlock() }; count += 1 }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
#endif

#if os(macOS) && JARVIS_SAFARI_CLICK_EXPERIMENT && JARVIS_SAFARI_CLICK_TESTING
extension TaskServiceTests {
    func testExperimentalClickGateRejectsForgedOrMissingRequirements() {
        let bundle = "local.jarvis.safari-click-experiment"
        #if JARVIS_SAFARI_EXPERIMENT_BUILD
        XCTAssertTrue(TaskService.experimentalSystemClickGateForTesting(bundleID: bundle, marker: NSNumber(value: true), optedIn: true, trusted: true))
        #else
        XCTAssertFalse(TaskService.experimentalSystemClickGateForTesting(bundleID: bundle, marker: NSNumber(value: true), optedIn: true, trusted: true))
        #endif
        XCTAssertFalse(TaskService.experimentalSystemClickGateForTesting(bundleID: "local.jarvis.dev", marker: NSNumber(value: true), optedIn: true, trusted: true))
        XCTAssertFalse(TaskService.experimentalSystemClickGateForTesting(bundleID: bundle, marker: NSNumber(value: 1), optedIn: true, trusted: true))
        XCTAssertFalse(TaskService.experimentalSystemClickGateForTesting(bundleID: bundle, marker: nil, optedIn: true, trusted: true))
        XCTAssertFalse(TaskService.experimentalSystemClickGateForTesting(bundleID: bundle, marker: NSNumber(value: true), optedIn: false, trusted: true))
        XCTAssertFalse(TaskService.experimentalSystemClickGateForTesting(bundleID: bundle, marker: NSNumber(value: true), optedIn: true, trusted: false))
    }
    func testExperimentalSystemPressRevocationBeforeFinalCheckNeverCallsSystem() async throws {
        for revokePermission in [false, true] {
            let fixture = try Fixture(), counter = ExperimentalClickActionCounter(), flags = ExperimentalSystemAuthorization()
            let task = try await fixture.service.createTask(title: "revocation")
            let ref = AXUIElementCreateSystemWide()
            let identity = SafariClickIdentity(pid: 42, window: "window", url: "https://example.com/a", role: "AXButton", title: "Open", enabled: true, requestDigest: "")
            let candidate = SafariClickCandidate(element: ref, window: ref, launchDate: Date(timeIntervalSince1970: 1), identity: identity)
            let entered = expectation(description: "final check")
            let block = ExperimentalClickBlockingAction(entered)
            await fixture.service.installExperimentalSystemClickForTesting(authorization: { flags.allowed }, beforeSystemCheck: { block.run() }) { _, _ in counter.increment(); return .success }
            let request = try await fixture.service.submitExperimentalClick(taskID: task.id, identity: identity, capture: SafariClickCapture { [candidate] })
            let attempt = Task { try await fixture.service.approveExperimentalClick(requestID: request.id, digest: request.payloadDigest) }
            await fulfillment(of: [entered], timeout: 2)
            flags.revoke(permission: revokePermission)
            block.release.signal()
            do { try await attempt.value; XCTFail("revoked action succeeded") } catch { }
            XCTAssertEqual(counter.value, 0)
            await XCTAssertThrowsErrorAsync(try await fixture.service.approveExperimentalClick(requestID: request.id, digest: request.payloadDigest))
        }
    }
    func testExperimentalSystemPressRevocationBeforeApprovalInvalidatesTicket() async throws {
        let fixture = try Fixture(), counter = ExperimentalClickActionCounter(), flags = ExperimentalSystemAuthorization()
        let task = try await fixture.service.createTask(title: "revocation")
        let ref = AXUIElementCreateSystemWide()
        let identity = SafariClickIdentity(pid: 42, window: "window", url: "https://example.com/a", role: "AXButton", title: "Open", enabled: true, requestDigest: "")
        let candidate = SafariClickCandidate(element: ref, window: ref, launchDate: Date(timeIntervalSince1970: 1), identity: identity)
        await fixture.service.installExperimentalSystemClickForTesting(authorization: { flags.allowed }) { _, _ in counter.increment(); return .success }
        let request = try await fixture.service.submitExperimentalClick(taskID: task.id, identity: identity, capture: SafariClickCapture { [candidate] })
        flags.revoke(permission: false)
        await XCTAssertThrowsErrorAsync(try await fixture.service.approveExperimentalClick(requestID: request.id, digest: request.payloadDigest))
        flags.restore()
        await XCTAssertThrowsErrorAsync(try await fixture.service.approveExperimentalClick(requestID: request.id, digest: request.payloadDigest))
        XCTAssertEqual(counter.value, 0)
    }
    func testExperimentalSystemPressRevocationEventCannotReviveTicket() async throws {
        let fixture = try Fixture(), counter = ExperimentalClickActionCounter(), flags = ExperimentalSystemAuthorization()
        let task = try await fixture.service.createTask(title: "revocation event")
        let ref = AXUIElementCreateSystemWide()
        let identity = SafariClickIdentity(pid: 42, window: "window", url: "https://example.com/a", role: "AXButton", title: "Open", enabled: true, requestDigest: "")
        let candidate = SafariClickCandidate(element: ref, window: ref, launchDate: Date(timeIntervalSince1970: 1), identity: identity)
        await fixture.service.installExperimentalSystemClickForTesting(authorization: { flags.allowed }) { _, _ in counter.increment(); return .success }
        let request = try await fixture.service.submitExperimentalClick(taskID: task.id, identity: identity, capture: SafariClickCapture { [candidate] })
        flags.revoke(permission: false)
        let alreadyStarted = try await fixture.service.experimentalSystemClickAuthorizationRevokedForTesting()
        XCTAssertFalse(alreadyStarted)
        flags.restore()
        await XCTAssertThrowsErrorAsync(try await fixture.service.approveExperimentalClick(requestID: request.id, digest: request.payloadDigest))
        XCTAssertEqual(counter.value, 0)
    }
    func testExperimentalSystemPressRevocationAfterStartRecordsUnknown() async throws {
        let fixture = try Fixture(), flags = ExperimentalSystemAuthorization()
        let task = try await fixture.service.createTask(title: "started revocation")
        let ref = AXUIElementCreateSystemWide()
        let identity = SafariClickIdentity(pid: 42, window: "window", url: "https://example.com/a", role: "AXButton", title: "Open", enabled: true, requestDigest: "")
        let candidate = SafariClickCandidate(element: ref, window: ref, launchDate: Date(timeIntervalSince1970: 1), identity: identity)
        let entered = expectation(description: "action started"), block = ExperimentalClickBlockingAction(entered)
        await fixture.service.installExperimentalSystemClickForTesting(authorization: { flags.allowed }) { _, _ in block.run(); return .success }
        let request = try await fixture.service.submitExperimentalClick(taskID: task.id, identity: identity, capture: SafariClickCapture { [candidate] })
        let approval = Task { try await fixture.service.approveExperimentalClick(requestID: request.id, digest: request.payloadDigest) }
        await fulfillment(of: [entered], timeout: 2)
        flags.revoke(permission: true)
        let alreadyStarted = try await fixture.service.experimentalSystemClickAuthorizationRevokedForTesting()
        XCTAssertTrue(alreadyStarted)
        let events = try fixture.audit.events(for: task.id)
        XCTAssertTrue(events.contains { $0.result == "action outcome unknown; do not retry automatically" })
        block.release.signal()
        _ = try? await approval.value
    }
    func testExperimentalSystemPressRevocationBeforeAtomicStartCannotBeRevived() async throws {
        let fixture = try Fixture(), counter = ExperimentalClickActionCounter(), flags = ExperimentalSystemAuthorization()
        let task = try await fixture.service.createTask(title: "atomic start")
        let ref = AXUIElementCreateSystemWide()
        let identity = SafariClickIdentity(pid: 42, window: "window", url: "https://example.com/a", role: "AXButton", title: "Open", enabled: true, requestDigest: "")
        let candidate = SafariClickCandidate(element: ref, window: ref, launchDate: Date(timeIntervalSince1970: 1), identity: identity)
        let entered = expectation(description: "before atomic start"), block = ExperimentalClickBlockingAction(entered)
        await fixture.service.installExperimentalSystemClickForTesting(authorization: { flags.allowed }, beforeStart: { block.run() }) { _, _ in counter.increment(); return .success }
        let request = try await fixture.service.submitExperimentalClick(taskID: task.id, identity: identity, capture: SafariClickCapture { [candidate] })
        let attempt = Task { try await fixture.service.approveExperimentalClick(requestID: request.id, digest: request.payloadDigest) }
        await fulfillment(of: [entered], timeout: 2)
        flags.revoke(permission: false)
        let started = try await fixture.service.experimentalSystemClickAuthorizationRevokedForTesting()
        XCTAssertFalse(started)
        flags.restore()
        block.release.signal()
        do { try await attempt.value; XCTFail("revoked action succeeded") } catch { }
        XCTAssertEqual(counter.value, 0)
    }
    func testExperimentalSystemPressRevocationBetweenCheckAndCASNeverStarts() async throws {
        let fixture = try Fixture(), counter = ExperimentalClickActionCounter()
        let task = try await fixture.service.createTask(title: "check then start")
        let ref = AXUIElementCreateSystemWide()
        let identity = SafariClickIdentity(pid: 42, window: "window", url: "https://example.com/a", role: "AXButton", title: "Open", enabled: true, requestDigest: "")
        let candidate = SafariClickCandidate(element: ref, window: ref, launchDate: Date(timeIntervalSince1970: 1), identity: identity)
        let entered = expectation(description: "authorization check waiting")
        let gate = ExperimentalAuthorizationCheckPause(entered)
        await fixture.service.installExperimentalSystemClickForTesting(authorization: { gate.check() }, beforeStart: { gate.arm() }) { _, _ in counter.increment(); return .success }
        let request = try await fixture.service.submitExperimentalClick(taskID: task.id, identity: identity, capture: SafariClickCapture { [candidate] })
        let attempt = Task { try await fixture.service.approveExperimentalClick(requestID: request.id, digest: request.payloadDigest) }
        await fulfillment(of: [entered], timeout: 2)
        let started = try await fixture.service.experimentalSystemClickAuthorizationRevokedForTesting()
        XCTAssertFalse(started)
        gate.release.signal()
        do { try await attempt.value; XCTFail("revoked action succeeded") } catch { }
        XCTAssertEqual(counter.value, 0)
    }
    func testExperimentalClickModeDisableRevokesPendingAndReenableUsesNewGeneration() async throws {
        let fixture = try Fixture(), counter = ExperimentalClickActionCounter()
        let task = try await fixture.service.createTask(title: "mode")
        let ref = AXUIElementCreateSystemWide()
        let identity = SafariClickIdentity(pid: 42, window: "window", url: "https://example.com/a", role: "AXButton", title: "Open", enabled: true, requestDigest: "")
        let candidate = SafariClickCandidate(element: ref, window: ref, launchDate: Date(timeIntervalSince1970: 1), identity: identity)
        try fixture.service.enableExperimentalClickModeForTesting(allowed: true) { _, _ in counter.increment(); return .success }
        let first = try await fixture.service.submitExperimentalClick(taskID: task.id, identity: identity, capture: SafariClickCapture { [candidate] })
        XCTAssertTrue(fixture.service.isExperimentalClickModeEnabled)
        let cleanup = fixture.service.disableExperimentalClickMode()
        try await cleanup.value
        XCTAssertFalse(fixture.service.isExperimentalClickModeEnabled)
        XCTAssertEqual(try fixture.requests.fetch(id: first.id)?.1, .rejected)
        await XCTAssertThrowsErrorAsync(try await fixture.service.approveExperimentalClick(requestID: first.id, digest: first.payloadDigest))
        try fixture.service.enableExperimentalClickModeForTesting(allowed: true) { _, _ in counter.increment(); return .success }
        let second = try await fixture.service.submitExperimentalClick(taskID: task.id, identity: identity, capture: SafariClickCapture { [candidate] })
        try await fixture.service.approveExperimentalClick(requestID: second.id, digest: second.payloadDigest)
        XCTAssertEqual(counter.value, 1)
    }
    func testExperimentalClickModeCannotEnableWithoutAuthorization() throws {
        let fixture = try Fixture()
        XCTAssertThrowsError(try fixture.service.enableExperimentalClickModeForTesting(allowed: false) { _, _ in XCTFail("must not execute"); return .success })
    }
    func testExperimentalClickModeCleanupFailureCanBeRetried() async throws {
        let fixture = try Fixture(), counter = ExperimentalClickActionCounter()
        let task = try await fixture.service.createTask(title: "cleanup")
        let ref = AXUIElementCreateSystemWide()
        let identity = SafariClickIdentity(pid: 42, window: "window", url: "https://example.com/a", role: "AXButton", title: "Open", enabled: true, requestDigest: "")
        let candidate = SafariClickCandidate(element: ref, window: ref, launchDate: Date(timeIntervalSince1970: 1), identity: identity)
        try fixture.service.enableExperimentalClickModeForTesting(allowed: true) { _, _ in counter.increment(); return .success }
        let request = try await fixture.service.submitExperimentalClick(taskID: task.id, identity: identity, capture: SafariClickCapture { [candidate] })
        try fixture.database.write { db in try db.execute(sql: "CREATE TRIGGER reject_mode_cleanup BEFORE INSERT ON approvals BEGIN SELECT RAISE(ABORT, 'test'); END") }
        let first = fixture.service.disableExperimentalClickMode()
        do { _ = try await first.value; XCTFail("expected cleanup failure") } catch { }
        XCTAssertTrue(fixture.service.isExperimentalClickCleanupRequired)
        XCTAssertThrowsError(try fixture.service.enableExperimentalClickModeForTesting(allowed: true) { _, _ in .success })
        try fixture.database.write { db in try db.execute(sql: "DROP TRIGGER reject_mode_cleanup") }
        let retry = fixture.service.disableExperimentalClickMode()
        _ = try await retry.value
        XCTAssertFalse(fixture.service.isExperimentalClickCleanupRequired)
        XCTAssertEqual(try fixture.requests.fetch(id: request.id)?.1, .rejected)
        XCTAssertEqual(counter.value, 0)
    }
    func testExperimentalClickModeCanBeDisabledAfterPermissionLoss() async throws {
        let fixture = try Fixture(), flags = ExperimentalSystemAuthorization()
        await fixture.service.installExperimentalSystemClickForTesting(authorization: { flags.allowed }) { _, _ in .success }
        flags.revoke(permission: true)
        XCTAssertFalse(fixture.service.isExperimentalClickModeEnabled)
        XCTAssertTrue(fixture.service.isExperimentalClickCleanupRequired)
        let cleanup = fixture.service.disableExperimentalClickMode()
        _ = try await cleanup.value
        XCTAssertFalse(fixture.service.isExperimentalClickModeEnabled)
    }
    func testExperimentalClickModeOldPreparedRequestCannotCommitAfterReenable() async throws {
        let fixture = try Fixture(), counter = ExperimentalClickActionCounter()
        let task = try await fixture.service.createTask(title: "mode race")
        let ref = AXUIElementCreateSystemWide()
        let identity = SafariClickIdentity(pid: 42, window: "window", url: "https://example.com/a", role: "AXButton", title: "Open", enabled: true, requestDigest: "")
        let candidate = SafariClickCandidate(element: ref, window: ref, launchDate: Date(timeIntervalSince1970: 1), identity: identity)
        let entered = expectation(description: "prepared"), gate = ExperimentalClickVerificationGate(entered: entered, blockAt: 1)
        try fixture.service.enableExperimentalClickModeForTesting(allowed: true, beforeCommit: { await gate.visit() }) { _, _ in counter.increment(); return .success }
        let submit = Task { try await fixture.service.submitExperimentalClick(taskID: task.id, identity: identity, capture: SafariClickCapture { [candidate] }) }
        await fulfillment(of: [entered], timeout: 2)
        let cleanup = fixture.service.disableExperimentalClickMode()
        _ = try await cleanup.value
        try fixture.service.enableExperimentalClickModeForTesting(allowed: true) { _, _ in counter.increment(); return .success }
        await gate.release()
        do { _ = try await submit.value; XCTFail("old generation committed") } catch { }
        XCTAssertTrue(try fixture.requests.list(status: .pending).filter { $0.0.taskID == task.id }.isEmpty)
        XCTAssertEqual(counter.value, 0)
    }
    func testExperimentalClickModeDisableAfterStartReportsUnknown() async throws {
        let fixture = try Fixture()
        let actualTask = try await fixture.service.createTask(title: "mode started")
        let ref = AXUIElementCreateSystemWide()
        let identity = SafariClickIdentity(pid: 42, window: "window", url: "https://example.com/a", role: "AXButton", title: "Open", enabled: true, requestDigest: "")
        let candidate = SafariClickCandidate(element: ref, window: ref, launchDate: Date(timeIntervalSince1970: 1), identity: identity)
        let entered = expectation(description: "action started"), block = ExperimentalClickBlockingAction(entered)
        try fixture.service.enableExperimentalClickModeForTesting(allowed: true) { _, _ in block.run(); return .success }
        let request = try await fixture.service.submitExperimentalClick(taskID: actualTask.id, identity: identity, capture: SafariClickCapture { [candidate] })
        let approval = Task { try await fixture.service.approveExperimentalClick(requestID: request.id, digest: request.payloadDigest) }
        await fulfillment(of: [entered], timeout: 2)
        let cleanup = fixture.service.disableExperimentalClickMode()
        let started = try await cleanup.value
        XCTAssertTrue(started)
        XCTAssertTrue(try fixture.audit.events(for: actualTask.id).contains { $0.result == "action outcome unknown; do not retry automatically" })
        block.release.signal()
        _ = try? await approval.value
    }
    func testExperimentalClickModePermissionLossCannotRevivePendingTicket() async throws {
        let fixture = try Fixture(), flags = ExperimentalSystemAuthorization(), counter = ExperimentalClickActionCounter()
        let task = try await fixture.service.createTask(title: "permission revoked")
        let ref = AXUIElementCreateSystemWide()
        let identity = SafariClickIdentity(pid: 42, window: "window", url: "https://example.com/a", role: "AXButton", title: "Open", enabled: true, requestDigest: "")
        let candidate = SafariClickCandidate(element: ref, window: ref, launchDate: Date(timeIntervalSince1970: 1), identity: identity)
        await fixture.service.installExperimentalSystemClickForTesting(authorization: { flags.allowed }) { _, _ in counter.increment(); return .success }
        let request = try await fixture.service.submitExperimentalClick(taskID: task.id, identity: identity, capture: SafariClickCapture { [candidate] })
        flags.revoke(permission: true)
        XCTAssertFalse(fixture.service.isExperimentalClickModeEnabled)
        XCTAssertTrue(fixture.service.isExperimentalClickCleanupRequired)
        flags.restore()
        XCTAssertFalse(fixture.service.isExperimentalClickModeEnabled)
        await XCTAssertThrowsErrorAsync(try await fixture.service.approveExperimentalClick(requestID: request.id, digest: request.payloadDigest))
        let cleanup = fixture.service.disableExperimentalClickMode()
        _ = try await cleanup.value
        XCTAssertEqual(try fixture.requests.fetch(id: request.id)?.1, .rejected)
        XCTAssertEqual(counter.value, 0)
    }
    func testExperimentalClickModeObservedPermissionLossInvalidatesOtherPending() async throws {
        let fixture = try Fixture(), flags = ExperimentalSystemAuthorization(), counter = ExperimentalClickActionCounter()
        let task = try await fixture.service.createTask(title: "permission revoked")
        let ref = AXUIElementCreateSystemWide()
        let identity = SafariClickIdentity(pid: 42, window: "window", url: "https://example.com/a", role: "AXButton", title: "Open", enabled: true, requestDigest: "")
        let candidate = SafariClickCandidate(element: ref, window: ref, launchDate: Date(timeIntervalSince1970: 1), identity: identity)
        await fixture.service.installExperimentalSystemClickForTesting(authorization: { flags.allowed }) { _, _ in counter.increment(); return .success }
        let first = try await fixture.service.submitExperimentalClick(taskID: task.id, identity: identity, capture: SafariClickCapture { [candidate] })
        let second = try await fixture.service.submitExperimentalClick(taskID: task.id, identity: identity, capture: SafariClickCapture { [candidate] })
        flags.revoke(permission: true)
        await XCTAssertThrowsErrorAsync(try await fixture.service.approveExperimentalClick(requestID: first.id, digest: first.payloadDigest))
        flags.restore()
        await XCTAssertThrowsErrorAsync(try await fixture.service.approveExperimentalClick(requestID: second.id, digest: second.payloadDigest))
        XCTAssertEqual(counter.value, 0)
    }
    func testExperimentalClickTargetSelectionNeedsApprovalAndUsesExactInputs() async throws {
        let fixture = try Fixture(), counter = ExperimentalClickActionCounter()
        let task = try await fixture.service.createTask(title: "select")
        let ref = AXUIElementCreateSystemWide()
        let identity = SafariClickIdentity(pid: 42, window: "window", url: "https://example.com/a?token=private", role: "AXButton", title: "Open", enabled: true, requestDigest: "")
        let candidate = SafariClickCandidate(element: ref, window: ref, launchDate: Date(timeIntervalSince1970: 1), identity: identity)
        try fixture.service.enableExperimentalClickModeForTesting(allowed: true) { _, _ in counter.increment(); return .success }
        fixture.service.installExperimentalClickTargetSelectorForTesting { role, title in
            guard role == identity.role, title == identity.title else { throw TaskServiceCapabilityError.unavailable }
            return (identity, SafariClickCapture { [candidate] })
        }
        let request = try await fixture.service.submitExperimentalSafariClick(taskID: task.id, role: "AXButton", title: "Open")
        XCTAssertEqual(counter.value, 0)
        let previews = try await fixture.service.listPendingApprovalRequests(taskID: task.id)
        XCTAssertEqual(previews.first?.target, identity.url)
        try await fixture.service.approveExperimentalClick(requestID: request.id, digest: request.payloadDigest)
        XCTAssertEqual(counter.value, 1)
        await XCTAssertThrowsErrorAsync(try await fixture.service.approveExperimentalClick(requestID: request.id, digest: request.payloadDigest))
        XCTAssertEqual(counter.value, 1)
    }
    func testExperimentalClickTargetSelectionRejectsMissingOrAmbiguous() async throws {
        for candidateCount in [0, 2] {
            let fixture = try Fixture(), counter = ExperimentalClickActionCounter()
            let task = try await fixture.service.createTask(title: "select")
            let ref = AXUIElementCreateSystemWide()
            let identity = SafariClickIdentity(pid: 42, window: "window", url: "https://example.com/a", role: "AXButton", title: "Open", enabled: true, requestDigest: "")
            let candidate = SafariClickCandidate(element: ref, window: ref, launchDate: Date(timeIntervalSince1970: 1), identity: identity)
            try fixture.service.enableExperimentalClickModeForTesting(allowed: true) { _, _ in counter.increment(); return .success }
            fixture.service.installExperimentalClickTargetSelectorForTesting { _, _ in (identity, SafariClickCapture { Array(repeating: candidate, count: candidateCount) }) }
            await XCTAssertThrowsErrorAsync(try await fixture.service.submitExperimentalSafariClick(taskID: task.id, role: "AXButton", title: "Open"))
            XCTAssertTrue(try fixture.requests.list(status: .pending).isEmpty)
            XCTAssertEqual(counter.value, 0)
        }
    }
    func testExperimentalClickRoutesRequireModeAndPersistedApproval() async throws {
        let fixture = try Fixture(), counter = ExperimentalClickActionCounter()
        let task = try await fixture.service.createTask(title: "route")
        let ref = AXUIElementCreateSystemWide()
        let identity = SafariClickIdentity(pid: 42, window: "window", url: "https://example.com/a", role: "AXButton", title: "Open", enabled: true, requestDigest: "")
        let candidate = SafariClickCandidate(element: ref, window: ref, launchDate: Date(timeIntervalSince1970: 1), identity: identity)
        fixture.service.installExperimentalClickTargetSelectorForTesting { _, _ in (identity, SafariClickCapture { [candidate] }) }
        let server = LoopbackServer(service: fixture.service)
        let body = try JSONEncoder().encode(["role": "AXButton", "title": "Open"])
        let path = "/tasks/\(task.id.uuidString)/safari-click"
        let disabled = await server.handle(method: "POST", path: path, body: body, peerHost: "127.0.0.1")
        XCTAssertNotEqual(disabled.status, 201)
        try fixture.service.enableExperimentalClickModeForTesting(allowed: true) { _, _ in counter.increment(); return .success }
        let submitted = await server.handle(method: "POST", path: path, body: body, peerHost: "127.0.0.1")
        XCTAssertEqual(submitted.status, 201)
        let request = try JSONDecoder().decode(ToolRequest.self, from: submitted.body)
        XCTAssertEqual(counter.value, 0)
        let approvalBody = try JSONEncoder().encode(["digest": request.payloadDigest])
        let approved = await server.handle(method: "POST", path: "/requests/\(request.id.uuidString)/safari-click-approve", body: approvalBody, peerHost: "127.0.0.1")
        XCTAssertEqual(approved.status, 204)
        XCTAssertEqual(counter.value, 1)
        let replay = await server.handle(method: "POST", path: "/requests/\(request.id.uuidString)/safari-click-approve", body: approvalBody, peerHost: "127.0.0.1")
        XCTAssertNotEqual(replay.status, 204)
        XCTAssertEqual(counter.value, 1)
        let secondResponse = await server.handle(method: "POST", path: path, body: body, peerHost: "127.0.0.1")
        let second = try JSONDecoder().decode(ToolRequest.self, from: secondResponse.body)
        let cleanup = fixture.service.disableExperimentalClickMode()
        _ = try await cleanup.value
        let secondBody = try JSONEncoder().encode(["digest": second.payloadDigest])
        let blocked = await server.handle(method: "POST", path: "/requests/\(second.id.uuidString)/safari-click-approve", body: secondBody, peerHost: "127.0.0.1")
        XCTAssertNotEqual(blocked.status, 204)
        XCTAssertEqual(counter.value, 1)
    }
    func testExperimentalClickApprovalWaitsForSafariFocusBeforePress() async throws {
        let fixture = try Fixture(), counter = ExperimentalClickActionCounter()
        let task = try await fixture.service.createTask(title: "focus")
        let ref = AXUIElementCreateSystemWide()
        let identity = SafariClickIdentity(pid: 42, window: "window", url: "https://example.com/a", role: "AXButton", title: "Open", enabled: true, requestDigest: "")
        let candidate = SafariClickCandidate(element: ref, window: ref, launchDate: Date(timeIntervalSince1970: 1), identity: identity)
        let provider = ExperimentalClickFocusFixture(candidate)
        try fixture.service.enableExperimentalClickModeForTesting(allowed: true) { _, _ in counter.increment(); return .success }
        fixture.service.installExperimentalClickTargetSelectorForTesting { _, _ in (identity, SafariClickCapture { try await provider.next() }) }
        let request = try await fixture.service.submitExperimentalSafariClick(taskID: task.id, role: "AXButton", title: "Open")
        try await fixture.service.approveExperimentalClick(requestID: request.id, digest: request.payloadDigest)
        XCTAssertEqual(counter.value, 1)
    }
    func testExperimentalClickRouteReportsUnknownWithoutTargetLeak() async throws {
        let fixture = try Fixture(), counter = ExperimentalClickActionCounter()
        let task = try await fixture.service.createTask(title: "route failure")
        let ref = AXUIElementCreateSystemWide()
        let identity = SafariClickIdentity(pid: 42, window: "window", url: "https://example.com/a?token=secret", role: "AXButton", title: "private title", enabled: true, requestDigest: "")
        let candidate = SafariClickCandidate(element: ref, window: ref, launchDate: Date(timeIntervalSince1970: 1), identity: identity)
        fixture.service.installExperimentalClickTargetSelectorForTesting { _, _ in (identity, SafariClickCapture { [candidate] }) }
        try fixture.service.enableExperimentalClickModeForTesting(allowed: true) { _, _ in counter.increment(); return .failure }
        let server = LoopbackServer(service: fixture.service)
        let body = try JSONEncoder().encode(["role": "AXButton", "title": "private title"])
        let submitted = await server.handle(method: "POST", path: "/tasks/\(task.id.uuidString)/safari-click", body: body, peerHost: "127.0.0.1")
        let request = try JSONDecoder().decode(ToolRequest.self, from: submitted.body)
        let approvalBody = try JSONEncoder().encode(["digest": request.payloadDigest])
        let response = await server.handle(method: "POST", path: "/requests/\(request.id.uuidString)/safari-click-approve", body: approvalBody, peerHost: "127.0.0.1")
        XCTAssertEqual(response.status, 409)
        let text = String(decoding: response.body, as: UTF8.self)
        XCTAssertTrue(text.contains("结果未知"))
        XCTAssertFalse(text.contains("secret"))
        XCTAssertFalse(text.contains("private title"))
        XCTAssertEqual(counter.value, 1)
    }
    func testExperimentalClickDisabledModeDoesNotInvokeSelectorDuringCleanup() async throws {
        let fixture = try Fixture(), selections = ExperimentalClickActionCounter()
        let task = try await fixture.service.createTask(title: "selector disabled")
        let ref = AXUIElementCreateSystemWide()
        let identity = SafariClickIdentity(pid: 42, window: "window", url: "https://example.com/a", role: "AXButton", title: "Open", enabled: true, requestDigest: "")
        let candidate = SafariClickCandidate(element: ref, window: ref, launchDate: Date(timeIntervalSince1970: 1), identity: identity)
        let entered = expectation(description: "cleanup waiting"), gate = ExperimentalClickVerificationGate(entered: entered, blockAt: 1)
        try fixture.service.enableExperimentalClickModeForTesting(allowed: true) { _, _ in .success }
        fixture.service.installExperimentalClickTargetSelectorForTesting { _, _ in
            selections.increment()
            return (identity, SafariClickCapture(beforeClear: { await gate.visit() }) { [candidate] })
        }
        _ = try await fixture.service.submitExperimentalSafariClick(taskID: task.id, role: "AXButton", title: "Open")
        let cleanup = fixture.service.disableExperimentalClickMode()
        await fulfillment(of: [entered], timeout: 2)
        await XCTAssertThrowsErrorAsync(try await fixture.service.submitExperimentalSafariClick(taskID: task.id, role: "AXButton", title: "Open"))
        XCTAssertEqual(selections.value, 1)
        await gate.release()
        _ = try await cleanup.value
    }
    func testExperimentalClickBarrierRouteExplainsUnavailableRecovery() async throws {
        let fixture = try Fixture(), counter = ExperimentalClickActionCounter()
        let firstTask = try await fixture.service.createTask(title: "first")
        let secondTask = try await fixture.service.createTask(title: "second")
        let ref = AXUIElementCreateSystemWide()
        let identity = SafariClickIdentity(pid: 42, window: "window", url: "https://example.com/a", role: "AXButton", title: "Open", enabled: true, requestDigest: "")
        let candidate = SafariClickCandidate(element: ref, window: ref, launchDate: Date(timeIntervalSince1970: 1), identity: identity)
        fixture.service.installExperimentalClickTargetSelectorForTesting { _, _ in (identity, SafariClickCapture { [candidate] }) }
        try fixture.service.enableExperimentalClickModeForTesting(allowed: true) { _, _ in counter.increment(); return .failure }
        let server = LoopbackServer(service: fixture.service)
        let body = try JSONEncoder().encode(["role": "AXButton", "title": "Open"])
        let firstResponse = await server.handle(method: "POST", path: "/tasks/\(firstTask.id.uuidString)/safari-click", body: body, peerHost: "127.0.0.1")
        let first = try JSONDecoder().decode(ToolRequest.self, from: firstResponse.body)
        let firstApproval = try JSONEncoder().encode(["digest": first.payloadDigest])
        let firstResult = await server.handle(method: "POST", path: "/requests/\(first.id.uuidString)/safari-click-approve", body: firstApproval, peerHost: "127.0.0.1")
        XCTAssertEqual(firstResult.status, 409)
        let secondResponse = await server.handle(method: "POST", path: "/tasks/\(secondTask.id.uuidString)/safari-click", body: body, peerHost: "127.0.0.1")
        let second = try JSONDecoder().decode(ToolRequest.self, from: secondResponse.body)
        let secondApproval = try JSONEncoder().encode(["digest": second.payloadDigest])
        let blocked = await server.handle(method: "POST", path: "/requests/\(second.id.uuidString)/safari-click-approve", body: secondApproval, peerHost: "127.0.0.1")
        XCTAssertEqual(blocked.status, 409)
        XCTAssertTrue(String(decoding: blocked.body, as: UTF8.self).contains("没有解除入口"))
        XCTAssertEqual(counter.value, 1)
    }
    func testExperimentalClickConfirmedBeforeStartTimeoutClearsBarrier() async throws {
        let fixture = try Fixture(), counter = ExperimentalClickActionCounter()
        let task = try await fixture.service.createTask(title: "before start")
        let ref = AXUIElementCreateSystemWide()
        let identity = SafariClickIdentity(pid: 42, window: "window", url: "https://example.com/a", role: "AXButton", title: "Open", enabled: true, requestDigest: "")
        let candidate = SafariClickCandidate(element: ref, window: ref, launchDate: Date(timeIntervalSince1970: 1), identity: identity)
        let entered = expectation(description: "worker before start"), block = ExperimentalClickBlockingAction(entered)
        await fixture.service.installExperimentalSystemClickForTesting(beforeStart: { block.run() }) { _, _ in counter.increment(); return .success }
        let request = try await fixture.service.submitExperimentalClick(taskID: task.id, identity: identity, capture: SafariClickCapture { [candidate] })
        let approval = Task { try await fixture.service.approveExperimentalClick(requestID: request.id, digest: request.payloadDigest) }
        await fulfillment(of: [entered], timeout: 2)
        do { try await approval.value; XCTFail("timeout expected") }
        catch SafariPressFailure.timeoutBeforeStart { }
        catch { XCTFail("unexpected error: \(error)") }
        XCTAssertFalse(try SQLitePersistenceUnitOfWork(database: fixture.database).hasExperimentalClickBarrier())
        XCTAssertEqual(counter.value, 0)
        block.release.signal()
    }
    func testExperimentalClickBeforeStartFailureWriteKeepsBarrier() async throws {
        let fixture = try Fixture(), counter = ExperimentalClickActionCounter()
        let task = try await fixture.service.createTask(title: "before start rollback")
        let ref = AXUIElementCreateSystemWide()
        let identity = SafariClickIdentity(pid: 42, window: "window", url: "https://example.com/a", role: "AXButton", title: "Open", enabled: true, requestDigest: "")
        let candidate = SafariClickCandidate(element: ref, window: ref, launchDate: Date(timeIntervalSince1970: 1), identity: identity)
        let entered = expectation(description: "worker before start"), block = ExperimentalClickBlockingAction(entered)
        await fixture.service.installExperimentalSystemClickForTesting(beforeStart: { block.run() }) { _, _ in counter.increment(); return .success }
        let request = try await fixture.service.submitExperimentalClick(taskID: task.id, identity: identity, capture: SafariClickCapture { [candidate] })
        try fixture.database.write { db in try db.execute(sql: "CREATE TRIGGER reject_safe_finish BEFORE UPDATE ON tool_requests WHEN NEW.status = 'failed' BEGIN SELECT RAISE(ABORT, 'test'); END") }
        let approval = Task { try await fixture.service.approveExperimentalClick(requestID: request.id, digest: request.payloadDigest) }
        await fulfillment(of: [entered], timeout: 2)
        do { try await approval.value; XCTFail("timeout expected") } catch { }
        XCTAssertTrue(try SQLitePersistenceUnitOfWork(database: fixture.database).hasExperimentalClickBarrier())
        XCTAssertEqual(counter.value, 0)
        block.release.signal()
    }
    func testExperimentalSystemPressRunsOnlyAfterDurableApprovalAndOnce() async throws {
        let fixture = try Fixture(), counter = ExperimentalClickActionCounter()
        let task = try await fixture.service.createTask(title: "system press test")
        let ref = AXUIElementCreateSystemWide()
        let identity = SafariClickIdentity(pid: 42, window: "window", url: "https://example.com/a", role: "AXButton", title: "Open", enabled: true, requestDigest: "")
        let candidate = SafariClickCandidate(element: ref, window: ref, launchDate: Date(timeIntervalSince1970: 1), identity: identity)
        await fixture.service.installExperimentalSystemClickForTesting { _, operation in
            XCTAssertEqual(operation as String, kAXPressAction as String)
            XCTAssertEqual(try? fixture.approvals.list().filter { $0.decision == .approved }.count, 1)
            counter.increment()
            return .success
        }
        let request = try await fixture.service.submitExperimentalClick(taskID: task.id, identity: identity, capture: SafariClickCapture { [candidate] })
        XCTAssertEqual(counter.value, 0)
        try await fixture.service.approveExperimentalClick(requestID: request.id, digest: request.payloadDigest)
        XCTAssertEqual(counter.value, 1)
        await XCTAssertThrowsErrorAsync(try await fixture.service.approveExperimentalClick(requestID: request.id, digest: request.payloadDigest))
        XCTAssertEqual(counter.value, 1)
    }
    func testExperimentalSystemPressDenialNeverCallsSystem() async throws {
        let fixture = try Fixture(), counter = ExperimentalClickActionCounter()
        let task = try await fixture.service.createTask(title: "system press denied")
        let ref = AXUIElementCreateSystemWide()
        let identity = SafariClickIdentity(pid: 42, window: "window", url: "https://example.com/a", role: "AXButton", title: "Open", enabled: true, requestDigest: "")
        let candidate = SafariClickCandidate(element: ref, window: ref, launchDate: Date(timeIntervalSince1970: 1), identity: identity)
        await fixture.service.installExperimentalSystemClickForTesting { _, _ in counter.increment(); return .success }
        let request = try await fixture.service.submitExperimentalClick(taskID: task.id, identity: identity, capture: SafariClickCapture { [candidate] })
        await XCTAssertThrowsErrorAsync(try await fixture.service.approveExperimentalClick(requestID: request.id, digest: "wrong"))
        await XCTAssertThrowsErrorAsync(try await fixture.service.approveExperimentalClick(requestID: request.id, digest: request.payloadDigest))
        XCTAssertEqual(counter.value, 0)
    }
    func testExperimentalSystemPressTimeoutAfterStartIsUnknown() async throws {
        let fixture = try Fixture(), counter = ExperimentalClickActionCounter()
        let task = try await fixture.service.createTask(title: "system press timeout")
        let ref = AXUIElementCreateSystemWide()
        let identity = SafariClickIdentity(pid: 42, window: "window", url: "https://example.com/a", role: "AXButton", title: "Open", enabled: true, requestDigest: "")
        let candidate = SafariClickCandidate(element: ref, window: ref, launchDate: Date(timeIntervalSince1970: 1), identity: identity)
        let entered = expectation(description: "system action entered")
        let block = ExperimentalClickBlockingAction(entered)
        await fixture.service.installExperimentalSystemClickForTesting { _, _ in counter.increment(); block.run(); return .success }
        let request = try await fixture.service.submitExperimentalClick(taskID: task.id, identity: identity, capture: SafariClickCapture { [candidate] })
        let attempt = Task { try await fixture.service.approveExperimentalClick(requestID: request.id, digest: request.payloadDigest) }
        await fulfillment(of: [entered], timeout: 2)
        do { try await attempt.value; XCTFail("expected unknown") }
        catch SafariPressFailure.actionOutcomeUnknown { }
        catch { XCTFail("unexpected error: \(error)") }
        block.release.signal()
        await XCTAssertThrowsErrorAsync(try await fixture.service.approveExperimentalClick(requestID: request.id, digest: request.payloadDigest))
        XCTAssertEqual(counter.value, 1)
    }
    func testExperimentalSystemPressChangedTargetNeverCallsSystem() async throws {
        let fixture = try Fixture(), counter = ExperimentalClickActionCounter()
        let task = try await fixture.service.createTask(title: "system target changed")
        let ref = AXUIElementCreateSystemWide()
        let identity = SafariClickIdentity(pid: 42, window: "window", url: "https://example.com/a", role: "AXButton", title: "Open", enabled: true, requestDigest: "")
        let candidate = SafariClickCandidate(element: ref, window: ref, launchDate: Date(timeIntervalSince1970: 1), identity: identity)
        let provider = ExperimentalSystemChangingProvider(candidate)
        await fixture.service.installExperimentalSystemClickForTesting { _, _ in counter.increment(); return .success }
        let request = try await fixture.service.submitExperimentalClick(taskID: task.id, identity: identity, capture: SafariClickCapture { await provider.next() })
        await XCTAssertThrowsErrorAsync(try await fixture.service.approveExperimentalClick(requestID: request.id, digest: request.payloadDigest))
        XCTAssertEqual(counter.value, 0)
    }
    func testExperimentalSystemPressFailureIsUnknownAndNeverRetried() async throws {
        let fixture = try Fixture(), counter = ExperimentalClickActionCounter()
        let task = try await fixture.service.createTask(title: "system press failure")
        let ref = AXUIElementCreateSystemWide()
        let identity = SafariClickIdentity(pid: 42, window: "window", url: "https://example.com/a", role: "AXButton", title: "Open", enabled: true, requestDigest: "")
        let candidate = SafariClickCandidate(element: ref, window: ref, launchDate: Date(timeIntervalSince1970: 1), identity: identity)
        await fixture.service.installExperimentalSystemClickForTesting { _, operation in
            XCTAssertEqual(operation as String, kAXPressAction as String)
            counter.increment()
            return .failure
        }
        let request = try await fixture.service.submitExperimentalClick(taskID: task.id, identity: identity, capture: SafariClickCapture { [candidate] })
        do { try await fixture.service.approveExperimentalClick(requestID: request.id, digest: request.payloadDigest); XCTFail("expected unknown") }
        catch SafariPressFailure.actionOutcomeUnknown { }
        catch { XCTFail("unexpected error: \(error)") }
        await XCTAssertThrowsErrorAsync(try await fixture.service.approveExperimentalClick(requestID: request.id, digest: request.payloadDigest))
        XCTAssertEqual(counter.value, 1)
    }
}
private actor ExperimentalSystemChangingProvider {
    let candidate: SafariClickCandidate
    var calls = 0
    init(_ candidate: SafariClickCandidate) { self.candidate = candidate }
    func next() -> [SafariClickCandidate] { calls += 1; return calls == 1 ? [candidate] : [] }
}
private final class ExperimentalSystemAuthorization: @unchecked Sendable {
    private let lock = NSLock()
    private var optedIn = true, permission = true
    var allowed: Bool { lock.lock(); defer { lock.unlock() }; return optedIn && permission }
    func revoke(permission: Bool) { lock.lock(); defer { lock.unlock() }; if permission { self.permission = false } else { optedIn = false } }
    func restore() { lock.lock(); defer { lock.unlock() }; optedIn = true; permission = true }
}
private final class ExperimentalAuthorizationCheckPause: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false
    let entered: XCTestExpectation
    let release = DispatchSemaphore(value: 0)
    init(_ entered: XCTestExpectation) { self.entered = entered }
    func arm() { lock.lock(); defer { lock.unlock() }; armed = true }
    func check() -> Bool {
        lock.lock(); let shouldWait = armed; armed = false; lock.unlock()
        if shouldWait { entered.fulfill(); _ = release.wait(timeout: .now() + 5) }
        return true
    }
}
private actor ExperimentalClickFocusFixture {
    let candidate: SafariClickCandidate
    var calls = 0
    init(_ candidate: SafariClickCandidate) { self.candidate = candidate }
    func next() throws -> [SafariClickCandidate] {
        calls += 1
        if calls == 2 || calls == 3 { throw SafariAXReadError.notFocused }
        return [candidate]
    }
}
#endif

#if !JARVIS_SAFARI_CLICK_EXPERIMENT || (!JARVIS_SAFARI_EXPERIMENT_BUILD && !JARVIS_COMBINED_EXPERIMENT)
extension TaskServiceTests {
    func testExperimentalClickRoutesAreAbsentInDefaultBuild() async throws {
        let fixture = try Fixture(), task = try await fixture.service.createTask(title: "default")
        let server = LoopbackServer(service: fixture.service)
        let body = try JSONEncoder().encode(["role": "AXButton", "title": "Open"])
        let response = await server.handle(method: "POST", path: "/tasks/\(task.id.uuidString)/safari-click", body: body, peerHost: "127.0.0.1")
        XCTAssertEqual(response.status, 404)
        let approval = await server.handle(method: "POST", path: "/requests/\(UUID().uuidString)/safari-click-approve", body: Data(), peerHost: "127.0.0.1")
        XCTAssertEqual(approval.status, 404)
    }
}
#endif

#if os(macOS) && JARVIS_SAFARI_CLICK_EXPERIMENT && JARVIS_SAFARI_CLICK_TESTING && JARVIS_SAFARI_EXPERIMENT_BUILD
extension TaskServiceTests {
    func testReadGateAndClickModeAreIndependent() async throws {
        let fixture = try Fixture(), counter = ExperimentalClickActionCounter()
        let service = try TaskService(taskRepository: fixture.tasks, auditRepository: fixture.audit, policy: Policy(allowSafariRead: true), enableSafariRead: true, requestRepository: fixture.requests, approvalRepository: fixture.approvals, unitOfWork: SQLitePersistenceUnitOfWork(database: fixture.database))
        XCTAssertTrue(service.isSafariReadEnabled())
        try service.enableExperimentalClickModeForTesting(allowed: true) { _, _ in counter.increment(); return .success }
        try service.setSafariReadEnabled(false)
        XCTAssertFalse(service.isSafariReadEnabled())
        let task = try await service.createTask(title: "independent click")
        let ref = AXUIElementCreateSystemWide()
        let identity = SafariClickIdentity(pid: 42, window: "window", url: "https://example.com/a", role: "AXButton", title: "Open", enabled: true, requestDigest: "")
        let candidate = SafariClickCandidate(element: ref, window: ref, launchDate: Date(timeIntervalSince1970: 1), identity: identity)
        let request = try await service.submitExperimentalClick(taskID: task.id, identity: identity, capture: SafariClickCapture { [candidate] })
        try service.setSafariReadEnabled(false)
        XCTAssertEqual(counter.value, 0)
        try await service.approveExperimentalClick(requestID: request.id, digest: request.payloadDigest)
        XCTAssertEqual(counter.value, 1)
        let cleanup = service.disableExperimentalClickMode()
        _ = try await cleanup.value
        XCTAssertFalse(service.isSafariReadEnabled())
    }
}
#endif

#if os(macOS) && JARVIS_SAFARI_CLICK_EXPERIMENT && JARVIS_SAFARI_CLICK_TESTING && JARVIS_SAFARI_EXPERIMENT_BUILD
extension TaskServiceTests {
    func testDisablingClickDoesNotDisableApprovedSafariRead() async throws {
        let fixture = try Fixture(), capture = SafariCaptureFixture()
        let service = try TaskService(taskRepository: fixture.tasks, auditRepository: fixture.audit, policy: Policy(allowSafariRead: true), enableSafariRead: true, requestRepository: fixture.requests, approvalRepository: fixture.approvals, unitOfWork: SQLitePersistenceUnitOfWork(database: fixture.database))
        service.safariCaptureFactory = { capture }
        try service.enableExperimentalClickModeForTesting(allowed: true) { _, _ in XCTFail("No click should run"); return .success }
        _ = try await service.disableExperimentalClickMode().value
        XCTAssertTrue(service.isSafariReadEnabled())
        let task = try await service.createTask(title: "independent read")
        let request = try await service.prepareSafariRead(taskID: task.id)
        guard case .requireApproval = try await service.submit(request: request) else { return XCTFail("Read must require approval") }
        let beforeApproval = try await service.takeEphemeralToolResult(taskID: task.id, requestID: request.id, digest: request.payloadDigest)
        XCTAssertNil(beforeApproval)
        try await service.approve(requestID: request.id, digest: request.payloadDigest)
        try await fixture.waitForRequest(id: request.id, status: .completed)
        let result = try await service.takeEphemeralToolResult(taskID: task.id, requestID: request.id, digest: request.payloadDigest)
        XCTAssertEqual(result, "private page text")
    }

    func testDisablingReadDuringClickTargetSelectionDoesNotCancelClick() async throws {
        let fixture = try Fixture(), selectorGate = DelayedPage(), counter = ExperimentalClickActionCounter()
        let service = try TaskService(taskRepository: fixture.tasks, auditRepository: fixture.audit, policy: Policy(allowSafariRead: true), enableSafariRead: true, requestRepository: fixture.requests, approvalRepository: fixture.approvals, unitOfWork: SQLitePersistenceUnitOfWork(database: fixture.database))
        try service.enableExperimentalClickModeForTesting(allowed: true) { _, _ in counter.increment(); return .success }
        let task = try await service.createTask(title: "independent click selection")
        let ref = AXUIElementCreateSystemWide()
        let identity = SafariClickIdentity(pid: 42, window: "window", url: "https://example.com/a", role: "AXButton", title: "Open", enabled: true, requestDigest: "")
        let candidate = SafariClickCandidate(element: ref, window: ref, launchDate: Date(timeIntervalSince1970: 1), identity: identity)
        service.installExperimentalClickTargetSelectorForTesting { _, _ in
            await selectorGate.wait()
            return (identity, SafariClickCapture { [candidate] })
        }
        let pending = Task { try await service.submitExperimentalSafariClick(taskID: task.id, role: "AXButton", title: "Open") }
        for _ in 0..<100 { if await selectorGate.hasStarted() { break }; try await Task.sleep(for: .milliseconds(10)) }
        let started = await selectorGate.hasStarted()
        XCTAssertTrue(started)
        try service.setSafariReadEnabled(false)
        await selectorGate.release()
        let request = try await pending.value
        XCTAssertFalse(service.isSafariReadEnabled())
        XCTAssertEqual(counter.value, 0)
        try await service.approveExperimentalClick(requestID: request.id, digest: request.payloadDigest)
        XCTAssertEqual(counter.value, 1)
        _ = try await service.disableExperimentalClickMode().value
    }
}
#endif

#if os(macOS) && JARVIS_SAFARI_CLICK_EXPERIMENT && JARVIS_SAFARI_CLICK_TESTING && JARVIS_COMBINED_EXPERIMENT
extension TaskServiceTests {
    func testCombinedClickRequiresExactIdentityBothBooleanMarkersAndOptIn() {
        func gate(_ bundle: String?, _ marker: Any?, _ combined: Any?, _ optedIn: Bool = true, _ trusted: Bool = true) -> Bool {
            TaskService.experimentalSystemClickGateForTesting(bundleID: bundle, marker: marker, combinedMarker: combined, optedIn: optedIn, trusted: trusted)
        }
        let identity = "local.jarvis.combined-experiment"
        XCTAssertTrue(gate(identity, NSNumber(value: true), NSNumber(value: true)))
        XCTAssertFalse(gate("local.jarvis.safari-click-experiment", NSNumber(value: true), NSNumber(value: true)))
        XCTAssertFalse(gate(identity, nil, NSNumber(value: true)))
        XCTAssertFalse(gate(identity, NSNumber(value: true), nil))
        XCTAssertFalse(gate(identity, NSNumber(value: 1), NSNumber(value: true)))
        XCTAssertFalse(gate(identity, NSNumber(value: true), NSNumber(value: 1)))
        XCTAssertFalse(gate(identity, NSNumber(value: true), NSNumber(value: true), false))
        XCTAssertFalse(gate(identity, NSNumber(value: true), NSNumber(value: true), true, false))
    }
}
#endif

extension TaskServiceTests {
    func testExactBrowserDisableReenableRevokesPendingTicket() async throws {
        #if !JARVIS_EXACT_BROWSER_EXPERIMENT && !JARVIS_COMBINED_EXPERIMENT
        throw XCTSkip("Exact browser feature is unavailable in ordinary builds")
        #endif
        let recorder = BrowserRecorder()
        let service = try Fixture(browserOpen: BrowserOpenExecutor(opener: { _ in false }, exactOpener: { url in recorder.record(url); return true }), exactBrowserEnabled: true).service
        let task = try await service.createTask(title: "open")
        let request = ToolRequest(taskID: task.id, name: "browser_open", sideEffect: .externalSend, target: "https://example.com/private?secret=1", payload: "Open in browser")
        _ = try await service.submit(request: request)
        let pending = try await service.listPendingApprovalRequests(taskID: task.id)
        let item = try XCTUnwrap(pending.first)
        XCTAssertEqual(item.target, request.target)
        try service.setExactBrowserEnabled(false)
        try service.setExactBrowserEnabled(true)
        let after = try await service.listPendingApprovalRequests(taskID: task.id)
        XCTAssertFalse(after[0].target.contains("secret"))
        await XCTAssertThrowsErrorAsync(try await service.approve(requestID: item.id, digest: item.digest))
        XCTAssertEqual(recorder.count, 0)
    }
    func testExactBrowserExecutorRejectsRevokedGenerationBeforeOpen() async throws {
        let recorder = BrowserRecorder()
        let executor = BrowserOpenExecutor(opener: { _ in false }, exactOpener: { url in recorder.record(url); return true })
        let gate = ExactBrowserSessionGate()
        gate.setEnabled(true)
        let generation = try XCTUnwrap(gate.capture())
        gate.setEnabled(false)
        gate.setEnabled(true)
        let request = ToolRequest(taskID: UUID(), name: "browser_open", sideEffect: .externalSend, target: "https://example.com/private", payload: "Open in browser")
        await XCTAssertThrowsErrorAsync(try await executor.executeApprovedExact(request, gate: gate, generation: generation))
        XCTAssertEqual(recorder.count, 0)
    }
}

extension TaskServiceTests {
    #if !JARVIS_EXACT_BROWSER_EXPERIMENT && !JARVIS_COMBINED_EXPERIMENT
    func testOrdinaryBuildCannotEnableExactBrowserEvenWithExplicitArguments() throws {
        let fixture = try Fixture()
        let service = try TaskService(taskRepository: fixture.tasks, auditRepository: fixture.audit, policy: Policy(), exactBrowserEnabled: true, allowExactBrowserToggle: true)
        XCTAssertFalse(service.isExactBrowserEnabled())
        XCTAssertThrowsError(try service.setExactBrowserEnabled(true))
    }
    #endif
}
