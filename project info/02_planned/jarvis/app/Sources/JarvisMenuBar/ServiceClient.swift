import Foundation
import Combine
import JarvisDomain

#if canImport(UserNotifications)
import UserNotifications
#endif

public struct ApprovalRequest: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let taskID: UUID
    public let reason: String
    public let target: String
    public let payload: String
    public let digest: String
    public let kind: String?
    public let previewAvailable: Bool?

    public init(id: UUID, taskID: UUID, reason: String, target: String, payload: String, digest: String, kind: String? = nil, previewAvailable: Bool? = nil) {
        self.id = id; self.taskID = taskID; self.reason = reason; self.target = target; self.payload = payload; self.digest = digest; self.kind = kind; self.previewAvailable = previewAvailable
    }

    private enum CodingKeys: String, CodingKey { case id, taskID, reason, approvalReason, target, payload, digest, actionDigest, kind, previewAvailable }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        taskID = try c.decode(UUID.self, forKey: .taskID)
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? c.decodeIfPresent(String.self, forKey: .approvalReason) ?? "Approval requested by policy"
        target = try c.decodeIfPresent(String.self, forKey: .target) ?? ""
        payload = try c.decodeIfPresent(String.self, forKey: .payload) ?? ""
        digest = try c.decodeIfPresent(String.self, forKey: .digest) ?? c.decode(String.self, forKey: .actionDigest)
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
        previewAvailable = try c.decodeIfPresent(Bool.self, forKey: .previewAvailable)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(taskID, forKey: .taskID); try c.encode(reason, forKey: .reason)
        try c.encode(target, forKey: .target); try c.encode(payload, forKey: .payload); try c.encode(digest, forKey: .digest); try c.encodeIfPresent(kind, forKey: .kind); try c.encodeIfPresent(previewAvailable, forKey: .previewAvailable)
    }
}

public struct APIError: Codable, Equatable, Sendable {
    public let message: String
    public init(message: String) { self.message = message }
}

public enum ServiceClientError: Error, Equatable, LocalizedError, Sendable {
    case unavailable
    case invalidResponse
    case decoding
    case http(status: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .unavailable: return "Jarvis service is unavailable"
        case .invalidResponse: return "Jarvis service returned an invalid response"
        case .decoding: return "Jarvis service returned malformed data"
        case let .http(status, message): return "Jarvis service error (\(status)): \(message)"
        }
    }
}

@MainActor
public final class ServiceClient: ObservableObject {
    /// Process-wide reference to the active service client. The app
    /// (`JarvisMenuBarApp`) sets this once during startup so non-SwiftUI
    /// entry points — global hotkeys, App Intents — can read live task data
    /// without going through a SwiftUI environment. Weak to keep
    /// `ServiceClient`'s lifecycle tied to the SwiftUI scene graph.
    public static weak var shared: ServiceClient?

    @Published public private(set) var tasks: [JarvisTask] = []
    @Published public private(set) var selectedTask: JarvisTask?
    @Published public private(set) var approvalRequests: [UUID: ApprovalRequest] = [:]
    @Published public private(set) var timelineEvents: [UUID: [TimelineEvent]] = [:]
    /// Read-side failures (refresh / createTask / loadTimeline /
    /// loadApprovalRequests). Write-side failures populate `actionError`
    /// instead.
    @Published public private(set) var serviceError: ServiceClientError?
    /// Write-side failures (approve / reject / cancel / startDemoApproval).
    /// Cleared automatically on the next successful mutation and on the
    /// next button press in the view layer. Read-side failures populate
    /// `serviceError` instead.
    @Published public private(set) var actionError: String?

