import CryptoKit
import Foundation

public enum SideEffect: String, Codable, CaseIterable, Equatable, Sendable {
    case read
    case localExecute = "local-execute"
    case localWrite = "local-write"
    case externalSend = "external-send"
    case upload
    case delete
    case credential
    case money
}

/// Structured execution context that is part of a request's approved scope.
public struct ToolScope: Codable, Equatable, Sendable {
    public let browserProfile: String?
    public let workingDirectory: String?

    public init(browserProfile: String? = nil, workingDirectory: String? = nil) {
        self.browserProfile = browserProfile
        self.workingDirectory = workingDirectory
    }

    fileprivate var digestComponent: String {
        [browserProfile ?? "", workingDirectory ?? ""]
            .map { "\($0.utf8.count):\($0)" }
            .joined(separator: "|")
    }
}

public struct ToolRequest: Codable, Identifiable, Sendable {
    public let id: UUID
    public let taskID: UUID
    public let name: String
    public let sideEffect: SideEffect
    public let target: String
    public let payload: String
    public let scope: ToolScope?
    public let payloadDigest: String

    public init(
        id: UUID = UUID(),
        taskID: UUID,
        name: String,
        sideEffect: SideEffect,
        target: String,
        payload: String,
        scope: ToolScope? = nil
    ) {
        self.id = id
        self.taskID = taskID
        self.name = name
        self.sideEffect = sideEffect
        self.target = target
        self.payload = payload
        self.scope = scope
        self.payloadDigest = Self.actionDigest(
            name: name,
            sideEffect: sideEffect,
            target: target,
            payload: payload,
            scope: scope
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id, taskID, name, sideEffect, target, payload, scope, payloadDigest
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(UUID.self, forKey: .id)
        let taskID = try container.decode(UUID.self, forKey: .taskID)
        let name = try container.decode(String.self, forKey: .name)
        let sideEffect = try container.decode(SideEffect.self, forKey: .sideEffect)
        let target = try container.decode(String.self, forKey: .target)
        let payload = try container.decode(String.self, forKey: .payload)
        let scope = try container.decodeIfPresent(ToolScope.self, forKey: .scope)
        let storedDigest = try container.decode(String.self, forKey: .payloadDigest)
        let expectedDigest = Self.actionDigest(
            name: name,
            sideEffect: sideEffect,
            target: target,
            payload: payload,
            scope: scope
        )

        guard storedDigest == expectedDigest else {
            throw DecodingError.dataCorruptedError(
                forKey: .payloadDigest,
                in: container,
                debugDescription: "Tool request digest does not match its action."
            )
        }

        self.init(
            id: id,
            taskID: taskID,
            name: name,
            sideEffect: sideEffect,
            target: target,
            payload: payload,
            scope: scope
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(taskID, forKey: .taskID)
        try container.encode(name, forKey: .name)
        try container.encode(sideEffect, forKey: .sideEffect)
        try container.encode(target, forKey: .target)
        try container.encode(payload, forKey: .payload)
        try container.encodeIfPresent(scope, forKey: .scope)
        try container.encode(payloadDigest, forKey: .payloadDigest)
    }

    /// Produces a stable digest that binds an approval to this exact action.
    public static func actionDigest(
        name: String,
        sideEffect: SideEffect,
        target: String,
        payload: String,
        scope: ToolScope? = nil
    ) -> String {
        var action = [name, sideEffect.rawValue, target, payload]
        if let scope {
            action.append(scope.digestComponent)
        }
        let encodedAction = action.map { "\($0.utf8.count):\($0)" }
            .joined(separator: "|")
        return SHA256.hash(data: Data(encodedAction.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public protocol TaskServiceAPI: Sendable {
    func createTask(title: String) async throws -> JarvisTask
    func getTask(id: UUID) async throws -> JarvisTask?
    func listTasks() async throws -> [JarvisTask]
    func approve(requestID: UUID, digest: String) async throws
    func reject(requestID: UUID) async throws
    func cancel(taskID: UUID) async throws
    func listPendingApprovalRequests(taskID: UUID) async throws -> [PendingApprovalRequest]
    func listTimelineEvents(taskID: UUID) async throws -> [TimelineEvent]
}

/// Digest-bound metadata exposed to the local approval UI. Payload is already redacted.
public struct PendingApprovalRequest: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let taskID: UUID
    public let reason: String
    public let target: String
    public let payload: String
    public let digest: String

    public init(id: UUID, taskID: UUID, reason: String, target: String, payload: String, digest: String) {
        self.id = id; self.taskID = taskID; self.reason = reason; self.target = target; self.payload = payload; self.digest = digest
    }
}

/// Redacted, user-visible record of a task transition or tool decision.
public struct TimelineEvent: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    public let worker: String
    public let target: String
    public let sideEffect: SideEffect
    public let actionDigest: String
    public let summary: String
    public let result: String
    public let approvalID: UUID?

    public init(id: UUID, timestamp: Date, worker: String, target: String, sideEffect: SideEffect,
                actionDigest: String, summary: String, result: String, approvalID: UUID?) {
        self.id = id; self.timestamp = timestamp; self.worker = worker; self.target = target
        self.sideEffect = sideEffect; self.actionDigest = actionDigest; self.summary = summary
        self.result = result; self.approvalID = approvalID
    }
}
