import Foundation

/// An editable workout plan. It remains app-owned data until the user confirms
/// that Densoso may open or schedule an Apple Workout plan.
struct WorkoutPlanDraft: Codable, Equatable, Identifiable, Sendable {
    enum Activity: String, CaseIterable, Codable, Sendable {
        case walking
        case running
        case cycling
        case strength
        case hiit

        var displayName: String {
            switch self {
            case .walking: "步行"
            case .running: "跑步"
            case .cycling: "骑行"
            case .strength: "力量训练"
            case .hiit: "高强度间歇"
            }
        }
    }

    enum Location: String, CaseIterable, Codable, Sendable {
        case indoor
        case outdoor

        var displayName: String { self == .indoor ? "室内" : "户外" }
    }

    enum Goal: Codable, Equatable, Sendable {
        case open
        case timeMinutes(Int)

        var displayName: String {
            switch self {
            case .open: "开放训练"
            case .timeMinutes(let minutes): "\(minutes) 分钟"
            }
        }
    }

    struct StrengthSet: Codable, Equatable, Identifiable, Sendable {
        let id: UUID
        var exerciseName: String
        var setCount: Int
        var repetitions: Int
        var loadKilograms: Double?

        init(
            id: UUID = UUID(),
            exerciseName: String,
            setCount: Int,
            repetitions: Int,
            loadKilograms: Double? = nil
        ) {
            self.id = id
            self.exerciseName = exerciseName
            self.setCount = setCount
            self.repetitions = repetitions
            self.loadKilograms = loadKilograms
        }
    }

    let id: UUID
    var name: String
    var activity: Activity
    var location: Location
    var goal: Goal
    var scheduledAt: Date?
    var strengthSets: [StrengthSet]

    init(
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

    static let squatFiveByFive = WorkoutPlanDraft(
        name: "5×5 深蹲",
        activity: .strength,
        goal: .timeMinutes(45),
        strengthSets: [StrengthSet(exerciseName: "深蹲", setCount: 5, repetitions: 5)]
    )
}
