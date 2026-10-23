import DensosoDomain
import Foundation
import SwiftData

@MainActor
final class HistoricalMetricsRecomputeService: HistoricalMetricsRecomputing {
    static let lookbackDayCount = 90
    static let maximumBatchSize = 10

    private let modelContainer: ModelContainer

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    func recomputePendingMetrics(
        now: Date,
        batchSize: Int,
        shouldStop: @MainActor () -> Bool
    ) async throws -> HistoricalMetricsRecomputeResult {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        guard let firstDay = calendar.date(byAdding: .day, value: -(Self.lookbackDayCount - 1), to: today),
              let dayAfterToday = calendar.date(byAdding: .day, value: 1, to: today) else {
            return HistoricalMetricsRecomputeResult(
                processedCount: 0,
                hasMoreEligibleWork: false,
                stoppedEarly: false
            )
        }

        let queryContext = ModelContext(modelContainer)
        let requiresRecompute = true
        let currentProjectionVersion = AlgorithmVersions.dailyMetricsProjection
        let predicate = #Predicate<DailyMetrics> {
            $0.date >= firstDay && $0.date < dayAfterToday
                && ($0.requiresRecompute == requiresRecompute
                    || $0.projectionVersion != currentProjectionVersion
                    || $0.sourceFingerprint == "")
        }
        var descriptor = FetchDescriptor<DailyMetrics>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.date)]
        )
        // DailyMetrics has one row per local day, so this covers the complete
        // 90-day window while keeping the candidate read strictly bounded.
        descriptor.fetchLimit = Self.lookbackDayCount
        let candidateDays = try queryContext.fetch(descriptor).map(\.date)
        let boundedBatchSize = min(max(batchSize, 1), Self.maximumBatchSize)
        var processedCount = 0

        for (index, day) in candidateDays.enumerated() {
            if shouldStop() {
                return HistoricalMetricsRecomputeResult(
                    processedCount: processedCount,
                    hasMoreEligibleWork: index < candidateDays.count,
                    stoppedEarly: true
                )
            }

            if processedCount >= boundedBatchSize {
                if try DailyMetricsProjector.hasValidHistoricalRecomputeInputs(on: day, now: now, in: queryContext) {
                    return HistoricalMetricsRecomputeResult(
                        processedCount: processedCount,
                        hasMoreEligibleWork: true,
                        stoppedEarly: false
                    )
                }
            } else {
                do {
                    if try await DailyMetricsProjector.reprojectHistoricalIfInputsAvailable(on: day, now: now, in: queryContext) {
                        try queryContext.save()
                        processedCount += 1
                    }
                } catch {
                    queryContext.rollback()
                    throw error
                }
            }

            // Yield between days so BGAppRefreshTask expiration and task
            // cancellation can prevent starting another projection.
            await Task.yield()
            if shouldStop(), index + 1 < candidateDays.count {
                return HistoricalMetricsRecomputeResult(
                    processedCount: processedCount,
                    hasMoreEligibleWork: true,
                    stoppedEarly: true
                )
            }
        }

        return HistoricalMetricsRecomputeResult(
            processedCount: processedCount,
            hasMoreEligibleWork: false,
            stoppedEarly: false
        )
    }
}
