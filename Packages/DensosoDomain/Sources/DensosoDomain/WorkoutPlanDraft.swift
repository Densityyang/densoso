import Foundation

/// An editable workout plan. It remains app-owned data until the user confirms
/// that Densoso may open or schedule an Apple Workout plan.
public struct WorkoutPlanDraft: Codable, Equatable, Identifiable, Sendable {
    public enum Activity: String, CaseIterable, Codable, Sendable {
        case walking
        case running
        case cycling
        case strength
        case hiit

        public var displayName: String {
            switch self {
            case .walking: "步行"
            case .running: "跑步"
            case .cycling: "骑行"
            case .strength: "力量训练"
            case .hiit: "高强度间歇"
            }
        }
    }

    public enum Location: String, CaseIterable, Codable, Sendable {
        case indoor
        case outdoor

        public var displayName: String { self == .indoor ? "室内" : "户外" }
    }

    public enum Goal: Codable, Equatable, Sendable {
        case open
        case timeMinutes(Int)

        public var displayName: String {
            switch self {
            case .open: "开放训练"
            case .timeMinutes(let minutes): "\(minutes) 分钟"
            }
        }
    }

    public struct StrengthSet: Codable, Equatable, Identifiable, Sendable {
        public let id: UUID
        public var exerciseID: String?
        public var exerciseName: String
        public var setCount: Int
        public var repetitions: Int
        public var loadKilograms: Double?

        public init(
            id: UUID = UUID(),
            exerciseID: String? = nil,
            exerciseName: String,
            setCount: Int,
            repetitions: Int,
            loadKilograms: Double? = nil
        ) {
            self.id = id
            self.exerciseID = exerciseID
            self.exerciseName = exerciseName
            self.setCount = setCount
            self.repetitions = repetitions
            self.loadKilograms = loadKilograms
        }
    }

    public let id: UUID
    public var name: String
    public var activity: Activity
    public var location: Location
    public var goal: Goal
    public var scheduledAt: Date?
    public var strengthSets: [StrengthSet]

    public init(
        id: UUID = UUID(),
        name: String,
        activity: Activity,
        location: Location = .indoor,
        goal: Goal = .open,
        scheduledAt: Date? = nil,
        strengthSets: [StrengthSet] = []
    ) {
        self.id = id
        self.name = name
        self.activity = activity
        self.location = location
        self.goal = goal
        self.scheduledAt = scheduledAt
        self.strengthSets = strengthSets
    }

    public static let squatFiveByFive = WorkoutPlanDraft(
        name: "5×5 深蹲",
        activity: .strength,
        goal: .timeMinutes(45),
        strengthSets: [StrengthSet(exerciseName: "深蹲", setCount: 5, repetitions: 5)]
    )
}