    var experimentalClickApprovalForTesting: ((ApprovalRequest) async throws -> Void)?
    var experimentalClickRefreshForTesting: ((UUID) async throws -> [ApprovalRequest])?
    var approvalClockForTesting: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    private var lastApprovalClock: TimeInterval?
    private let approvalFreshnessLifetime: TimeInterval = 2
    private struct ApprovalFreshness { let taskID: UUID; let digest: String; let generation: UInt64; let deadline: TimeInterval }
    @Published private var approvalFreshness: [UUID: ApprovalFreshness] = [:]
    private var approvalGeneration: [UUID: UInt64] = [:]
    @Published private var approvalMutationCount: [UUID: Int] = [:]
    @Published private var failedExperimentalApprovals: Set<UUID> = []
    @Published private var inFlightExperimentalApprovals: Set<UUID> = []
    var experimentalApprovalCapacityForTesting: Int = 128
    private var experimentalApprovalCapacity: Int { min(max(experimentalApprovalCapacityForTesting, 0), 128) }
    private var experimentalApprovalCapacityAvailable: Bool {
        failedExperimentalApprovals.count + inFlightExperimentalApprovals.count < experimentalApprovalCapacity
    }
    var experimentalClickCapacityReached: Bool { !experimentalApprovalCapacityAvailable }
    private var baseURL: URL
    private var authorizationToken: String?
    private let session: URLSession
    /// Tracks the last-known status for every task returned by `refresh`, so
    /// `notifyTransitions` can diff and emit notifications. Exposed as
    /// `internal` so the `ServiceClientTests` can verify the prune invariant;
    /// callers outside this module should treat it as read-only via the
    /// public observable surface.
    var previousStatuses: [UUID: TaskStatus] = [:]

    public init(baseURL: URL = URL(string: "http://127.0.0.1:8080")!, session: URLSession = .shared, authorizationToken: String? = nil) {
        self.baseURL = baseURL; self.session = session; self.authorizationToken = authorizationToken
        #if canImport(UserNotifications)
        // `swift run` is a bare executable, which UserNotifications cannot register. A packaged app can.
        if Self.notificationsAreAvailable {
            Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
        }
        #endif
        if ServiceClient.shared == nil {
            ServiceClient.shared = self
        }
    }

    public func configure(baseURL: URL, authorizationToken: String? = nil) {
        guard baseURL.scheme?.lowercased() == "http", baseURL.host == "127.0.0.1", baseURL.user == nil, baseURL.password == nil else { return }
        for taskID in Array(approvalGeneration.keys) { approvalGeneration[taskID, default: 0] &+= 1 }
        approvalRequests.removeAll()
        approvalFreshness.removeAll()
        self.baseURL = baseURL
        self.authorizationToken = authorizationToken
    }

    @discardableResult
    public func refresh() async throws -> [JarvisTask] {
        do {
            let (data, _) = try await request(path: "/tasks", method: "GET")
            let decoded = try Self.decodeTaskList(data, decoder: Self.decoder)
            let newStatuses = Dictionary(uniqueKeysWithValues: decoded.map { ($0.id, $0.status) })
            notifyTransitions(from: previousStatuses, to: newStatuses)
            // Prune entries for tasks no longer present in /tasks before merging
            // the new statuses in, so the diff stays bounded even after long
            // sessions with many task deletions.
            let currentIDs = Set(decoded.map(\.id))
            for oldID in previousStatuses.keys where !currentIDs.contains(oldID) {
                previousStatuses.removeValue(forKey: oldID)
            }
            for (id, status) in newStatuses {
                previousStatuses[id] = status
            }
            tasks = decoded
            if let id = selectedTask?.id { selectedTask = decoded.first(where: { $0.id == id }) }
            serviceError = nil
            return decoded
        } catch let error as ServiceClientError {
            serviceError = error; throw error
        } catch {
            serviceError = .unavailable; throw ServiceClientError.unavailable
        }
    }

    public func select(_ task: JarvisTask?) { selectedTask = task }

    /// Clears the last published action error (e.g. when the user retries a button).
    public func clearActionError() { actionError = nil }

