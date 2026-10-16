import Foundation

/// A short, app-owned multi-day training plan. It is only actionable after the
/// user confirms it; each scheduled session is then compiled by WorkoutKit.
public struct TrainingPlanDraft: Codable, Equatable, Identifiable, Sendable {
    public static let maximumSessionCount = 14

    public let id: UUID
    public var name: String
    public let createdAt: Date
    public var sessions: [TrainingSessionDraft]

    public init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = Date(),
        sessions: [TrainingSessionDraft]
    ) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.createdAt = createdAt
        self.sessions = sessions
    }

    public var validationError: TrainingPlanDraftValidationError? {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.count <= 100 else {
            return .invalidName
        }
        guard createdAt.timeIntervalSince1970.isFinite else { return .invalidDate }
        guard !sessions.isEmpty, sessions.count <= Self.maximumSessionCount else {
            return .invalidSessionCount
        }
        guard Set(sessions.map(\.id)).count == sessions.count else {
            return .duplicateSessionIdentity
        }
        for session in sessions {
            if let error = session.validationError { return error }
        }
        return nil
    }
}

public struct TrainingSessionDraft: Codable, Equatable, Identifiable, Sendable {
    public enum Intensity: String, CaseIterable, Codable, Sendable {
        case recovery
        case easy
        case moderate
        case vigorous

        public var displayName: String {
            switch self {
            case .recovery: "恢复"
            case .easy: "轻松"
            case .moderate: "中等"
            case .vigorous: "较高"
            }
        }
    }

    public let id: UUID
    public var date: Date
    /// A missing activity represents a planned rest day.
    public var activity: WorkoutPlanDraft.Activity?
    public var goal: WorkoutPlanDraft.Goal?
    public var location: WorkoutPlanDraft.Location?
    public var recommendedIntensity: Intensity?
    public var reason: String

    public init(
        id: UUID = UUID(),
        date: Date,
        activity: WorkoutPlanDraft.Activity?,
        goal: WorkoutPlanDraft.Goal? = nil,
        location: WorkoutPlanDraft.Location? = nil,
        recommendedIntensity: Intensity? = nil,
        reason: String
    ) {
        self.id = id
        self.date = date
        self.activity = activity
        self.goal = goal
        self.location = location
        self.recommendedIntensity = recommendedIntensity
        self.reason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isRestDay: Bool { activity == nil }

    public var validationError: TrainingPlanDraftValidationError? {
        guard date.timeIntervalSince1970.isFinite else { return .invalidDate }
        guard !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              reason.count <= 240 else {
            return .invalidReason
        }

        guard let activity else {
            return goal == nil && location == nil && recommendedIntensity == nil
                ? nil
                : .invalidRestSession
        }
        guard activity.isWorkoutKitSupported,
              goal != nil,
              location != nil,
              recommendedIntensity != nil else {
            return .invalidWorkoutSession
        }
        switch goal {
        case .some(.open):
            return .invalidWorkoutSession
        case .some(.timeMinutes(let minutes)):
            return (1...720).contains(minutes) ? nil : .invalidGoal
        case .some(.distanceMeters(let meters)):
            return meters.isFinite && (100...100_000).contains(meters) ? nil : .invalidGoal
        case .none:
            return .invalidWorkoutSession
        }
    }
}

public enum TrainingPlanDraftValidationError: Error, Equatable, Sendable {
    case invalidName
    case invalidDate
    case invalidSessionCount
    case duplicateSessionIdentity
    case invalidReason
    case invalidRestSession
    case invalidWorkoutSession
    case invalidGoal
}
