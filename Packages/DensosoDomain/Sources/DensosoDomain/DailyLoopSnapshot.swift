import Foundation

/// Time-of-day phase selected by the application for the current local day.
public enum DailyLoopPhase: String, Codable, CaseIterable, Sendable {
    case morning
    case daytime
    case evening
}

/// Semantic shortcuts that a client may offer from the daily loop.
public enum DailyLoopQuickAction: String, Codable, CaseIterable, Sendable {
    case logMeal
    case logWeight
    case planWorkout
    case dailyCheckIn
}

/// A short presentation summary paired with the existing computed health state.
/// This type stores supplied values only; health calculations remain in their service.
public struct DailyStateSummary: Codable, Equatable, Sendable {
    public let headline: String
    public let detail: String?
    public let healthState: HealthStateV2?

    public init(headline: String, detail: String? = nil, healthState: HealthStateV2? = nil) {
        self.headline = headline
        self.detail = detail
        self.healthState = healthState
    }
}

/// Current-day view contract composed from already available domain summaries.
/// `dayStart` is the caller's local-calendar day anchor; this value does not infer dates,
/// phases, guidance, or health state.
public struct DailyLoopSnapshot: Codable, Equatable, Sendable {
    public let dayStart: Date
    public let generatedAt: Date
    public let phase: DailyLoopPhase
    public let todayState: DailyStateSummary?
    public let todaySummary: String?
    public let tomorrowGuidance: NextDayGuidance?
    public let pendingActions: [WatchPendingActionSummary]
    public let workoutPlans: [WatchWorkoutPlanSummary]
    public let quickActions: [DailyLoopQuickAction]

    public init(
        dayStart: Date,
        generatedAt: Date = Date(),
        phase: DailyLoopPhase,
        todayState: DailyStateSummary? = nil,
        todaySummary: String? = nil,
        tomorrowGuidance: NextDayGuidance? = nil,
        pendingActions: [WatchPendingActionSummary] = [],
        workoutPlans: [WatchWorkoutPlanSummary] = [],
        quickActions: [DailyLoopQuickAction] = []
    ) {
        self.dayStart = dayStart
        self.generatedAt = generatedAt
        self.phase = phase
        self.todayState = todayState
        self.todaySummary = todaySummary
        self.tomorrowGuidance = tomorrowGuidance
        self.pendingActions = pendingActions
        self.workoutPlans = workoutPlans
        self.quickActions = quickActions
    }
}
