import DensosoDomain
import Foundation
import Observation
import SwiftData

private struct HealthBriefCacheGenerationError: Error {}

/// Serializes brief-cache commits with synchronous HealthKit snapshot purges.
final class HealthBriefCacheGenerationFence: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0

    var currentGeneration: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    @discardableResult
    func invalidate() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        generation &+= 1
        return generation
    }

    func withCurrentGeneration<Value>(
        _ expected: UInt64,
        perform operation: () throws -> Value
    ) throws -> Value {
        lock.lock()
        defer { lock.unlock() }
        guard generation == expected else { throw HealthBriefCacheGenerationError() }
        return try operation()
    }
}

/// MainActor observable facade. SwiftData reads, deterministic calculations and
/// cache writes are performed by `HealthProjectionActor`.
@MainActor
@Observable
final class HealthIntelligenceService {
    private let projectionActor: HealthProjectionActor
    private let briefCacheGenerationFence: HealthBriefCacheGenerationFence
    private var briefCacheGeneration: UInt64
    private var isBriefCacheInvalidated = false
    private var isBriefRefreshAllowed = true

    private(set) var dailyBrief: DailyHealthBrief?
    private(set) var dailyBriefSourceFingerprint: String?
    private(set) var dailyBriefValidatedAt: Date?
    private(set) var weeklyBrief: WeeklyHealthBrief?
    private(set) var lastError: String?

    init(
        projectionActor: HealthProjectionActor,
        briefCacheGenerationFence: HealthBriefCacheGenerationFence
    ) {
        self.projectionActor = projectionActor
        self.briefCacheGenerationFence = briefCacheGenerationFence
        briefCacheGeneration = briefCacheGenerationFence.currentGeneration
    }

    convenience init(modelContainer: ModelContainer, calendar: Calendar = .current) {
        let briefCacheGenerationFence = HealthBriefCacheGenerationFence()
        self.init(
            projectionActor: HealthProjectionActor(
                modelContainer: modelContainer,
                calendar: calendar,
                briefCacheGenerationFence: briefCacheGenerationFence
            ),
            briefCacheGenerationFence: briefCacheGenerationFence
        )
    }

    @discardableResult
    func refresh(asOf date: Date = Date()) async throws -> DailyHealthBrief? {
        try await PerformanceSignposts.measureAsync("Health.StateRefresh") {
            guard isBriefRefreshAllowed else { throw HealthBriefCacheGenerationError() }
            let expectedGeneration = briefCacheGeneration
            lastError = nil
            do {
                let snapshot = try await projectionActor.refresh(
                    asOf: date,
                    cacheGeneration: expectedGeneration
                )
                guard expectedGeneration == briefCacheGeneration,
                      briefCacheGenerationFence.currentGeneration == expectedGeneration else {
                    throw HealthBriefCacheGenerationError()
                }
                isBriefCacheInvalidated = false
                dailyBrief = snapshot.dailyBrief
                dailyBriefSourceFingerprint = snapshot.dailyBriefSourceFingerprint
                dailyBriefValidatedAt = snapshot.dailyBriefValidatedAt
                if snapshot.updatesWeeklyBrief {
                    weeklyBrief = snapshot.weeklyBrief
                }
                return snapshot.dailyBrief
            } catch is HealthBriefCacheGenerationError {
                throw HealthBriefCacheGenerationError()
            } catch {
                let errorMessage = SharedErrorDescriptor.mapped(
                    from: error,
                    fallback: .projectionFailedFallback
                ).userMessage
                lastError = "无法更新健康摘要：\(errorMessage)"
                throw error
            }
        }
    }

    func loadCachedBriefs() async {
        guard !isBriefCacheInvalidated, isBriefRefreshAllowed else { return }
        let expectedGeneration = briefCacheGeneration
        let cached = await projectionActor.loadCachedBriefs()
        guard expectedGeneration == briefCacheGeneration,
              briefCacheGenerationFence.currentGeneration == expectedGeneration,
              !isBriefCacheInvalidated else { return }
        dailyBrief = cached.hasDailyRecord ? cached.dailyBrief : nil
        dailyBriefSourceFingerprint = cached.dailyBriefSourceFingerprint
        dailyBriefValidatedAt = cached.dailyBriefValidatedAt
        weeklyBrief = cached.hasWeeklyRecord ? cached.weeklyBrief : nil
    }

    /// Hides derived briefs before a HealthKit cache purge and invalidates any
    /// refresh already reading the previous HealthKit snapshot.
    func invalidateBriefsForHealthSnapshotRebuild() {
        briefCacheGeneration = briefCacheGenerationFence.invalidate()
        isBriefCacheInvalidated = true
        isBriefRefreshAllowed = false
        lastError = nil
        dailyBrief = nil
        dailyBriefSourceFingerprint = nil
        dailyBriefValidatedAt = nil
        weeklyBrief = nil
    }

    func allowBriefRefreshAfterSuccessfulHealthSnapshotPurge() {
        guard briefCacheGenerationFence.currentGeneration == briefCacheGeneration else { return }
        isBriefRefreshAllowed = true
    }

    func healthContextSummary(asOf date: Date = Date()) async throws -> HealthContextSummary? {
        try await projectionActor.healthContextSummary(asOf: date)
    }

    /// A read-only, deterministic evidence context for structured Agent summaries.
    /// This path never refreshes or writes caches.
    func healthNarrativeContext(asOf date: Date = Date()) async throws -> HealthNarrativeContext {
        try await projectionActor.healthNarrativeContext(asOf: date)
    }

    /// A read-only query for recent user-reported feelings; it never changes HealthState.
    func subjectiveContext(asOf date: Date = Date()) async throws -> SubjectiveHealthContext? {
        try await projectionActor.subjectiveContext(asOf: date)
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
