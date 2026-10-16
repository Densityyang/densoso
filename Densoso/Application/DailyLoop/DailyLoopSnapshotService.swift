import DensosoDomain
import Foundation

struct DailyLoopSnapshotComposer {
    private let calendar: Calendar
    private let maximumPendingActions = 10
    private let maximumWorkoutPlans = 10

    init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    func compose(
        asOf date: Date,
        dailyBrief: DailyHealthBrief?,
        pendingActions: [PendingAction],
        workoutPlans: [ConfirmedWorkoutPlanEntry],
        trainingPlans: [ConfirmedTrainingPlanEntry] = []
    ) -> DailyLoopSnapshot {
        let dayStart = calendar.startOfDay(for: date)
        let currentBrief = dailyBrief.flatMap {
            calendar.isDate($0.dayStart, inSameDayAs: dayStart) ? $0 : nil
        }
        let healthState = currentBrief?.healthState
        let todayState = healthState.map { state in
            DailyStateSummary(
                headline: Self.headline(for: state),
                healthState: state
            )
        }
        let pendingSummaries = pendingActions
            .filter { $0.state == .pending && $0.expiresAt > date }
            .sorted {
                if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
                return $0.id.uuidString < $1.id.uuidString
            }
            .prefix(maximumPendingActions)
            .map { action in
                let requiresPhoneReview: Bool
                if case .trainingPlan(_) = action.payload {
                    requiresPhoneReview = true
                } else {
                    requiresPhoneReview = false
                }
                return WatchPendingActionSummary(
                    actionID: action.id,
                    title: action.payload.title,
                    summary: action.payload.summary,
                    expiresAt: action.expiresAt,
                    requiresPhoneReview: requiresPhoneReview
                )
            }
        let plansThroughTomorrow = calendar.date(byAdding: .day, value: 2, to: dayStart)
        let singleSessionSummaries = workoutPlans
            .filter {
                guard $0.state != .terminal,
                      let scheduledAt = $0.draft.scheduledAt,
                      let plansThroughTomorrow else { return false }
                return scheduledAt >= dayStart && scheduledAt < plansThroughTomorrow
            }
            .map {
                WatchWorkoutPlanSummary(
                    actionID: $0.actionID,
                    title: $0.draft.name,
                    scheduledAt: $0.draft.scheduledAt,
                    state: $0.state.rawValue,
                    lastError: $0.lastError
                )
            }
        let multiDaySessionSummaries = trainingPlans.flatMap { entry in
            entry.draft.sessions.compactMap { session -> WatchWorkoutPlanSummary? in
                guard entry.state != .terminal,
                      !session.isRestDay,
                      session.date >= dayStart,
                      let plansThroughTomorrow,
                      session.date < plansThroughTomorrow,
                      let activity = session.activity else { return nil }
                return WatchWorkoutPlanSummary(
                    actionID: session.id,
                    title: "\(entry.draft.name) · \(activity.displayName)",
                    scheduledAt: session.date,
                    state: entry.state.rawValue,
                    lastError: entry.lastError
                )
            }
        }
        let workoutPlanSummaries = Array((singleSessionSummaries + multiDaySessionSummaries)
            .sorted {
                let leftDate = $0.scheduledAt ?? .distantFuture
                let rightDate = $1.scheduledAt ?? .distantFuture
                if leftDate != rightDate { return leftDate < rightDate }
                return $0.actionID.uuidString < $1.actionID.uuidString
            }
            .prefix(maximumWorkoutPlans))

        return DailyLoopSnapshot(
            dayStart: dayStart,
            generatedAt: date,
            phase: Self.phase(at: date, calendar: calendar),
            todayState: todayState,
            todaySummary: Self.nonEmpty(currentBrief?.summary),
            tomorrowGuidance: healthState?.tomorrowGuidance,
            pendingActions: pendingSummaries,
            workoutPlans: workoutPlanSummaries,
            quickActions: DailyLoopQuickAction.allCases
        )
    }

    private static func phase(at date: Date, calendar: Calendar) -> DailyLoopPhase {
        let hour = calendar.component(.hour, from: date)
        if hour < 12 { return .morning }
        if hour < 18 { return .daytime }
        return .evening
    }

    private static func headline(for state: HealthStateV2) -> String {
        switch state.recovery.status {
        case .insufficientEvidence: "恢复证据不足"
        case .withinTypicalRange: "恢复处于常见范围"
        case .attention: "恢复状态需要留意"
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Composes the daily loop from already-loaded summaries and current action summaries.
/// It never refreshes health calculations or writes persistence.
@MainActor
final class DailyLoopSnapshotService {
    private let healthIntelligenceService: HealthIntelligenceService
    private let agentSession: AgentSession
    private let workoutPlanSchedulingService: WorkoutPlanSchedulingService
    private let composer: DailyLoopSnapshotComposer

    init(
        healthIntelligenceService: HealthIntelligenceService,
        agentSession: AgentSession,
        workoutPlanSchedulingService: WorkoutPlanSchedulingService,
        calendar: Calendar = .current
    ) {
        self.healthIntelligenceService = healthIntelligenceService
        self.agentSession = agentSession
        self.workoutPlanSchedulingService = workoutPlanSchedulingService
        self.composer = DailyLoopSnapshotComposer(calendar: calendar)
    }

    func snapshot(asOf date: Date = Date()) throws -> DailyLoopSnapshot {
        composer.compose(
            asOf: date,
            dailyBrief: healthIntelligenceService.dailyBrief,
            pendingActions: agentSession.pendingActions,
            workoutPlans: try workoutPlanSchedulingService.confirmedPlans(),
            trainingPlans: try workoutPlanSchedulingService.confirmedTrainingPlans()
        )
    }
}
