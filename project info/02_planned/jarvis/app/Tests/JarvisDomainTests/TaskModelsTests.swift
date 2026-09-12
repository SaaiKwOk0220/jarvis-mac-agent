import XCTest
@testable import JarvisDomain

final class TaskModelsTests: XCTestCase {
    func testTaskStatusCodableRoundTripPreservesEveryState() throws {
        let statuses: [TaskStatus] = [
            .draft, .planning, .running, .awaitingApproval,
            .blocked, .failed, .cancelled, .completed,
        ]

        let encoded = try JSONEncoder().encode(statuses)

        XCTAssertEqual(try JSONDecoder().decode([TaskStatus].self, from: encoded), statuses)
    }

    func testSideEffectCodableRoundTripPreservesEveryEffect() throws {
        let effects: [SideEffect] = [
            .read, .localExecute, .localWrite, .externalSend,
            .upload, .delete, .credential, .money,
        ]

        let encoded = try JSONEncoder().encode(effects)

        XCTAssertEqual(try JSONDecoder().decode([SideEffect].self, from: encoded), effects)
    }

    func testActionDigestChangesWhenTargetChanges() {
        let original = ToolRequest.actionDigest(
            name: "open_file", sideEffect: .read, target: "/tmp/a", payload: ""
        )
        let changedTarget = ToolRequest.actionDigest(
            name: "open_file", sideEffect: .read, target: "/tmp/b", payload: ""
        )

        XCTAssertNotEqual(original, changedTarget)
    }

    func testActionDigestChangesWhenPayloadChanges() {
        let original = ToolRequest.actionDigest(
            name: "write_file", sideEffect: .localWrite, target: "/tmp/a", payload: "first"
        )
        let changedPayload = ToolRequest.actionDigest(
            name: "write_file", sideEffect: .localWrite, target: "/tmp/a", payload: "second"
        )

        XCTAssertNotEqual(original, changedPayload)
    }
}
