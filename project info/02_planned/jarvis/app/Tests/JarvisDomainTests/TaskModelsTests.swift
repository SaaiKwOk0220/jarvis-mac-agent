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

    func testActionDigestChangesWhenScopeChanges() {
        let original = ToolRequest.actionDigest(
            name: "open_page", sideEffect: .read, target: "https://example.com", payload: "",
            scope: ToolScope(browserProfile: "work")
        )
        let changedScope = ToolRequest.actionDigest(
            name: "open_page", sideEffect: .read, target: "https://example.com", payload: "",
            scope: ToolScope(browserProfile: "personal")
        )

        XCTAssertNotEqual(original, changedScope)
    }

    func testToolRequestAlwaysComputesDigestFromItsAction() {
        let request = ToolRequest(
            taskID: UUID(),
            name: "write_file",
            sideEffect: .localWrite,
            target: "/tmp/a",
            payload: "contents"
        )

        XCTAssertEqual(
            request.payloadDigest,
            ToolRequest.actionDigest(
                name: "write_file",
                sideEffect: .localWrite,
                target: "/tmp/a",
                payload: "contents"
            )
        )
    }

    func testToolRequestDecodingRejectsMismatchedDigest() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "id": UUID().uuidString,
            "taskID": UUID().uuidString,
            "name": "write_file",
            "sideEffect": "local-write",
            "target": "/tmp/a",
            "payload": "contents",
            "payloadDigest": "not-the-real-digest",
        ])

        XCTAssertThrowsError(try JSONDecoder().decode(ToolRequest.self, from: data))
    }
}
