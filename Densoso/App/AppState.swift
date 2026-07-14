import Foundation
import Observation

@MainActor
@Observable
final class AppState {
    static let shared = AppState()

    var isOnboarded = false
    var isLoading = false
    var errorMessage: String?
    var todayMetrics: DailyMetrics?
    var weeklyReport: WeeklyReport?
    var userProfile: UserProfile?

    // Agent
    var isAgentProcessing = false
    var agentStreamedText = ""

    // 语音
    var isRecording = false
    var transcribedText = ""

    private init() {}
}