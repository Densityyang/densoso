import Foundation

/// An editable workout plan. It remains app-owned data until the user confirms
/// that Densoso may open or schedule an Apple Workout plan.
public struct WorkoutPlanDraft: Codable, Equatable, Identifiable, Sendable {
    public enum Activity: String, CaseIterable, Codable, Sendable {
        case walking
        case running
        case cycling
        case swimming
        case hiking
        case strength
        case hiit

        public var displayName: String {
            switch self {
            case .walking: "步行"
            case .running: "跑步"
            case .cycling: "骑行"
            case .swimming: "游泳"
            case .hiking: "徒步"
            case .strength: "力量训练（旧计划）"
            case .hiit: "高强度间歇（旧计划）"
            }
        }

        public var isWorkoutKitSupported: Bool {
            switch self {
            case .walking, .running, .cycling, .swimming, .hiking: true
            case .strength, .hiit: false
            }
        }

        public static let supportedCases: [Activity] = [.walking, .running, .cycling, .swimming, .hiking]
    }

    public enum Location: String, CaseIterable, Codable, Sendable {
        case indoor
        case outdoor

        public var displayName: String { self == .indoor ? "室内" : "户外" }
    }

    public enum Goal: Codable, Equatable, Sendable {
        case open
        case timeMinutes(Int)
        case distanceMeters(Double)

        public var displayName: String {
            switch self {
            case .open: "开放训练"
            case .timeMinutes(let minutes): "\(minutes) 分钟"
            case .distanceMeters(let meters): String(format: "%.0f 米", meters)
            }
        }
    }

    /// Retained only so V3 pending-plan payloads can still decode and be canonically verified.
    /// Phase 8 does not expose or pass strength-set data to WorkoutKit.
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

    public static let defaultDraft = WorkoutPlanDraft(
        name: "轻松步行",
        activity: .walking,
        goal: .timeMinutes(30)
    )
}
