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
        XCTAssertEqual(Policy().evaluate(request, config: config),
                       .requireApproval(reason: "shell command requires explicit approval"))

        let typo = ToolRequest(taskID: taskID, name: "swiftc && rm", sideEffect: .localExecute,
                               target: "/tmp/jarvis-project", payload: "test")
        XCTAssertEqual(Policy().evaluate(typo, config: config), .deny(reason: "command is not allowlisted"))
    }

    func testLocalExecuteRequiresExplicitApprovalForAnyAllowlistedPayload() {
        let request = ToolRequest(taskID: taskID, name: "swift", sideEffect: .localExecute,
                                  target: "/tmp/jarvis-project", payload: "test")
        XCTAssertEqual(Policy().evaluate(request, config: config),
                       .requireApproval(reason: "shell command requires explicit approval"))

        for payload in ["test --package-path /tmp/jarvis-project", "test; rm -rf /tmp/jarvis-project", "test && rm -rf /tmp/jarvis-project", "run script", "test --filter anything", "test --output /tmp/result"] {
            let allowedButRequiresApproval = ToolRequest(taskID: taskID, name: "swift", sideEffect: .localExecute,
                                                         target: "/tmp/jarvis-project", payload: payload)
            XCTAssertEqual(Policy().evaluate(allowedButRequiresApproval, config: config),
                           .requireApproval(reason: "shell command requires explicit approval"),
                           "payload \(payload) should pass allowlist and require explicit approval")
        }
    }

    func testLocalWriteAlwaysRequiresApproval() {
        let request = ToolRequest(taskID: taskID, name: "write_file", sideEffect: .localWrite,
                                  target: "/tmp/jarvis-project/out.txt", payload: "hello")
        XCTAssertEqual(Policy().evaluate(request, config: config), .requireApproval(reason: "local write changes local state"))
    }

    func testProtectedExternalEffectsRequireApproval() {
        let requests = [
            ToolRequest(taskID: taskID, name: "action", sideEffect: .externalSend,
                        target: "https://example.com", payload: "payload"),
            ToolRequest(taskID: taskID, name: "action", sideEffect: .upload,
                        target: "example.com", payload: "payload"),
            ToolRequest(taskID: taskID, name: "action", sideEffect: .delete,
                        target: "/tmp/jarvis-project/out.txt", payload: "payload"),
            ToolRequest(taskID: taskID, name: "action", sideEffect: .credential,
                        target: "example.com", payload: "payload"),
        ]
        for request in requests {
            guard case .requireApproval = Policy().evaluate(request, config: config) else {
                XCTFail("expected approval for \(request.sideEffect)"); continue
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

    func testApprovalDigestRejectsChangedTargetAndScope() {
        let request = ToolRequest(taskID: taskID, name: "open_page", sideEffect: .read,
                                  target: "https://example.com/inbox", payload: "",
                                  scope: ToolScope(browserProfile: "work"))
        let changedTarget = ToolRequest(taskID: taskID, name: request.name, sideEffect: request.sideEffect,
                                        target: "https://example.com/archive", payload: request.payload,
                                        scope: request.scope)
        let changedScope = ToolRequest(taskID: taskID, name: request.name, sideEffect: request.sideEffect,
                                       target: request.target, payload: request.payload,
                                       scope: ToolScope(browserProfile: "personal"))

        XCTAssertFalse(validateApproval(request: changedTarget, approvalDigest: request.payloadDigest))
        XCTAssertFalse(validateApproval(request: changedScope, approvalDigest: request.payloadDigest))
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

    func testLocalExecuteRejectsScopeWorkingDirectoryOutsideApprovedDirectories() {
        var scopedConfig = config
        scopedConfig.approvedDirectories = ["/tmp"]
        let request = ToolRequest(taskID: taskID, name: "swift", sideEffect: .localExecute,
                                  target: "/tmp", payload: "test",
                                  scope: ToolScope(workingDirectory: "/etc"))
        XCTAssertEqual(Policy().evaluate(request, config: scopedConfig),
                       .deny(reason: "shell working directory is outside approved directories"))
    }

    func testAllowlistedSiteAndApplicationAreAllowedForReads() {
        let site = ToolRequest(taskID: taskID, name: "open_page", sideEffect: .read,
                               target: "https://example.com/inbox", payload: "",
                               scope: ToolScope(browserProfile: "work"))
        XCTAssertEqual(Policy().evaluate(site, config: config), .allow)
        let app = ToolRequest(taskID: taskID, name: "focus_app", sideEffect: .read,
                              target: "com.apple.TextEdit", payload: "")
        XCTAssertEqual(Policy().evaluate(app, config: config), .allow)
    }

    func testBrowserReadRequiresAnAllowlistedStructuredProfile() {
        let missing = ToolRequest(taskID: taskID, name: "open_page", sideEffect: .read,
                                  target: "https://example.com/inbox", payload: "profile=work")
        XCTAssertEqual(Policy().evaluate(missing, config: config), .deny(reason: "browser profile is required"))

        let unknown = ToolRequest(taskID: taskID, name: "open_page", sideEffect: .read,
                                  target: "https://example.com/inbox", payload: "",
                                  scope: ToolScope(browserProfile: "personal"))
        XCTAssertEqual(Policy().evaluate(unknown, config: config), .deny(reason: "browser profile is not allowlisted"))
    }

    func testBrowserAndSendTargetsRequireExactHTTPSHostWithoutUserInfo() {
        let browserProfile = ToolScope(browserProfile: "work")
        for target in ["http://example.com", "https://user@example.com", "https://sub.example.com", "mailto:user@example.com", "not a URL"] {
            let read = ToolRequest(taskID: taskID, name: "open_page", sideEffect: .read,
                                   target: target, payload: "", scope: browserProfile)
            let send = ToolRequest(taskID: taskID, name: "send", sideEffect: .externalSend,
                                   target: target, payload: "")
            XCTAssertNotEqual(Policy().evaluate(read, config: config), .allow, "browser target: \(target)")
            XCTAssertNotEqual(Policy().evaluate(send, config: config), .requireApproval(reason: "external send has an external side effect"), "send target: \(target)")
        }
    }

    func testEveryURLSchemeIsClassifiedAsABrowserTargetRatherThanALocalPath() {
        var filesystemConfig = config
        filesystemConfig.approvedDirectories = [FileManager.default.currentDirectoryPath]
        let scope = ToolScope(browserProfile: "work")

        for target in ["javascript:alert(1)", "data:text/html,<h1>unsafe</h1>", "https:example.com"] {
            let request = ToolRequest(taskID: taskID, name: "open_page", sideEffect: .read,
                                      target: target, payload: "", scope: scope)
            XCTAssertNotEqual(Policy().evaluate(request, config: filesystemConfig), .allow, target)
        }
    }

    func testExternalSendAllowsOnlyExactConfiguredHTTPSHostOrBundleID() {
        let site = ToolRequest(taskID: taskID, name: "send", sideEffect: .externalSend,
                               target: "https://example.com/messages", payload: "hello")
        XCTAssertEqual(Policy().evaluate(site, config: config), .requireApproval(reason: "external send has an external side effect"))
        let app = ToolRequest(taskID: taskID, name: "send", sideEffect: .externalSend,
                              target: "com.apple.TextEdit", payload: "hello")
        XCTAssertEqual(Policy().evaluate(app, config: config), .requireApproval(reason: "external send has an external side effect"))
    }

    func testDeleteResolvesAbsoluteRelativeAndFileURLPathsInsideApprovedDirectory() {
        let scope = ToolScope(workingDirectory: "/tmp/jarvis-project")
        for target in ["/tmp/jarvis-project/out.txt", "file:///tmp/jarvis-project/out.txt", "out.txt", "../jarvis-project/out.txt"] {
            let request = ToolRequest(taskID: taskID, name: "delete_file", sideEffect: .delete,
                                      target: target, payload: "", scope: scope)
            XCTAssertEqual(Policy().evaluate(request, config: config), .requireApproval(reason: "delete removes data"), target)
        }
    }

    func testDeleteDeniesUnscopedAmbiguousEscapingAndRemoteTargets() {
        let scoped = ToolScope(workingDirectory: "/tmp/jarvis-project")
        let cases: [(String, ToolScope?)] = [
            ("out.txt", nil),
            ("../other/out.txt", scoped),
            ("file:///tmp/other/out.txt", scoped),
            ("file://remote/tmp/jarvis-project/out.txt", scoped),
            ("https://example.com/out.txt", scoped),
        ]
        for (target, scope) in cases {
            let request = ToolRequest(taskID: taskID, name: "delete_file", sideEffect: .delete,
                                      target: target, payload: "", scope: scope)
            XCTAssertEqual(Policy().evaluate(request, config: config), .deny(reason: "delete target is not an approved local path"), target)
        }
    }
}
