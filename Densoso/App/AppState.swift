import Foundation
import Observation
import DensosoDomain

@MainActor
@Observable
final class AppState {
    static let shared = AppState()

    var isOnboarded = false
    var isLoading = false
    var errorMessage: String?
    var startupWarning: String?
    var todayMetrics: DailyMetrics?
    var weeklyReport: WeeklyReport?
    var userProfile: UserProfile?

    // Agent
    var isAgentProcessing = false
    var agentStreamedText = ""
    var pendingWorkoutPlan: WorkoutPlanDraft?
    var pendingMealText: String?

    // 语音
    var isRecording = false
    var transcribedText = ""

    private init() {}
}
