import DensosoDomain
import Foundation
import Observation
import SwiftData

/// MainActor observable facade. SwiftData reads, deterministic calculations and
/// cache writes are performed by `HealthProjectionActor`.
@MainActor
@Observable
final class HealthIntelligenceService {
    private let projectionActor: HealthProjectionActor

    private(set) var dailyBrief: DailyHealthBrief?
    private(set) var weeklyBrief: WeeklyHealthBrief?
    private(set) var lastError: String?

    init(projectionActor: HealthProjectionActor) {
        self.projectionActor = projectionActor
    }

    convenience init(modelContainer: ModelContainer, calendar: Calendar = .current) {
        self.init(projectionActor: HealthProjectionActor(modelContainer: modelContainer, calendar: calendar))
    }

    @discardableResult
    func refresh(asOf date: Date = Date()) async throws -> DailyHealthBrief? {
        lastError = nil
        do {
            let snapshot = try await projectionActor.refresh(asOf: date)
            dailyBrief = snapshot.dailyBrief
            if snapshot.updatesWeeklyBrief {
                weeklyBrief = snapshot.weeklyBrief
            }
            return snapshot.dailyBrief
        } catch {
            lastError = "无法更新健康摘要：\(error.localizedDescription)"
            throw error
        }
    }

    func loadCachedBriefs() async {
        let cached = await projectionActor.loadCachedBriefs()
        if cached.hasDailyRecord { dailyBrief = cached.dailyBrief }
        if cached.hasWeeklyRecord { weeklyBrief = cached.weeklyBrief }
    }

    func healthContextSummary(asOf date: Date = Date()) async throws -> HealthContextSummary? {
        try await projectionActor.healthContextSummary(asOf: date)
    }

    /// A read-only, deterministic evidence context for structured Agent summaries.
    /// This path never refreshes or writes caches.
    func healthNarrativeContext(asOf date: Date = Date()) async throws -> HealthNarrativeContext {
        try await projectionActor.healthNarrativeContext(asOf: date)
    }

    /// Does not refresh or write the daily/weekly brief caches.
    func todayHealthState(asOf date: Date = Date()) async throws -> HealthStateV2? {
        try await projectionActor.todayHealthState(asOf: date)
    }

    func healthHistory(from startDate: Date, through endDate: Date) async throws -> [HealthStateHistoryPoint] {
        try await projectionActor.healthHistory(from: startDate, through: endDate)
    }

    func goalProfile(asOf date: Date = Date()) async throws -> GoalProfile? {
        try await projectionActor.goalProfile(asOf: date)
    }

    func saveGoalProfile(_ goal: GoalProfile) async throws {
        try await projectionActor.saveGoalProfile(goal)
    }
}
