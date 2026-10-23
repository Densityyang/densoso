import CryptoKit
import DensosoDomain
import Foundation

struct DailyLoopSnapshotComposer {
    private let calendar: Calendar
    private let maximumPendingActions = 10
    private let maximumWorkoutPlans = 10
    private let refreshStaleAfter: TimeInterval = 6 * 60 * 60

    init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    func compose(
        asOf date: Date,
        generatedAt: Date = Date(),
        dailyBrief: DailyHealthBrief?,
        dailyBriefSourceFingerprint: String? = nil,
        dailyBriefValidatedAt: Date? = nil,
        coverage: DailyLoopMetricCoverage = .unavailable,
        errorCode: String? = nil,
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

        let timezoneIdentifier = calendar.timeZone.identifier
        let dayKey = DailyLoopSnapshot.localDayKey(for: dayStart, timezoneIdentifier: timezoneIdentifier)
        let sourceFingerprint: String? = errorCode == nil
            ? makeSourceFingerprint(
                dayKey: dayKey,
                timezoneIdentifier: timezoneIdentifier,
                dailyBriefSourceFingerprint: currentBrief == nil ? nil : dailyBriefSourceFingerprint,
                dailyBrief: currentBrief,
                coverage: coverage,
                pendingActions: pendingSummaries,
                workoutPlans: workoutPlanSummaries
            )
            : nil
        let refreshState: DailyLoopRefreshState
        if errorCode != nil {
            refreshState = .error
        } else if sourceFingerprint == nil {
            refreshState = .refreshRequired
        } else {
            refreshState = freshness(
                asOf: date,
                dailyBrief: currentBrief,
                dailyBriefSourceFingerprint: dailyBriefSourceFingerprint,
                dailyBriefValidatedAt: dailyBriefValidatedAt
            )
        }

        return DailyLoopSnapshot(
            dayStart: dayStart,
            dayKey: dayKey,
            timezoneIdentifier: timezoneIdentifier,
            generatedAt: generatedAt,
            sourceFingerprint: sourceFingerprint,
            projectionVersion: DailyLoopSnapshot.currentAlgorithmVersion,
            coverage: coverage,
            refreshState: refreshState,
            errorCode: errorCode,
            phase: Self.phase(at: date, calendar: calendar),
            todayState: todayState,
            todaySummary: Self.nonEmpty(currentBrief?.summary),
            tomorrowGuidance: healthState?.tomorrowGuidance,
            pendingActions: pendingSummaries,
            workoutPlans: workoutPlanSummaries,
            quickActions: DailyLoopQuickAction.allCases
        )
    }

    private func freshness(
        asOf date: Date,
        dailyBrief: DailyHealthBrief?,
        dailyBriefSourceFingerprint: String?,
        dailyBriefValidatedAt: Date?
    ) -> DailyLoopRefreshState {
        guard dailyBrief != nil,
              let dailyBriefSourceFingerprint,
              !dailyBriefSourceFingerprint.isEmpty,
              let dailyBriefValidatedAt else { return .refreshRequired }
        guard calendar.isDate(dailyBriefValidatedAt, inSameDayAs: date) else { return .stale }
        let age = date.timeIntervalSince(dailyBriefValidatedAt)
        guard age >= 0, age <= refreshStaleAfter else { return .stale }
        return .fresh
    }

    private func makeSourceFingerprint(
        dayKey: String,
        timezoneIdentifier: String,
        dailyBriefSourceFingerprint: String?,
        dailyBrief: DailyHealthBrief?,
        coverage: DailyLoopMetricCoverage,
        pendingActions: [WatchPendingActionSummary],
        workoutPlans: [WatchWorkoutPlanSummary]
    ) -> String? {
        let material = DailyLoopFingerprintMaterial(
            algorithmVersion: DailyLoopSnapshot.currentAlgorithmVersion,
            dayKey: dayKey,
            timezoneIdentifier: timezoneIdentifier,
            dailyBriefSourceFingerprint: dailyBriefSourceFingerprint,
            dailyBrief: dailyBrief,
            coverage: coverage,
            pendingActions: pendingActions,
            workoutPlans: workoutPlans,
            quickActions: DailyLoopQuickAction.allCases
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(material) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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

private struct DailyLoopFingerprintMaterial: Encodable {
    let algorithmVersion: String
    let dayKey: String
    let timezoneIdentifier: String
    let dailyBriefSourceFingerprint: String?
    let dailyBrief: DailyHealthBrief?
    let coverage: DailyLoopMetricCoverage
    let pendingActions: [WatchPendingActionSummary]
    let workoutPlans: [WatchWorkoutPlanSummary]
    let quickActions: [DailyLoopQuickAction]
}

/// Composes the daily loop from actor-loaded plan entries and current health/action summaries.
/// `snapshot` is read-only; `refreshSnapshot` explicitly refreshes the canonical local health brief first.
@MainActor
final class DailyLoopSnapshotService {
    private let healthProjectionActor: HealthProjectionActor
    private let healthIntelligenceService: HealthIntelligenceService
    private let agentSession: AgentSession
    private(set) var lastGeneratedAt: Date?

    init(
        healthProjectionActor: HealthProjectionActor,
        healthIntelligenceService: HealthIntelligenceService,
        agentSession: AgentSession
    ) {
        self.healthProjectionActor = healthProjectionActor
        self.healthIntelligenceService = healthIntelligenceService
        self.agentSession = agentSession
    }

    func snapshot(asOf date: Date = Date()) async throws -> DailyLoopSnapshot {
        let snapshot = try await healthProjectionActor.dailyLoopSnapshot(
            asOf: date,
            dailyBrief: healthIntelligenceService.dailyBrief,
            dailyBriefSourceFingerprint: healthIntelligenceService.dailyBriefSourceFingerprint,
            dailyBriefValidatedAt: healthIntelligenceService.dailyBriefValidatedAt,
            pendingActions: agentSession.pendingActions
        )
        lastGeneratedAt = snapshot.generatedAt
        return snapshot
    }

    func refreshSnapshot(asOf date: Date = Date()) async throws -> DailyLoopSnapshot {
        _ = try await healthIntelligenceService.refresh(asOf: date)
        return try await snapshot(asOf: date)
    }
}
