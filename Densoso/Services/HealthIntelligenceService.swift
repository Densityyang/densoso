import DensosoDomain
import Foundation
import Observation
import SwiftData

private struct HealthBriefCacheGenerationError: Error {}

private struct HealthBriefRefreshWaiter {
    let id: UUID
    let continuation: CheckedContinuation<DailyHealthBrief?, Error>
}

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
    typealias RefreshOperation = @MainActor (Date, UInt64) async throws -> HealthIntelligenceRefreshSnapshot
    typealias ObserverRefreshDelay = @MainActor (Duration) async throws -> Void

    private let projectionActor: HealthProjectionActor
    private let briefCacheGenerationFence: HealthBriefCacheGenerationFence
    private let persistenceOperationBarrier: PersistenceOperationBarrier
    private let refreshOperation: RefreshOperation
    private let observerRefreshDelay: ObserverRefreshDelay
    private var briefCacheGeneration: UInt64
    private var isBriefCacheInvalidated = false
    private var isBriefRefreshAllowed = true
    private var refreshGeneration: UInt64 = 0
    private var queuedRefreshDate: Date?
    private var refreshRunnerTask: Task<Void, Never>?
    private var refreshWaiters: [HealthBriefRefreshWaiter] = []
    private var observerRefreshGeneration: UInt64 = 0
    private var observerRefreshTask: Task<Void, Never>?

    private(set) var dailyBrief: DailyHealthBrief?
    private(set) var dailyBriefSourceFingerprint: String?
    private(set) var dailyBriefValidatedAt: Date?
    private(set) var weeklyBrief: WeeklyHealthBrief?
    private(set) var lastError: String?
    private(set) var lastSuccessfulRefreshAt: Date?
    private(set) var lastRefreshFailedAt: Date?
    private(set) var consecutiveRefreshFailures = 0

    init(
        projectionActor: HealthProjectionActor,
        briefCacheGenerationFence: HealthBriefCacheGenerationFence,
        refreshOperation: RefreshOperation? = nil,
        observerRefreshDelay: @escaping ObserverRefreshDelay = { duration in try await Task.sleep(for: duration) },
        persistenceOperationBarrier: PersistenceOperationBarrier = .shared
    ) {
        self.projectionActor = projectionActor
        self.briefCacheGenerationFence = briefCacheGenerationFence
        self.persistenceOperationBarrier = persistenceOperationBarrier
        self.observerRefreshDelay = observerRefreshDelay
        self.refreshOperation = refreshOperation ?? { date, cacheGeneration in
            try await projectionActor.refresh(asOf: date, cacheGeneration: cacheGeneration)
        }
        briefCacheGeneration = briefCacheGenerationFence.currentGeneration
    }

    convenience init(
        modelContainer: ModelContainer,
        calendar: Calendar = .autoupdatingCurrent,
        persistenceOperationBarrier: PersistenceOperationBarrier = .shared
    ) {
        let briefCacheGenerationFence = HealthBriefCacheGenerationFence()
        self.init(
            projectionActor: HealthProjectionActor(
                modelContainer: modelContainer,
                calendar: calendar,
                briefCacheGenerationFence: briefCacheGenerationFence
            ),
            briefCacheGenerationFence: briefCacheGenerationFence,
            observerRefreshDelay: { duration in try await Task.sleep(for: duration) },
            persistenceOperationBarrier: persistenceOperationBarrier
        )
    }

    @discardableResult
    func refresh(asOf date: Date = Date()) async throws -> DailyHealthBrief? {
        try await PerformanceSignposts.measureAsync("Health.StateRefresh") {
            let waiterID = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<DailyHealthBrief?, Error>) in
                    guard !Task.isCancelled else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    guard isBriefRefreshAllowed else {
                        continuation.resume(throwing: HealthBriefCacheGenerationError())
                        return
                    }
                    refreshGeneration &+= 1
                    queuedRefreshDate = date
                    refreshWaiters.append(HealthBriefRefreshWaiter(id: waiterID, continuation: continuation))
                    if refreshRunnerTask == nil {
                        refreshRunnerTask = Task { @MainActor [weak self] in
                            await self?.runRefreshQueue()
                        }
                    }
                }
            } onCancel: { [weak self] in
                Task { @MainActor in
                    self?.cancelRefreshWaiter(waiterID)
                }
            }
        }
    }

    private func runRefreshQueue() async {
        while let date = queuedRefreshDate {
            queuedRefreshDate = nil
            let requestGeneration = refreshGeneration
            let expectedCacheGeneration = briefCacheGeneration
            lastError = nil
            do {
                let operationLease = try await persistenceOperationBarrier.acquireMutationOperation()
                defer { persistenceOperationBarrier.release(operationLease) }
                let snapshot = try await persistenceOperationBarrier.withLease(operationLease) {
                    try await refreshOperation(date, expectedCacheGeneration)
                }
                guard requestGeneration == refreshGeneration else { continue }
                guard isBriefRefreshAllowed,
                      expectedCacheGeneration == briefCacheGeneration,
                      briefCacheGenerationFence.currentGeneration == expectedCacheGeneration else {
                    throw HealthBriefCacheGenerationError()
                }
                isBriefCacheInvalidated = false
                dailyBrief = snapshot.dailyBrief
                dailyBriefSourceFingerprint = snapshot.dailyBriefSourceFingerprint
                dailyBriefValidatedAt = snapshot.dailyBriefValidatedAt
                if snapshot.updatesWeeklyBrief {
                    weeklyBrief = snapshot.weeklyBrief
                }
                lastRefreshFailedAt = nil
                consecutiveRefreshFailures = 0
                lastSuccessfulRefreshAt = date
                lastError = nil
                resumeRefreshWaiters(returning: snapshot.dailyBrief)
            } catch is HealthBriefCacheGenerationError {
                guard requestGeneration == refreshGeneration else { continue }
                resumeRefreshWaiters(throwing: HealthBriefCacheGenerationError())
            } catch {
                guard requestGeneration == refreshGeneration else { continue }
                lastRefreshFailedAt = Date()
                consecutiveRefreshFailures += 1
                let errorMessage = SharedErrorDescriptor.mapped(
                    from: error,
                    fallback: .projectionFailedFallback
                ).userMessage
                lastError = "无法更新健康摘要：\(errorMessage)"
                resumeRefreshWaiters(throwing: error)
            }
        }
        refreshRunnerTask = nil
    }

    private func resumeRefreshWaiters(returning brief: DailyHealthBrief?) {
        let waiters = refreshWaiters
        refreshWaiters.removeAll()
        waiters.forEach { $0.continuation.resume(returning: brief) }
    }

    private func resumeRefreshWaiters(throwing error: Error) {
        let waiters = refreshWaiters
        refreshWaiters.removeAll()
        waiters.forEach { $0.continuation.resume(throwing: error) }
    }

    private func cancelRefreshWaiter(_ id: UUID) {
        guard let index = refreshWaiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = refreshWaiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
        guard refreshWaiters.isEmpty else { return }
        refreshGeneration &+= 1
        queuedRefreshDate = nil
    }

    func hasDailyBriefSourceChanged(asOf date: Date = Date()) async throws -> Bool {
        let currentFingerprint = try await projectionActor.dailyBriefSourceFingerprint(asOf: date)
        return currentFingerprint != dailyBriefSourceFingerprint
    }

    /// Debounces the burst of per-stream observer callbacks and lets a newer
    /// refresh generation supersede an older projection result.
    func scheduleRefreshAfterHealthObserverEvent(
        onComplete: @escaping @MainActor () -> Void = {}
    ) {
        observerRefreshGeneration &+= 1
        let generation = observerRefreshGeneration
        observerRefreshTask?.cancel()
        let delay = observerRefreshDelay
        observerRefreshTask = Task { @MainActor [weak self, delay] in
            do {
                try await delay(.milliseconds(300))
            } catch {
                return
            }
            guard let self, self.observerRefreshGeneration == generation else { return }
            self.observerRefreshTask = nil
            do {
                _ = try await self.refresh()
                guard self.observerRefreshGeneration == generation else { return }
                onComplete()
            } catch {
                // A later observer callback or foreground activation can retry.
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
        refreshGeneration &+= 1
        queuedRefreshDate = nil
        isBriefCacheInvalidated = true
        isBriefRefreshAllowed = false
        lastError = nil
        lastRefreshFailedAt = nil
        consecutiveRefreshFailures = 0
        lastSuccessfulRefreshAt = nil
        resumeRefreshWaiters(throwing: HealthBriefCacheGenerationError())
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
        let operationLease = try await persistenceOperationBarrier.acquireMutationOperation()
        defer { persistenceOperationBarrier.release(operationLease) }
        try await persistenceOperationBarrier.withLease(operationLease) {
            try await projectionActor.saveGoalProfile(goal)
        }
    }
}
