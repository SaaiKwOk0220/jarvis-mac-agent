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
        payload: String,
        payloadDigest: String? = nil
    ) {
        self.id = id
        self.taskID = taskID
        self.name = name
        self.sideEffect = sideEffect
        self.target = target
        self.payload = payload
        self.payloadDigest = payloadDigest ?? Self.actionDigest(
            name: name,
            sideEffect: sideEffect,
            target: target,
            payload: payload
        )
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
