import Foundation

/// The lifecycle shared by the Watch workout UI and the iPhone mirroring path.
/// Persistence and HealthKit calls deliberately live outside this state machine.
public enum WorkoutSessionState: String, Codable, Sendable, Equatable {
    case idle
    case prepared
    case running
    case paused
    case ended
    case discarded
}

public enum WorkoutSessionEvent: String, Codable, Sendable, Equatable {
    case prepare
    case start
    case pause
    case resume
    case end
    case discard
}

public enum WorkoutSessionTransitionError: Error, Sendable, Equatable {
    case invalidTransition(state: WorkoutSessionState, event: WorkoutSessionEvent)
}

/// Stable identifier that survives watch-to-phone reconnects.
/// A HealthKit UUID is attached later, once a workout has been saved by HealthKit.
public struct LogicalWorkoutSession: Codable, Sendable, Equatable, Hashable {
    public let id: UUID
    public let startedAt: Date

    public init(id: UUID = UUID(), startedAt: Date = Date()) {
        self.id = id
        self.startedAt = startedAt
    }
}

public struct WorkoutSessionSnapshot: Sendable, Equatable {
    public let logicalSession: LogicalWorkoutSession
    public let state: WorkoutSessionState

    public init(logicalSession: LogicalWorkoutSession, state: WorkoutSessionState) {
        self.logicalSession = logicalSession
        self.state = state
    }
}

/// Serializes watch workout lifecycle events and rejects invalid transitions.
/// Callers can replay a snapshot after reconnecting without creating a new ID.
public actor WatchWorkoutCoordinator {
    private var logicalSession: LogicalWorkoutSession
    private var sessionState: WorkoutSessionState

    public init(logicalSession: LogicalWorkoutSession = LogicalWorkoutSession()) {
        self.logicalSession = logicalSession
        self.sessionState = .idle
    }

    public func snapshot() -> WorkoutSessionSnapshot {
        WorkoutSessionSnapshot(logicalSession: logicalSession, state: sessionState)
    }

    @discardableResult
    public func send(_ event: WorkoutSessionEvent) throws -> WorkoutSessionSnapshot {
        guard let nextState = Self.nextState(after: event, from: sessionState) else {
            throw WorkoutSessionTransitionError.invalidTransition(state: sessionState, event: event)
        }
        if event == .prepare, (sessionState == .ended || sessionState == .discarded) {
            logicalSession = LogicalWorkoutSession()
        }
        sessionState = nextState
        return snapshot()
    }

    public static func nextState(after event: WorkoutSessionEvent, from state: WorkoutSessionState) -> WorkoutSessionState? {
        switch (state, event) {
        case (.idle, .prepare), (.discarded, .prepare), (.ended, .prepare):
            .prepared
        case (.prepared, .start):
            .running
        case (.running, .pause):
            .paused
        case (.paused, .resume):
            .running
        case (.running, .end), (.paused, .end):
            .ended
        case (.prepared, .discard), (.running, .discard), (.paused, .discard):
            .discarded
        default:
            nil
        }
    }
}