    @discardableResult
    public func createTask(title: String) async throws -> JarvisTask {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { throw ServiceClientError.http(status: 400, message: "task title is required") }
        var request = URLRequest(url: baseURL.appendingPathComponent("tasks"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["title": trimmedTitle])
        do {
            let (data, response) = try await send(request)
            try Self.validate(response: response, data: data)
            let task: JarvisTask
            do { task = try Self.decoder.decode(JarvisTask.self, from: data) }
            catch { throw ServiceClientError.decoding }
            selectedTask = task
            _ = try await refresh()
            return task
        } catch let error as ServiceClientError { serviceError = error; throw error }
        catch { serviceError = .unavailable; throw ServiceClientError.unavailable }
    }

    public func loadTask(id: UUID) async throws -> JarvisTask {
        let (data, _) = try await request(path: "/tasks/\(id.uuidString)", method: "GET")
        let task: JarvisTask
        do { task = try Self.decoder.decode(JarvisTask.self, from: data) } catch { throw ServiceClientError.decoding }
        selectedTask = task
        return task
    }

    /// Loads digest-bound approval metadata when the service exposes the optional task requests route.
    public func loadApprovalRequests(taskID: UUID) async throws -> [ApprovalRequest] {
        let generation = beginApprovalRefresh(taskID: taskID)
        let (data, _) = try await request(path: "/tasks/\(taskID.uuidString)/requests", method: "GET")
        do {
            let requests = try Self.decoder.decode([ApprovalRequest].self, from: data)
            try Task.checkCancellation()
            commitApprovalRefresh(requests, taskID: taskID, generation: generation)
            serviceError = nil
            return requests
        } catch is CancellationError { throw CancellationError() }
        catch { throw ServiceClientError.decoding }
    }

    private func approvalTime() -> TimeInterval? {
        let now = approvalClockForTesting()
        guard now.isFinite, now >= 0, lastApprovalClock.map({ now >= $0 }) ?? true else { return nil }
        lastApprovalClock = now
        return now
    }
    @discardableResult func beginApprovalRefresh(taskID: UUID) -> UInt64 {
        let generation = approvalGeneration[taskID, default: 0] &+ 1
        approvalGeneration[taskID] = generation
        approvalFreshness = approvalFreshness.filter { $0.value.taskID != taskID }
        return generation
    }
    func commitApprovalRefresh(_ requests: [ApprovalRequest], taskID: UUID, generation: UInt64) {
        guard approvalGeneration[taskID] == generation else { return }
        var next = approvalRequests.filter { $0.value.taskID != taskID }
        for request in requests where request.taskID == taskID && next[request.id] == nil { next[request.id] = request }
        approvalRequests = next
        var freshness = approvalFreshness.filter { $0.value.taskID != taskID }
        if let now = approvalTime(), (now + approvalFreshnessLifetime).isFinite {
            for request in requests where request.taskID == taskID && next[request.id] == request && request.previewAvailable == true {
                freshness[request.id] = ApprovalFreshness(taskID: taskID, digest: request.digest, generation: generation, deadline: now + approvalFreshnessLifetime)
            }
        }
        approvalFreshness = freshness
    }
    func applyApprovalRequests(_ requests: [ApprovalRequest], taskID: UUID) {
        let generation = beginApprovalRefresh(taskID: taskID)
        commitApprovalRefresh(requests, taskID: taskID, generation: generation)
    }
    func beginApprovalMutation(taskID: UUID) {
        approvalMutationCount[taskID, default: 0] += 1
        beginApprovalRefresh(taskID: taskID)
    }
    func endApprovalMutation(taskID: UUID) {
        let count = approvalMutationCount[taskID, default: 0]
        if count <= 1 { approvalMutationCount.removeValue(forKey: taskID) } else { approvalMutationCount[taskID] = count - 1 }
        beginApprovalRefresh(taskID: taskID)
    }
    func isApprovalFresh(_ request: ApprovalRequest) -> Bool {
        guard let now = approvalTime(), experimentalApprovalCapacityAvailable,
              !failedExperimentalApprovals.contains(request.id), !inFlightExperimentalApprovals.contains(request.id), approvalMutationCount[request.taskID, default: 0] == 0, let freshness = approvalFreshness[request.id], freshness.taskID == request.taskID,
              freshness.digest == request.digest, now < freshness.deadline, approvalGeneration[request.taskID] == freshness.generation,
              approvalRequests[request.id] == request, request.previewAvailable == true else { return false }
        return true
    }

    public func loadTimeline(taskID: UUID) async throws -> [TimelineEvent] {
        let (data, _) = try await request(path: "/tasks/\(taskID.uuidString)/timeline", method: "GET")
        do {
            let events = try Self.decoder.decode([TimelineEvent].self, from: data)
            timelineEvents[taskID] = events
            serviceError = nil
            return events
        } catch { throw ServiceClientError.decoding }
    }

    public func approve(requestID: UUID, digest: String) async throws {
        do {
            try await mutate(path: "/requests/\(requestID.uuidString)/approve", body: ["digest": digest])
            try await refresh()
            actionError = nil
        } catch let error as ServiceClientError {
            actionError = error.localizedDescription
            throw error
        } catch {
            actionError = ServiceClientError.unavailable.localizedDescription
            throw ServiceClientError.unavailable
        }
    }

    var experimentalClickApprovalAvailable: Bool {
        if experimentalClickApprovalForTesting != nil { return true }
        #if JARVIS_SAFARI_CLICK_EXPERIMENT && (JARVIS_SAFARI_EXPERIMENT_BUILD || JARVIS_COMBINED_EXPERIMENT)
        guard AppStorageNamespace.isTrueBoolean(Bundle.main.object(forInfoDictionaryKey: "JarvisSafariClickExperiment")) else { return false }
        #if JARVIS_COMBINED_EXPERIMENT
        return CombinedExperimentAccess.current
        #else
        return Bundle.main.bundleIdentifier == "local.jarvis.safari-click-experiment" &&
            AppStorageNamespace.isTrueBoolean(Bundle.main.object(forInfoDictionaryKey: "JarvisSafariExperiment"))
        #endif
        #else
        return false
        #endif
    }
    #if JARVIS_SAFARI_CLICK_EXPERIMENT && (JARVIS_SAFARI_EXPERIMENT_BUILD || JARVIS_COMBINED_EXPERIMENT)
    func submitExperimentalSafariClick(taskID: UUID, role: String, title: String) async throws -> ToolRequest {
        guard experimentalClickApprovalAvailable else { throw ServiceClientError.unavailable }
        var request = URLRequest(url: baseURL.appendingPathComponent("tasks/\(taskID.uuidString)/safari-click"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["role": role, "title": title])
        do {
            let (data, response) = try await send(request)
            try Self.validate(response: response, data: data)
            let result = try Self.decoder.decode(ToolRequest.self, from: data)
            _ = try? await refresh()
            _ = try? await loadApprovalRequests(taskID: taskID)
            return result
        } catch let error as ServiceClientError { actionError = error.localizedDescription; throw error }
        catch { actionError = ServiceClientError.unavailable.localizedDescription; throw ServiceClientError.unavailable }
    }
    #endif

    public func approve(_ request: ApprovalRequest) async throws {
        if request.kind == "safari_click_experiment" {
            let unknownMessage = "操作结果可能未知，请先检查页面，切勿自动重试。"
            if failedExperimentalApprovals.contains(request.id) { actionError = unknownMessage; throw ServiceClientError.unavailable }
            if !experimentalApprovalCapacityAvailable { actionError = "未知结果记录已达上限，请先核实此前操作；当前会话暂停新的实验审批。"; throw ServiceClientError.unavailable }
            var handlerInvoked = false
            do {
                guard isApprovalFresh(request), !request.digest.isEmpty, experimentalClickApprovalAvailable else { throw ServiceClientError.unavailable }
                if let refresh = experimentalClickRefreshForTesting {
                    let generation = beginApprovalRefresh(taskID: request.taskID)
                    let requests = try await refresh(request.taskID)
                    try Task.checkCancellation()
                    commitApprovalRefresh(requests, taskID: request.taskID, generation: generation)
                } else { _ = try await loadApprovalRequests(taskID: request.taskID) }
                try Task.checkCancellation()
                guard isApprovalFresh(request), experimentalApprovalCapacityAvailable else { throw ServiceClientError.unavailable }
                inFlightExperimentalApprovals.insert(request.id)
                defer { inFlightExperimentalApprovals.remove(request.id) }
                beginApprovalMutation(taskID: request.taskID)
                defer { endApprovalMutation(taskID: request.taskID) }
                try Task.checkCancellation()
                handlerInvoked = true
                if let handler = experimentalClickApprovalForTesting {
                    try await handler(request)
                } else {
                    #if JARVIS_SAFARI_CLICK_EXPERIMENT && (JARVIS_SAFARI_EXPERIMENT_BUILD || JARVIS_COMBINED_EXPERIMENT)
                    try await mutate(path: "/requests/\(request.id.uuidString)/safari-click-approve", body: ["digest": request.digest])
                    _ = try await loadApprovalRequests(taskID: request.taskID)
                    #else
                    throw ServiceClientError.unavailable
                    #endif
                }
                try Task.checkCancellation()
                actionError = nil
                return
            } catch is CancellationError {
                beginApprovalRefresh(taskID: request.taskID)
                if handlerInvoked { failedExperimentalApprovals.insert(request.id); actionError = unknownMessage }
                throw CancellationError()
            } catch let error as ServiceClientError {
                if handlerInvoked { failedExperimentalApprovals.insert(request.id) }
                if case let .http(_, message) = error,
                   message == "已有点击正在进行或结果未确认，请等待或核对页面和实验记录；当前版本没有解除入口。" {
                    actionError = message
                } else { actionError = handlerInvoked ? unknownMessage : error.localizedDescription }
                throw error
            } catch {
                if handlerInvoked { failedExperimentalApprovals.insert(request.id) }
                actionError = handlerInvoked ? unknownMessage : ServiceClientError.unavailable.localizedDescription
                throw ServiceClientError.unavailable
            }
        }
        try await approve(requestID: request.id, digest: request.digest)
    }

    public func reject(requestID: UUID) async throws {
        let taskID = approvalRequests[requestID]?.taskID
        if let taskID { beginApprovalMutation(taskID: taskID) }
        defer { if let taskID { endApprovalMutation(taskID: taskID) } }
        do {
            try await mutate(path: "/requests/\(requestID.uuidString)/reject")
            try await refresh()
            actionError = nil
        } catch let error as ServiceClientError {
            actionError = error.localizedDescription
            throw error
        } catch {
            actionError = ServiceClientError.unavailable.localizedDescription
            throw ServiceClientError.unavailable
        }
    }

    public func reject(_ request: ApprovalRequest) async throws { try await reject(requestID: request.id) }

    public func cancel(taskID: UUID) async throws {
        beginApprovalMutation(taskID: taskID)
        defer { endApprovalMutation(taskID: taskID) }
        do {
            try await mutate(path: "/tasks/\(taskID.uuidString)/cancel")
            try await refresh()
            actionError = nil
        } catch let error as ServiceClientError {
            actionError = error.localizedDescription
            throw error
        } catch {
            actionError = ServiceClientError.unavailable.localizedDescription
            throw ServiceClientError.unavailable
        }
    }

    /// Marks a multi-request task as `.completed`. A successful executor run
    /// leaves the task in `.running` (not `.completed`) so additional tool
    /// requests can be submitted on the same task; the caller must invoke
    /// `completeTask` to record the workflow as done. A 409 response (already
    /// terminal) is surfaced through `actionError` like the other mutations.
    public func completeTask(taskID: UUID) async throws {
        do {
            try await mutate(path: "/tasks/\(taskID.uuidString)/complete")
            try await refresh()
            actionError = nil
        } catch let error as ServiceClientError {
            actionError = error.localizedDescription
            throw error
        } catch {
            actionError = ServiceClientError.unavailable.localizedDescription
            throw ServiceClientError.unavailable
        }
    }

    public func startDemoApproval(taskID: UUID) async throws {
        do {
            try await mutate(path: "/tasks/\(taskID.uuidString)/demo-approval")
            _ = try await refresh()
            _ = try await loadTimeline(taskID: taskID)
            _ = try await loadApprovalRequests(taskID: taskID)
            actionError = nil
        } catch let error as ServiceClientError {
            actionError = error.localizedDescription
            throw error
        } catch {
            actionError = ServiceClientError.unavailable.localizedDescription
            throw ServiceClientError.unavailable
        }
    }

    /// Submits a shell command tool request for an existing task. The
    /// LoopbackServer forces `taskID` from the URL so the request cannot
    /// target a different task than the menu-bar UI requested. A successful
    /// call lands the task in `.awaitingApproval`; the user must approve via
    /// the task-detail window for the command to actually execute.
    public func submitShellCommand(
        taskID: UUID,
        command: String,
        workingDirectory: String
    ) async throws {
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCommand.isEmpty else {
            throw ServiceClientError.http(status: 400, message: "command is required")
        }
        let scope = ToolScope(workingDirectory: workingDirectory)
        let request = ToolRequest(
            taskID: taskID,
            name: "shell",
            sideEffect: .localExecute,
            target: workingDirectory,
            payload: trimmedCommand,
            scope: scope
        )
        do {
            var urlRequest = URLRequest(url: baseURL.appendingPathComponent("tasks/\(taskID.uuidString)/requests"))
            urlRequest.httpMethod = "POST"
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.httpBody = try JSONEncoder().encode(request)
            let (data, response) = try await send(urlRequest)
            try Self.validate(response: response, data: data)
            // After submitting, refresh tasks + approval metadata so the
            // task-detail window opened by the caller sees the new request.
            _ = try await refresh()
            _ = try await loadApprovalRequests(taskID: taskID)
            actionError = nil
        } catch let error as ServiceClientError {
            actionError = error.localizedDescription
            throw error
        } catch {
            actionError = ServiceClientError.unavailable.localizedDescription
            throw ServiceClientError.unavailable
        }
    }

    /// Submits a fetch URL tool request for an existing task. The host must
    /// already be present in the policy allowlist (`PolicyConfig.sites`); the
    /// request is otherwise denied at the policy layer. A successful call
    /// records the request as `.executing` immediately — `.read` requests do
    /// not need an approval step — so the user can simply watch the task
    /// transition to `.completed` in the task-detail window.
    ///
    /// The request always carries `scope.browserProfile = "default"` because
    /// the read-side policy gate requires a configured browser profile for any
    /// URL target; the underlying URLSession fetcher does not actually use
    /// the profile, but the policy treats it as a mandatory audit attribute.
    public func submitFetchURL(
        taskID: UUID,
        urlString: String
    ) async throws {
        let trimmedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else {
            throw ServiceClientError.http(status: 400, message: "url is required")
        }
        let request = ToolRequest(
            taskID: taskID,
            name: "fetch",
            sideEffect: .read,
            target: trimmedURL,
            payload: trimmedURL,
            scope: ToolScope(browserProfile: "default")
        )
        do {
            var urlRequest = URLRequest(url: baseURL.appendingPathComponent("tasks/\(taskID.uuidString)/requests"))
            urlRequest.httpMethod = "POST"
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.httpBody = try JSONEncoder().encode(request)
            let (data, response) = try await send(urlRequest)
            try Self.validate(response: response, data: data)
            _ = try await refresh()
            _ = try await loadApprovalRequests(taskID: taskID)
            actionError = nil
        } catch let error as ServiceClientError {
            actionError = error.localizedDescription
            throw error
        } catch {
            actionError = ServiceClientError.unavailable.localizedDescription
            throw ServiceClientError.unavailable
        }
    }

    /// Submits a screenshot tool request for an existing task. The target
    /// resolves to `<appSupport>/Jarvis/screenshots/<outputFilename>`, which
    /// is also the directory Runtime passes to `PolicyConfig.approvedDirectories`
    /// (the executor takes care of creating the directory on first write).
    ///
    /// The `outputFilename` is validated to be a basename only — slashes
    /// and `..` segments are rejected so a hostile paste can never escape
    /// the screenshots directory. Like `submitFetchURL`, the request is a
    /// `.read` action and does not require an approval step; the
    /// task-detail window will show the capture progressing straight
    /// through to `.completed`.
    public func submitScreenshot(
        taskID: UUID,
        outputFilename: String
    ) async throws {
        let trimmed = outputFilename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ServiceClientError.http(status: 400, message: "filename is required")
        }
        guard !trimmed.contains("/"), !trimmed.contains("..") else {
            throw ServiceClientError.http(status: 400, message: "filename must be a basename")
        }
        let target = Self.screenshotsApprovedDirectory
            .appendingPathComponent(trimmed, isDirectory: false)
            .path
        let request = ToolRequest(
            taskID: taskID,
            name: "screenshot",
            sideEffect: .read,
            target: target,
            payload: "screen"
        )
        do {
            var urlRequest = URLRequest(url: baseURL.appendingPathComponent("tasks/\(taskID.uuidString)/requests"))
            urlRequest.httpMethod = "POST"
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.httpBody = try JSONEncoder().encode(request)
            let (data, response) = try await send(urlRequest)
            try Self.validate(response: response, data: data)
            _ = try await refresh()
            _ = try await loadApprovalRequests(taskID: taskID)
            actionError = nil
        } catch let error as ServiceClientError {
            actionError = error.localizedDescription
            throw error
        } catch {
            actionError = ServiceClientError.unavailable.localizedDescription
            throw ServiceClientError.unavailable
        }
    }

    /// Submits an accessibility-query tool request for an existing task. The
    /// target is an application bundle identifier (`com.*`) and is checked
    /// before the request leaves the UI: bundle identifiers are the only shape
    /// the read-side policy gate can match against
    /// `PolicyConfig.applicationBundleIDs`, so a bare process id or a display
    /// name would be denied as "not allowlisted" with a confusing reason.
    ///
    /// `maxDepth` bounds how many levels of the accessibility tree the
    /// executor walks. Like `submitFetchURL`, the request is a `.read` action
    /// and does not require an approval step; the task-detail window will show
    /// the inspection progressing straight through to `.completed`.
    ///
    /// The request carries no `scope`: the read-side policy gate for a bundle
    /// ID target consults `PolicyConfig.applicationBundleIDs` only, and an
    /// all-nil `ToolScope` would not survive persistence — the repository
    /// normalizes it back to `nil`, which changes the recomputed digest and
    /// makes the stored request unreadable.
    public func submitAccessibilityQuery(
        taskID: UUID,
        target: String,
        maxDepth: Int
    ) async throws {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ServiceClientError.http(status: 400, message: "target is required")
        }
        guard trimmed.hasPrefix("com.") else {
            throw ServiceClientError.http(status: 400, message: "target must be an application bundle identifier (com.*)")
        }
        let payload = "{\"maxDepth\":\(maxDepth)}"
        let request = ToolRequest(
            taskID: taskID,
            name: "ax_query",
            sideEffect: .read,
            target: trimmed,
            payload: payload
        )
        do {
            var urlRequest = URLRequest(url: baseURL.appendingPathComponent("tasks/\(taskID.uuidString)/requests"))
            urlRequest.httpMethod = "POST"
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.httpBody = try JSONEncoder().encode(request)
            let (data, response) = try await send(urlRequest)
            try Self.validate(response: response, data: data)
            _ = try await refresh()
            _ = try await loadApprovalRequests(taskID: taskID)
            actionError = nil
        } catch let error as ServiceClientError {
            actionError = error.localizedDescription
            throw error
        } catch {
            actionError = ServiceClientError.unavailable.localizedDescription
            throw ServiceClientError.unavailable
        }
    }

