import Foundation
import JarvisDomain
import JarvisLLM

/// Bridges `AgentLoop`'s tool calls onto `TaskService`, so Jarvis's four
/// workers are advertised to the LLM and every call they make is routed
/// through the service's policy gate and approval flow.
///
/// The loop itself has no way to reach a tool: it only sees an
/// `AgentToolRunner`, and this is the implementation that gives it one. That
/// matters because the policy gate and the approval queue stay authoritative —
/// a shell command the policy wants a human to approve comes back as
/// `.awaitingApproval` and stops the run rather than executing behind the
/// user's back, and a denied call never reaches a worker at all.
///
/// All stored state is immutable, so the instance is safe to share across the
/// loop's concurrent provider calls.
public final class TaskServiceToolRunner: AgentToolRunner, Sendable {
    private let service: any TaskServiceAPI
    private let taskID: UUID
    private let appSupportDirectory: URL
    private let enableSafariRead: Bool
    private let exactBrowserEnabled: Bool

    /// Summary the service writes on the audit event that carries a finished
    /// tool's output; the runner matches observations on this plus the
    /// request's action digest.
    static let toolResultSummary = "tool result"

    /// Reported to the model when the audit timeline carries no result yet.
    /// The tool did run — the loop should keep going rather than treat the
    /// missing read as a failure.
    static let missingObservationFallback = "completed"

