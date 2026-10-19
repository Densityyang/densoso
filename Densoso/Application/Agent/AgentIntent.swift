import DensosoDomain
import Foundation

struct HealthQuestion: Codable, Equatable, Sendable {
    let text: String
}

struct HistoryQuery: Codable, Equatable, Sendable {
    let startDate: Date
    let endDate: Date

    var isWellFormed: Bool { startDate <= endDate }
}

typealias MealIntent = MealDraft
typealias WeightIntent = WeightDraft
typealias WorkoutIntent = WorkoutPlanDraft
typealias CheckInIntent = DailyCheckIn
typealias TrainingPlanIntent = TrainingPlanDraft
typealias UserPreferenceIntent = UserPreference

/// Read-intent cases require explicit adapter metadata; the cloud adapter must
/// not infer them from free-form reply text or tool-call counts.
enum AgentIntent: Codable, Equatable, Sendable {
    case answerHealthQuestion(HealthQuestion)
    case recordMeal(MealIntent)
    case recordWeight(WeightIntent)
    case createWorkoutPlan(WorkoutIntent)
    case createTrainingPlan(TrainingPlanIntent)
    case dailyCheckIn(CheckInIntent)
    case queryHistory(HistoryQuery)
    case recordUserPreference(UserPreferenceIntent)
    case captureProposal(LocalRecordSuggestion)
    case answer(String)
    case unsupported
}
