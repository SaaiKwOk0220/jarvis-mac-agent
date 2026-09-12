import XCTest
import JarvisDomain
@testable import JarvisPolicy

final class PolicyTests: XCTestCase {
    private let taskID = UUID()
    private var config: PolicyConfig {
        PolicyConfig(
            approvedDirectories: ["/tmp/jarvis-project"],
            commandNames: ["swift", "xcodebuild"],
            browserProfiles: ["work"],
            sites: ["example.com"],
            applicationBundleIDs: ["com.apple.TextEdit"]
        )
    }

    func testReadWithinApprovedDirectoryIsAllowed() {
        let request = ToolRequest(taskID: taskID, name: "read_file", sideEffect: .read,
                                  target: "/tmp/jarvis-project/Sources/main.swift", payload: "")
        XCTAssertEqual(Policy().evaluate(request, config: config), .allow)
    }

    func testApprovedLocalCommandIsAllowedOnlyByExactName() {
        let request = ToolRequest(taskID: taskID, name: "swift", sideEffect: .localExecute,
                                  target: "/tmp/jarvis-project", payload: "test")
        XCTAssertEqual(Policy().evaluate(request, config: config), .allow)

        let typo = ToolRequest(taskID: taskID, name: "swiftc && rm", sideEffect: .localExecute,
                               target: "/tmp/jarvis-project", payload: "test")
        XCTAssertEqual(Policy().evaluate(typo, config: config), .deny(reason: "command is not allowlisted"))
    }

    func testLocalWriteAlwaysRequiresApproval() {
        let request = ToolRequest(taskID: taskID, name: "write_file", sideEffect: .localWrite,
                                  target: "/tmp/jarvis-project/out.txt", payload: "hello")
        XCTAssertEqual(Policy().evaluate(request, config: config), .requireApproval(reason: "local write changes local state"))
    }

    func testProtectedExternalEffectsRequireApproval() {
        for effect in [SideEffect.externalSend, .upload, .delete, .credential] {
            let request = ToolRequest(taskID: taskID, name: "action", sideEffect: effect,
                                      target: "example.com", payload: "payload")
            guard case .requireApproval = Policy().evaluate(request, config: config) else {
                XCTFail("expected approval for \(effect)"); continue
            }
        }
    }

    func testMoneyIsUnsupportedAndDenied() {
        let request = ToolRequest(taskID: taskID, name: "pay", sideEffect: .money,
                                  target: "example.com", payload: "100")
        XCTAssertEqual(Policy().evaluate(request, config: config), .deny(reason: "money actions are unsupported"))
    }

    func testApprovalDigestMustMatchExactAction() {
        let request = ToolRequest(taskID: taskID, name: "write_file", sideEffect: .localWrite,
                                  target: "/tmp/jarvis-project/out.txt", payload: "hello")
        XCTAssertTrue(validateApproval(request: request, approvalDigest: request.payloadDigest))
        XCTAssertFalse(validateApproval(request: request, approvalDigest: "changed"))

        let changed = ToolRequest(taskID: taskID, name: request.name, sideEffect: request.sideEffect,
                                  target: request.target, payload: "different")
        XCTAssertFalse(validateApproval(request: changed, approvalDigest: request.payloadDigest))
    }

    func testReadOutsideApprovedDirectoryIsDenied() {
        let request = ToolRequest(taskID: taskID, name: "read_file", sideEffect: .read,
                                  target: "/tmp/other/file.txt", payload: "")
        XCTAssertEqual(Policy().evaluate(request, config: config), .deny(reason: "target is outside approved directories"))
    }

    func testCommandWorkingDirectoryMustBeContainedRatherThanShareAPrefix() {
        let request = ToolRequest(taskID: taskID, name: "swift", sideEffect: .localExecute,
                                  target: "/tmp/jarvis-project-escape", payload: "test")
        XCTAssertEqual(Policy().evaluate(request, config: config), .deny(reason: "target is outside approved directories"))
    }

    func testCommandWithoutAnApprovedWorkingDirectoryIsDenied() {
        let request = ToolRequest(taskID: taskID, name: "swift", sideEffect: .localExecute,
                                  target: "unspecified", payload: "test")
        XCTAssertEqual(Policy().evaluate(request, config: config), .deny(reason: "target is outside approved directories"))
    }

    func testAllowlistedSiteAndApplicationAreAllowedForReads() {
        let site = ToolRequest(taskID: taskID, name: "open_page", sideEffect: .read,
                               target: "https://example.com/inbox", payload: "")
        XCTAssertEqual(Policy().evaluate(site, config: config), .allow)
        let app = ToolRequest(taskID: taskID, name: "focus_app", sideEffect: .read,
                              target: "com.apple.TextEdit", payload: "")
        XCTAssertEqual(Policy().evaluate(app, config: config), .allow)
    }
}
