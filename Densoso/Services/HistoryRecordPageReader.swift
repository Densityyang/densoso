import Foundation
import SwiftData

struct HistoryRecordCursor: Equatable {
    let date: Date
    let id: UUID
}

struct HistoryRecordDateRange: Equatable {
    let startDate: Date
    let endDate: Date
}

struct HistoryRecordPage<Record> {
    let records: [Record]
    let nextCursor: HistoryRecordCursor?
    let hasMore: Bool
}

struct HistorySyncSummary: Equatable {
    let pendingCount: Int
    let failedCount: Int
    let latestSuccessfulImport: Date?
}

struct HistoryRecordPageReader {
    static let pageSize = 64

    func meals(
        in context: ModelContext,
        during dateRange: HistoryRecordDateRange?,
        before cursor: HistoryRecordCursor? = nil
    ) throws -> HistoryRecordPage<MealRecord> {
        let sortBy = [
            SortDescriptor(\MealRecord.date, order: .reverse),
            SortDescriptor(\MealRecord.id, order: .reverse),
        ]
        return try fetchPage(
            in: context,
            predicate: mealPredicate(during: dateRange, before: cursor),
            sortBy: sortBy,
            cursorFor: { HistoryRecordCursor(date: $0.date, id: $0.id) },
            hasMorePredicate: { self.mealPredicate(during: dateRange, before: $0) }
        )
    }

    func workouts(
        in context: ModelContext,
        during dateRange: HistoryRecordDateRange?,
        before cursor: HistoryRecordCursor? = nil
    ) throws -> HistoryRecordPage<WorkoutRecord> {
        let sortBy = [
            SortDescriptor(\WorkoutRecord.date, order: .reverse),
            SortDescriptor(\WorkoutRecord.id, order: .reverse),
        ]
        return try fetchPage(
            in: context,
            predicate: workoutPredicate(during: dateRange, before: cursor),
            sortBy: sortBy,
            cursorFor: { HistoryRecordCursor(date: $0.date, id: $0.id) },
            hasMorePredicate: { self.workoutPredicate(during: dateRange, before: $0) }
        )
    }

    func weights(
        in context: ModelContext,
        during dateRange: HistoryRecordDateRange?,
        before cursor: HistoryRecordCursor? = nil
    ) throws -> HistoryRecordPage<WeightRecord> {
        let sortBy = [
            SortDescriptor(\WeightRecord.measuredAt, order: .reverse),
            SortDescriptor(\WeightRecord.id, order: .reverse),
        ]
        return try fetchPage(
            in: context,
            predicate: weightPredicate(during: dateRange, before: cursor),
            sortBy: sortBy,
            cursorFor: { HistoryRecordCursor(date: $0.measuredAt, id: $0.id) },
            hasMorePredicate: { self.weightPredicate(during: dateRange, before: $0) }
        )
    }

    func syncSummary(in context: ModelContext) throws -> HistorySyncSummary {
        let pending = "pending"
        let sending = "sending"
        let retryable = "retryable"
        let terminal = "terminal"
        let pendingPredicate = #Predicate<HealthSyncOutboxEntry> { entry in
            entry.state == pending || entry.state == sending || entry.state == retryable
        }
        let failedPredicate = #Predicate<HealthSyncOutboxEntry> { $0.state == terminal }
        let pendingCount = try context.fetchCount(FetchDescriptor(predicate: pendingPredicate))
        let failedCount = try context.fetchCount(FetchDescriptor(predicate: failedPredicate))

        let cursorPredicate = #Predicate<HealthKitImportCursor> { $0.lastSuccessfulAt != nil }
        var cursorDescriptor = FetchDescriptor<HealthKitImportCursor>(
            predicate: cursorPredicate,
            sortBy: [SortDescriptor(\HealthKitImportCursor.lastSuccessfulAt, order: .reverse)]
        )
        cursorDescriptor.fetchLimit = 1
        let latestSuccessfulImport = try context.fetch(cursorDescriptor).first?.lastSuccessfulAt
        return HistorySyncSummary(
            pendingCount: pendingCount,
            failedCount: failedCount,
            latestSuccessfulImport: latestSuccessfulImport
        )
    }

    private func fetchPage<Record: PersistentModel>(
        in context: ModelContext,
        predicate: Predicate<Record>,
        sortBy: [SortDescriptor<Record>],
        cursorFor: (Record) -> HistoryRecordCursor,
        hasMorePredicate: (HistoryRecordCursor) -> Predicate<Record>
    ) throws -> HistoryRecordPage<Record> {
        var descriptor = FetchDescriptor<Record>(predicate: predicate, sortBy: sortBy)
        descriptor.fetchLimit = Self.pageSize
        let records = try context.fetch(descriptor)
        let nextCursor = records.last.map(cursorFor)
        let hasMore: Bool
        if records.count == Self.pageSize, let nextCursor {
            var lookAhead = FetchDescriptor<Record>(predicate: hasMorePredicate(nextCursor))
            lookAhead.fetchLimit = 1
            hasMore = try context.fetch(lookAhead).first != nil
        } else {
            hasMore = false
        }
        return HistoryRecordPage(records: records, nextCursor: nextCursor, hasMore: hasMore)
    }

    private func mealPredicate(
        during dateRange: HistoryRecordDateRange?,
        before cursor: HistoryRecordCursor?
    ) -> Predicate<MealRecord> {
        let startDate = dateRange?.startDate ?? .distantPast
        let endDate = dateRange?.endDate ?? .distantFuture
        if let cursor {
            let cursorDate = cursor.date
            let cursorID = cursor.id
            return #Predicate<MealRecord> { meal in
                meal.date >= startDate && meal.date < endDate
                    && (meal.date < cursorDate || (meal.date == cursorDate && meal.id < cursorID))
            }
        }
        return #Predicate<MealRecord> { $0.date >= startDate && $0.date < endDate }
    }

    private func workoutPredicate(
        during dateRange: HistoryRecordDateRange?,
        before cursor: HistoryRecordCursor?
    ) -> Predicate<WorkoutRecord> {
        let startDate = dateRange?.startDate ?? .distantPast
        let endDate = dateRange?.endDate ?? .distantFuture
        if let cursor {
            let cursorDate = cursor.date
            let cursorID = cursor.id
            return #Predicate<WorkoutRecord> { workout in
                workout.date >= startDate && workout.date < endDate
                    && (workout.date < cursorDate || (workout.date == cursorDate && workout.id < cursorID))
            }
        }
        return #Predicate<WorkoutRecord> { $0.date >= startDate && $0.date < endDate }
    }

    private func weightPredicate(
        during dateRange: HistoryRecordDateRange?,
        before cursor: HistoryRecordCursor?
    ) -> Predicate<WeightRecord> {
        let startDate = dateRange?.startDate ?? .distantPast
        let endDate = dateRange?.endDate ?? .distantFuture
        if let cursor {
            let cursorDate = cursor.date
            let cursorID = cursor.id
            return #Predicate<WeightRecord> { weight in
                weight.measuredAt >= startDate && weight.measuredAt < endDate
                    && (weight.measuredAt < cursorDate
                        || (weight.measuredAt == cursorDate && weight.id < cursorID))
            }
        }
        return #Predicate<WeightRecord> { $0.measuredAt >= startDate && $0.measuredAt < endDate }
    }
}