    /// Resolves the directory under which `submitScreenshot` writes its
    /// captures. Mirrors the path Runtime uses for the same data
    /// (`<appSupport>/Jarvis/screenshots/`); both the production submit
    /// path and the service-side policy read from this single source of
    /// truth so the policy gate accepts the request. Exposed as a static
    /// helper so tests can seed `PolicyConfig.approvedDirectories` with the
    /// matching path without duplicating the resolution logic.
    public static var screenshotsApprovedDirectory: URL {
        let appSupport = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return appSupport.appendingPathComponent(AppStorageScope.currentDirectory, isDirectory: true).appendingPathComponent("screenshots", isDirectory: true)
    }

    private func mutate(path: String, body: [String: String]? = nil) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { request.httpBody = try JSONEncoder().encode(body) }
        do {
            let (data, response) = try await send(request)
            try Self.validate(response: response, data: data)
        } catch let error as ServiceClientError { throw error }
        catch { throw ServiceClientError.unavailable }
    }

    private func send(_ original: URLRequest) async throws -> (Data, URLResponse) {
        var request = original
        if let authorizationToken {
            guard let url = request.url, url.scheme?.lowercased() == "http", url.host == "127.0.0.1", url.user == nil, url.password == nil else { throw ServiceClientError.unavailable }
            request.setValue("Bearer \(authorizationToken)", forHTTPHeaderField: "Authorization")
        }
        return try await session.data(for: request, delegate: LoopbackNoRedirectDelegate.shared)
    }

    private func request(path: String, method: String) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))))
        request.httpMethod = method
        do {
            let (data, response) = try await send(request)
            try Self.validate(response: response, data: data)
            guard let http = response as? HTTPURLResponse else { throw ServiceClientError.invalidResponse }
            return (data, http)
        } catch let error as ServiceClientError { throw error }
        catch { throw ServiceClientError.unavailable }
    }

    private func notifyTransitions(from old: [UUID: TaskStatus], to new: [UUID: TaskStatus]) {
        #if canImport(UserNotifications)
        guard Self.notificationsAreAvailable else { return }
        for (id, status) in new {
            guard old[id] != status, [.awaitingApproval, .blocked, .failed, .completed].contains(status) else { continue }
            let content = UNMutableNotificationContent()
            content.title = "Jarvis task update"
            content.body = "Task \(id.uuidString.prefix(8)) is \(status.rawValue.replacingOccurrences(of: "_", with: " "))."
            content.userInfo = ["taskID": id.uuidString, "status": status.rawValue]
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "jarvis-\(id.uuidString)-\(status.rawValue)", content: content, trigger: nil))
        }
        #endif
    }

    private static let decoder = JSONDecoder()

    private static var notificationsAreAvailable: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    private static func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw ServiceClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? decoder.decode(APIError.self, from: data).message) ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw ServiceClientError.http(status: http.statusCode, message: message)
        }
    }

    public static func decodeTaskList(_ data: Data, decoder: JSONDecoder = JSONDecoder()) throws -> [JarvisTask] {
        do { return try decoder.decode([JarvisTask].self, from: data) } catch { throw ServiceClientError.decoding }
    }

    public static func decodeApprovalRequest(_ data: Data, decoder: JSONDecoder = JSONDecoder()) throws -> ApprovalRequest {
        do { return try decoder.decode(ApprovalRequest.self, from: data) } catch { throw ServiceClientError.decoding }
    }

    public static func decodeAPIError(_ data: Data, decoder: JSONDecoder = JSONDecoder()) throws -> APIError {
        do { return try decoder.decode(APIError.self, from: data) } catch { throw ServiceClientError.decoding }
    }
}

/// Do not forward the in-memory bearer token through HTTP redirects.
final class LoopbackNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = LoopbackNoRedirectDelegate()
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
