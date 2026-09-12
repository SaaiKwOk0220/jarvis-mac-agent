import JarvisDomain

public enum TaskStateMachineError: Error, Equatable, Sendable {
    case illegalTransition(from: TaskStatus, to: TaskStatus)
}

/// Defines the only legal persisted task-state changes.
public enum TaskStateMachine {
    public static func validate(from: TaskStatus, to: TaskStatus) throws {
        guard allowedDestinations(for: from).contains(to) else {
            throw TaskStateMachineError.illegalTransition(from: from, to: to)
        }
    }

    public static func allowedDestinations(for status: TaskStatus) -> Set<TaskStatus> {
        switch status {
        case .draft:
            [.planning, .cancelled]
        case .planning:
            [.running, .blocked, .failed, .cancelled]
        case .running:
            [.awaitingApproval, .blocked, .failed, .completed, .cancelled]
        case .awaitingApproval:
            [.running, .blocked, .failed, .cancelled]
        case .blocked:
            [.planning, .failed, .cancelled]
        case .failed, .cancelled, .completed:
            []
        }
    }
}