    /// Default directory for Jarvis's own files: the same
    /// `<Application Support>/Jarvis` path the app hands to
    /// `PolicyConfig.approvedDirectories` at startup.
    public static var defaultAppSupportDirectory: URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent(AppStorageScope.currentDirectory, isDirectory: true)
    }

    /// - Parameters:
    ///   - service: The live service that owns policy, approval, and audit.
    ///   - taskID: The task every tool call is submitted against, so the
    ///     user's approval queue and timeline show one coherent run.
    ///   - appSupportDirectory: Where Jarvis may read and write; defaults to
    ///     `defaultAppSupportDirectory` and is injectable for tests.
    public init(
        service: any TaskServiceAPI,
        taskID: UUID,
        appSupportDirectory: URL = TaskServiceToolRunner.defaultAppSupportDirectory,
        enableSafariRead: Bool = false,
        exactBrowserEnabled: Bool = false
    ) {
        self.service = service
        self.taskID = taskID
        self.appSupportDirectory = appSupportDirectory
        self.enableSafariRead = enableSafariRead
        self.exactBrowserEnabled = exactBrowserEnabled
    }

    /// The catalog advertised to the model for this run. Descriptions name the
    /// allowlists the policy enforces, so the model plans requests that can
    /// actually be approved instead of discovering the gate by failing.
    public func tools() -> [LLMTool] {
        var catalog: [LLMTool] = [
            LLMTool(
                name: "browser_open",
                description: exactBrowserEnabled ? "Open a user-requested HTTPS address after approval; the full address may contain sensitive values and will be shown for approval. Browser redirects and network activity may follow. Does not read page contents." : "Open a user-requested HTTPS origin after approval. Paths, query strings, fragments and credentials are rejected. The browser may redirect or send network requests afterward.",
                parameters: ["url": LLMToolParameter(type: "string", description: exactBrowserEnabled ? "HTTPS address, including path or query; no credentials or fragment." : "HTTPS origin only, without a path, query, fragment, or credentials.")]
            ),
            LLMTool(
                name: "shell",
                description: """
                Run the read-only pwd command in a restricted process. Only pwd is supported; it needs explicit user approval \
                before it executes, and the working directory must be inside an \
                approved directory (Jarvis's own application-support folder by \
                default). Output is truncated.
                """,
                parameters: [
                    "command": LLMToolParameter(type: "string", description: "The command to run; only pwd is currently supported."),
                    "workingDirectory": LLMToolParameter(
                        type: "string",
                        description: "Absolute directory to run in. Must be inside an approved directory; defaults to Jarvis's application-support folder.",
                        required: false
                    ),
                ]
            ),
            LLMTool(
                name: "fetch",
                description: """
                Fetch an HTTPS URL and return the status plus the start of the \
                body. Read-only, but the host must be on the approved site \
                allowlist or the request is denied.
                """,
                parameters: [
                    "url": LLMToolParameter(type: "string", description: "The HTTPS URL to fetch."),
                ]
            ),
            LLMTool(
                name: "screenshot",
                description: """
                Capture the main display to a PNG inside Jarvis's screenshots \
                folder. Read-only.
                """,
                parameters: [
                    "filename": LLMToolParameter(
                        type: "string",
                        description: "Basename of the PNG to write. Defaults to screenshot.png.",
                        required: false
                    ),
                ]
            ),
            LLMTool(
                name: "ax_query",
                description: """
                Read an app's accessibility tree and return a compact text \
                rendering. Read-only and never performs an action, but the app's \
                bundle identifier must be on the approved application allowlist.
                """,
                parameters: [
                    "bundleID": LLMToolParameter(type: "string", description: "Bundle identifier of a running app, for example com.apple.finder."),
                    "maxDepth": LLMToolParameter(
                        type: "string",
                        description: "How many levels of the tree to walk, as a number. Defaults to 4.",
                        required: false
                    ),
                ]
            ),
        ]
        if service.isSafariReadEnabled() {
            catalog.insert(LLMTool(name: "safari_read", description: "Capture the user's current focused Safari window and request approval to read its accessibility text. Ask the user to switch to the intended Safari page. The full captured URL is shown only for approval; content is sent to the model after approval. Dynamic pages are not atomic snapshots.", parameters: [:]), at: 0)
        }
        return catalog
    }

    /// Submits one tool call as a `ToolRequest` and translates the policy
    /// verdict back into what the loop understands.
    ///
    /// On `.allow` the service has already awaited the worker, so the tool's
    /// output is read back out of the audit timeline. Unknown tool names never
    /// reach the service: they come back as `.denied` so the model can re-plan.
    public func perform(_ call: LLMToolCall) async throws -> AgentToolOutcome {
        let request: ToolRequest
        if call.name == "safari_read" {
            guard service.isSafariReadEnabled() else { return .denied("Safari reading is unavailable") }
            request = try await service.prepareSafariRead(taskID: taskID)
        } else {
            guard let mapped = makeRequest(for: call) else { return .denied("unknown tool") }
            request = mapped
        }

        switch try await service.submit(request: request) {
        case .allow:
            return .executed(try await observation(for: request))
        case .requireApproval(let reason):
            return .awaitingApproval(requestID: request.id, payloadDigest: request.payloadDigest, description: reason)
        case .deny(let reason):
            return .denied(reason)
        }
    }

    /// Maps a model tool call onto a request the policy gate understands, or
    /// `nil` when the name is not in the advertised catalog. The targets and
    /// scopes here mirror the ones the menu-bar UI submits by hand, so both
    /// entry points hit the same allowlists.
    private func makeRequest(for call: LLMToolCall) -> ToolRequest? {
        switch call.name {
        case "browser_open":
            let url = call.arguments["url"] ?? ""
            return ToolRequest(taskID: taskID, name: "browser_open", sideEffect: .externalSend, target: url, payload: "Open in browser")
        case "shell":
            let workingDirectory = resolvedWorkingDirectory(call.arguments["workingDirectory"])
            return ToolRequest(
                taskID: taskID,
                name: "shell",
                sideEffect: .localExecute,
                target: workingDirectory,
                payload: call.arguments["command"] ?? "",
                scope: ToolScope(workingDirectory: workingDirectory)
            )
        case "fetch":
            let url = call.arguments["url"] ?? ""
            return ToolRequest(
                taskID: taskID,
                name: "fetch",
                sideEffect: .read,
                target: url,
                payload: url,
                // The read gate for a URL target requires a configured
                // profile to audit against; the fetcher itself ignores it.
                scope: ToolScope(browserProfile: "default")
            )
        case "screenshot":
            guard let filename = screenshotFilename(call.arguments["filename"]) else {
                return nil
            }
            return ToolRequest(
                taskID: taskID,
                name: "screenshot",
                sideEffect: .read,
                target: screenshotsDirectory.appendingPathComponent(filename, isDirectory: false).path,
                payload: "screen"
            )
        case "ax_query":
            let maxDepth = Int(call.arguments["maxDepth"] ?? "") ?? 4
            return ToolRequest(
                taskID: taskID,
                name: "ax_query",
                sideEffect: .read,
                target: call.arguments["bundleID"] ?? "",
                payload: "{\"maxDepth\":\(maxDepth)}"
            )
        default:
            return nil
        }
    }

    /// Reads the finished tool's output from the audit timeline. The service
    /// records exactly one "tool result" event per executed request, keyed by
    /// that request's action digest, so matching on both isolates this call
    /// from any other work on the task.
    private func observation(for request: ToolRequest) async throws -> String {
        let events = try await service.listTimelineEvents(taskID: taskID)
        let match = events.last {
            $0.actionDigest == request.payloadDigest && $0.requestID == request.id && $0.summary == Self.toolResultSummary
        }
        return match?.result ?? Self.missingObservationFallback
    }

    private var screenshotsDirectory: URL {
        appSupportDirectory.appendingPathComponent("screenshots", isDirectory: true)
    }

    /// Falls back to Jarvis's own folder when the model omits the directory,
    /// so the common case lands inside an approved directory by default.
    private func resolvedWorkingDirectory(_ argument: String?) -> String {
        let trimmed = (argument ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? appSupportDirectory.path : trimmed
    }

    /// Accepts only a bare filename, so a model-supplied path can never escape
    /// the screenshots directory. An omitted name uses a fixed default; a
    /// path-shaped name is refused rather than silently rewritten.
    private func screenshotFilename(_ argument: String?) -> String? {
        let trimmed = (argument ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "screenshot.png" }
        guard !trimmed.contains("/"), !trimmed.contains("..") else { return nil }
        return trimmed
    }
}
