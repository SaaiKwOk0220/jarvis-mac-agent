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

public struct ToolRequest: Codable, Identifiable, Sendable {
    public let id: UUID
    public let taskID: UUID
    public let name: String
    public let sideEffect: SideEffect
    public let target: String
    public let payload: String
    public let payloadDigest: String

    public init(
        id: UUID = UUID(),
        taskID: UUID,
        name: String,
        sideEffect: SideEffect,
        target: String,
        payload: String
    ) {
        self.id = id
        self.taskID = taskID
        self.name = name
        self.sideEffect = sideEffect
        self.target = target
        self.payload = payload
        self.payloadDigest = Self.actionDigest(
            name: name,
            sideEffect: sideEffect,
            target: target,
            payload: payload
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id, taskID, name, sideEffect, target, payload, payloadDigest
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(UUID.self, forKey: .id)
        let taskID = try container.decode(UUID.self, forKey: .taskID)
        let name = try container.decode(String.self, forKey: .name)
        let sideEffect = try container.decode(SideEffect.self, forKey: .sideEffect)
        let target = try container.decode(String.self, forKey: .target)
        let payload = try container.decode(String.self, forKey: .payload)
        let storedDigest = try container.decode(String.self, forKey: .payloadDigest)
        let expectedDigest = Self.actionDigest(
            name: name,
            sideEffect: sideEffect,
            target: target,
            payload: payload
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
            payload: payload
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
        try container.encode(payloadDigest, forKey: .payloadDigest)
    }

    /// Produces a stable digest that binds an approval to this exact action.
    public static func actionDigest(
        name: String,
        sideEffect: SideEffect,
        target: String,
        payload: String
    ) -> String {
        let action = [name, sideEffect.rawValue, target, payload]
            .map { "\($0.utf8.count):\($0)" }
            .joined(separator: "|")
        return SHA256.hash(data: Data(action.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public protocol TaskServiceAPI: Sendable {
    func createTask(title: String) async throws -> Task
    func getTask(id: UUID) async throws -> Task?
    func listTasks() async throws -> [Task]
    func approve(requestID: UUID, digest: String) async throws
    func reject(requestID: UUID) async throws
    func cancel(taskID: UUID) async throws
}
