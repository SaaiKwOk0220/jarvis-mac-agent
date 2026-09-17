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

    public init(id: UUID, taskID: UUID, reason: String, target: String, payload: String, digest: String) {
        self.id = id; self.taskID = taskID; self.reason = reason; self.target = target; self.payload = payload; self.digest = digest
    }

    private enum CodingKeys: String, CodingKey { case id, taskID, reason, approvalReason, target, payload, digest, actionDigest }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        taskID = try c.decode(UUID.self, forKey: .taskID)
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? c.decodeIfPresent(String.self, forKey: .approvalReason) ?? "Approval requested by policy"
        target = try c.decodeIfPresent(String.self, forKey: .target) ?? ""
        payload = try c.decodeIfPresent(String.self, forKey: .payload) ?? ""
        digest = try c.decodeIfPresent(String.self, forKey: .digest) ?? c.decode(String.self, forKey: .actionDigest)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(taskID, forKey: .taskID); try c.encode(reason, forKey: .reason)
        try c.encode(target, forKey: .target); try c.encode(payload, forKey: .payload); try c.encode(digest, forKey: .digest)
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

    private var baseURL: URL
    private let session: URLSession
    /// Tracks the last-known status for every task returned by `refresh`, so
    /// `notifyTransitions` can diff and emit notifications. Exposed as
    /// `internal` so the `ServiceClientTests` can verify the prune invariant;
    /// callers outside this module should treat it as read-only via the
    /// public observable surface.
    var previousStatuses: [UUID: TaskStatus] = [:]

    public init(baseURL: URL = URL(string: "http://127.0.0.1:8080")!, session: URLSession = .shared) {
        self.baseURL = baseURL; self.session = session
        #if canImport(UserNotifications)
        // `swift run` is a bare executable, which UserNotifications cannot register. A packaged app can.
        if Self.notificationsAreAvailable {
            Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
        }
        #endif
    }

    public func configure(baseURL: URL) {
        guard baseURL.scheme?.lowercased() == "http", (baseURL.host == "127.0.0.1" || baseURL.host == "localhost") else { return }
        self.baseURL = baseURL
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
            let (data, response) = try await session.data(for: request)
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
        let (data, _) = try await request(path: "/tasks/\(taskID.uuidString)/requests", method: "GET")
        do {
            let requests = try Self.decoder.decode([ApprovalRequest].self, from: data)
            // Key by taskID so the UI can resolve the active pending request for a
            // task with `approvalRequests[task.id]`. `TaskService.submit(request:)`
            // enforces "one task, one pending request at a time", but if the
            // response ever carries multiple entries for the same taskID the
            // last one wins, which is the safe choice for the approver UI.
            for request in requests {
                approvalRequests[request.taskID] = request
            }
            serviceError = nil
            return requests
        } catch { throw ServiceClientError.decoding }
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

    public func approve(_ request: ApprovalRequest) async throws { try await approve(requestID: request.id, digest: request.digest) }

    public func reject(requestID: UUID) async throws {
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
            let (data, response) = try await session.data(for: urlRequest)
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

    private func mutate(path: String, body: [String: String]? = nil) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { request.httpBody = try JSONEncoder().encode(body) }
        do {
            let (data, response) = try await session.data(for: request)
            try Self.validate(response: response, data: data)
        } catch let error as ServiceClientError { throw error }
        catch { throw ServiceClientError.unavailable }
    }

    private func request(path: String, method: String) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))))
        request.httpMethod = method
        do {
            let (data, response) = try await session.data(for: request)
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
