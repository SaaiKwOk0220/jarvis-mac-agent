import Foundation

public enum TaskStatus: String, Codable, CaseIterable, Equatable, Sendable {
    case draft
    case planning
    case running
    case awaitingApproval = "awaiting_approval"
    case blocked
    case failed
    case cancelled
    case completed
}

public struct Task: Codable, Identifiable, Sendable {
    public let id: UUID
    public var title: String
    public var status: TaskStatus
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        title: String,
        status: TaskStatus = .draft,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
