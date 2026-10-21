import Foundation
import CryptoKit
import SwiftData
import DensosoDomain

private struct HealthKitSampleIndexUpdate {
    let sample: HealthSampleSnapshot
    let pendingDayKeys: Set<String>

    func merged(with other: Self) -> Self {
        let preferredSample = HealthSampleSnapshot.preferredForDeduplication(other.sample, over: sample)
            ? other.sample
            : sample
        return Self(
            sample: preferredSample,
            // Each unresolved day survives duplicate page ordering until it is read completely.
            pendingDayKeys: pendingDayKeys.union(other.pendingDayKeys)
        )
    }
}

/// Coordinates local health-record writes and their derived daily metrics.
/// SwiftData persists both the source change and its projection with one save.
@MainActor
final class HealthRepository: HealthSyncRepository {
    private static let healthKitSampleIndexBatchSize = 400
    private static let healthKitSampleIndexPredicateBatchSize = 64
    private static let importedWorkoutBatchSize = 400
    private static let workoutEffortFetchBatchSize = 64

    private let modelContext: ModelContext
    private let willSave: (() throws -> Void)?

    init(modelContext: ModelContext, willSave: (() throws -> Void)? = nil) {
        self.modelContext = modelContext
        self.willSave = willSave
    }

    func insert(_ meal: MealRecord) throws {
        try write(affecting: [meal.date]) { _ in
            modelContext.insert(meal)
            try enqueue(operation: "upsertMeal", recordID: meal.id, syncType: "meal")
        }
    }

    /// Persists an edited local meal and creates a newer HealthKit sync version.
    func update(_ meal: MealRecord) throws {
        try write(affecting: [meal.date]) { _ in
            try enqueue(operation: "upsertMeal", recordID: meal.id, syncType: "meal")
        }
    }

    func update(_ weight: WeightRecord, previouslyAt previousDate: Date? = nil) throws {
        guard weight.source != "healthKit" else { throw HealthRepositoryError.refuseHealthKitEcho }
        let affectedDates = [weight.measuredAt] + (previousDate.map { [$0] } ?? [])
        try write(affecting: affectedDates) { _ in
            try enqueue(operation: "upsertWeight", recordID: weight.id, syncType: "weight")
            try refreshDailyWeightSnapshot(on: weight.measuredAt)
            if let previousDate, !Calendar.current.isDate(previousDate, inSameDayAs: weight.measuredAt) {
                try refreshDailyWeightSnapshot(on: previousDate)
            }
        }
    }

    func insert(_ weight: WeightRecord) throws {
        guard weight.source != "healthKit" else { throw HealthRepositoryError.refuseHealthKitEcho }
        try write(affecting: [weight.measuredAt]) { _ in
            modelContext.insert(weight)
            try enqueue(operation: "upsertWeight", recordID: weight.id, syncType: "weight")
            try refreshDailyWeightSnapshot(on: weight.measuredAt)
        }
    }

    func delete(_ weight: WeightRecord) throws {
        guard weight.source != "healthKit" else { throw HealthRepositoryError.refuseHealthKitEcho }
        try write(affecting: [weight.measuredAt]) { _ in
            try enqueue(operation: "deleteWeight", recordID: weight.id, syncType: "weight")
            modelContext.delete(weight)
            try refreshDailyWeightSnapshot(on: weight.measuredAt, excluding: weight.id)
        }
    }

    func insert(_ workout: WorkoutRecord) throws {
        try write(affecting: [workout.date]) { _ in
            modelContext.insert(workout)
        }
    }

    func delete(_ meal: MealRecord) throws {
        try write(affecting: [meal.date]) { _ in
            try enqueue(operation: "deleteMeal", recordID: meal.id, syncType: "meal")
            modelContext.delete(meal)
        }
    }

    func delete(_ workout: WorkoutRecord) throws {
        try write(affecting: [workout.date]) { _ in
            modelContext.delete(workout)
        }
    }

    /// Applies HealthKit changes atomically with the corresponding anchor update.
    /// Imported records never enter the outbound HealthKit outbox, preventing sync echo.
    func applyImportedWorkouts(
        _ snapshots: [WorkoutSnapshot],
        deletedHealthKitUUIDs: [UUID],
        nextAnchorData: Data,
        stream: String = "workouts"
    ) throws {
        try write(affecting: snapshots.map(\.startedAt)) { affectedDates in
            let importedPredicate = #Predicate<WorkoutRecord> { $0.healthKitUUID != nil }
            var importedDescriptor = FetchDescriptor<WorkoutRecord>(
                predicate: importedPredicate,
                sortBy: [
                    SortDescriptor(\WorkoutRecord.healthKitUUID),
                    SortDescriptor(\WorkoutRecord.createdAt),
                    SortDescriptor(\WorkoutRecord.id),
                ]
            )
            importedDescriptor.fetchLimit = Self.importedWorkoutBatchSize

            let changedUUIDs = Set(snapshots.map(\.healthKitUUID)).union(deletedHealthKitUUIDs)
            var workoutsByHealthKitUUID: [UUID: WorkoutRecord] = [:]
            var duplicateWorkoutIDs = Set<UUID>()
            var currentHealthKitUUID: UUID?
            var currentPreferredWorkout: WorkoutRecord?
            var offset = 0
            // Keep the global one-record-per-HealthKit-UUID invariant while
            // avoiding materializing local workouts that have no HealthKit ID or
            // loading every imported workout into memory at once.
            while true {
                importedDescriptor.fetchOffset = offset
                let importedWorkouts = try modelContext.fetch(importedDescriptor)
                guard !importedWorkouts.isEmpty else { break }
                for workout in importedWorkouts {
                    guard let healthKitUUID = workout.healthKitUUID else { continue }
                    if currentHealthKitUUID != healthKitUUID {
                        if let completedUUID = currentHealthKitUUID,
                           let winner = currentPreferredWorkout,
                           changedUUIDs.contains(completedUUID) {
                            workoutsByHealthKitUUID[completedUUID] = winner
                        }
                        currentHealthKitUUID = healthKitUUID
                        currentPreferredWorkout = workout
                    } else if let existingWinner = currentPreferredWorkout {
                        affectedDates.insert(existingWinner.date)
                        affectedDates.insert(workout.date)
                        if Self.preferredImportedWorkout(workout, existingWinner) {
                            duplicateWorkoutIDs.insert(existingWinner.id)
                            currentPreferredWorkout = workout
                        } else {
                            duplicateWorkoutIDs.insert(workout.id)
                        }
                    }
                }
                offset += importedWorkouts.count
                if importedWorkouts.count < Self.importedWorkoutBatchSize { break }
            }
            if let completedUUID = currentHealthKitUUID,
               let winner = currentPreferredWorkout,
               changedUUIDs.contains(completedUUID) {
                workoutsByHealthKitUUID[completedUUID] = winner
            }
            try deleteWorkoutDuplicates(ids: duplicateWorkoutIDs)

            for snapshot in snapshots {
                if let existing = workoutsByHealthKitUUID[snapshot.healthKitUUID] {
                    affectedDates.insert(existing.date)
                    apply(snapshot, to: existing)
                    affectedDates.insert(existing.date)
                } else {
                    let workout = WorkoutRecord()
                    apply(snapshot, to: workout)
                    modelContext.insert(workout)
                    workoutsByHealthKitUUID[snapshot.healthKitUUID] = workout
                    affectedDates.insert(workout.date)
                }
            }

            for healthKitUUID in Set(deletedHealthKitUUIDs) {
                if let workout = workoutsByHealthKitUUID[healthKitUUID] {
                    affectedDates.insert(workout.date)
                    modelContext.delete(workout)
                }
            }

            if let cursor = try cursorRecord(stream: stream) {
                cursor.anchorData = nextAnchorData
                cursor.updatedAt = Date()
                cursor.lastSuccessfulAt = Date()
            } else {
                modelContext.insert(HealthKitImportCursor(
                    stream: stream,
                    anchorData: nextAnchorData,
                    lastSuccessfulAt: Date()
                ))
            }
        }
    }

    private static func preferredImportedWorkout(_ lhs: WorkoutRecord, _ rhs: WorkoutRecord) -> Bool {
        lhs.createdAt == rhs.createdAt
            ? lhs.id.uuidString < rhs.id.uuidString
            : lhs.createdAt < rhs.createdAt
    }

    private func deleteWorkoutDuplicates(ids: Set<UUID>) throws {
        let orderedIDs = ids.sorted { $0.uuidString < $1.uuidString }
        var offset = 0
        while offset < orderedIDs.count {
            let batchEnd = min(offset + Self.importedWorkoutBatchSize, orderedIDs.count)
            let batchIDs = Array(orderedIDs[offset..<batchEnd])
            let predicate = #Predicate<WorkoutRecord> { batchIDs.contains($0.id) }
            for workout in try modelContext.fetch(FetchDescriptor<WorkoutRecord>(predicate: predicate)) {
                modelContext.delete(workout)
            }
            offset = batchEnd
        }
    }

    func cursor(for stream: String) throws -> HealthKitImportCursor? {
        try cursorRecord(stream: stream)
    }

    func cursorSnapshot(for stream: String) throws -> HealthKitCursorSnapshot? {
        guard let cursor = try cursor(for: stream) else { return nil }
        return HealthKitCursorSnapshot(
            anchorData: cursor.anchorData,
            lastSuccessfulAt: cursor.lastSuccessfulAt,
            lookbackStart: cursor.lookbackStart
        )
    }

    /// Explicit settings sync can rebaseline anchored reads after the user changes HealthKit access.
    func resetHealthKitCursors() throws {
        try write(affecting: []) { _ in
            let cursors = try modelContext.fetch(FetchDescriptor<HealthKitImportCursor>())
            for cursor in cursors {
                cursor.anchorData = nil
                cursor.lastSuccessfulAt = nil
                cursor.lookbackStart = nil
                cursor.updatedAt = Date()
            }
        }
    }

    func affectedHealthSampleDays(for page: HealthSamplePage, stream: String) throws -> [Date] {
        let requestedIDs = Array(Set(page.samples.map(\.id)).union(page.deletedSampleIDs))
            .sorted { $0.uuidString < $1.uuidString }
        var days = Set<Date>()
        if !requestedIDs.isEmpty {
            var offset = 0
            while offset < requestedIDs.count {
                let batchEnd = min(offset + Self.healthKitSampleIndexPredicateBatchSize, requestedIDs.count)
                let sampleIDs = Array(requestedIDs[offset..<batchEnd])
                let predicate = #Predicate<HealthKitSampleIndexRecord> {
                    $0.stream == stream && sampleIDs.contains($0.sampleID)
                }
                for record in try modelContext.fetch(FetchDescriptor<HealthKitSampleIndexRecord>(predicate: predicate)) {
                    days.formUnion(Self.indexedProjectionDays(for: record, stream: stream))
                }
                offset = batchEnd
            }
        }
        for sample in page.samples {
            if stream == HealthMetricID.sleepAnalysis.rawValue {
                days.formUnion(Self.sleepWakeDays(startDate: sample.startDate, endDate: sample.endDate))
            } else {
                days.insert(Calendar.current.startOfDay(for: sample.startDate))
            }
        }
        try forEachPendingHealthKitSampleIndex(stream: stream) { records in
            for record in records {
                days.formUnion(Self.pendingDays(for: record))
            }
        }
        return days.sorted()
    }

    func applyImportedHealthSamples(
        _ page: HealthSamplePage,
        stream: String,
        lastSuccessfulAt: Date,
        lookbackStart: Date?,
        replacements: [HealthSampleDaySnapshot]
    ) throws {
        guard let nextAnchorData = page.nextAnchorData else {
            throw HealthRepositoryError.missingHealthKitAnchor
        }

        let calendar = Calendar.current
        let replacementsByDay = Dictionary(
            replacements.map { (calendar.startOfDay(for: $0.dayStart), $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        let affectedDays = Array(replacementsByDay.keys)
        try write(affecting: affectedDays) { _ in
            for (day, replacement) in replacementsByDay {
                let existing = try healthSnapshot(for: day) ?? Self.emptyHealthSnapshot(for: day)
                let priorSummary = existing.healthKitSampleSummary
                    ?? DailyHealthSampleSummary(samples: existing.healthKitSamples ?? [], dayStart: day)
                let intervalEnd = calendar.date(byAdding: .day, value: 1, to: day) ?? day
                let replacementSamples = replacement.samples.filter { sample in
                    sample.metric.rawValue == stream
                        && (stream == HealthMetricID.sleepAnalysis.rawValue
                            || (sample.startDate >= day && sample.startDate < intervalEnd))
                }
                let dayWorkouts: [WorkoutRecord]
                if stream == HealthMetricID.workoutEffort.rawValue {
                    dayWorkouts = try workouts(on: day)
                } else {
                    dayWorkouts = []
                }
                let replacementSummary = DailyHealthSampleSummaryBuilder.build(
                    samples: replacementSamples,
                    dayStart: day,
                    sleepSamples: stream == HealthMetricID.sleepAnalysis.rawValue ? replacement.samples : nil,
                    workouts: stream == HealthMetricID.workoutEffort.rawValue ? dayWorkouts : []
                )
                let isReplacementAvailable = replacement.readState == .available
                let updatedMetrics = isReplacementAvailable
                    ? priorSummary.metrics.filter { $0.metric.rawValue != stream } + replacementSummary.metrics
                    : priorSummary.metrics
                let updatedEfforts = stream == HealthMetricID.workoutEffort.rawValue && isReplacementAvailable
                    ? replacementSummary.workoutEffort
                    : priorSummary.workoutEffort
                let summary = DailyHealthSampleSummary(
                    metrics: updatedMetrics,
                    sleep: stream == HealthMetricID.sleepAnalysis.rawValue && isReplacementAvailable
                        ? replacementSummary.sleep
                        : priorSummary.sleep,
                    workoutEffort: updatedEfforts
                )
                var readStates = existing.healthReadStates ?? [:]
                readStates[stream] = replacement.readState
                var updated = Self.replacing(
                    existing,
                    healthKitSamples: .some(nil),
                    healthKitSampleSummary: .some(summary),
                    healthReadStates: .some(readStates)
                )

                if stream == HealthMetricID.bodyMass.rawValue {
                    let localWeight = try latestLocalWeightKilograms(on: day)
                    let candidateHealthKitWeight = replacementSummary.aggregate(for: .bodyMass)?.latestValue
                    let healthKitWeight: Double?
                    if isReplacementAvailable,
                       let candidateHealthKitWeight,
                       candidateHealthKitWeight.isFinite,
                       candidateHealthKitWeight > 0 {
                        healthKitWeight = candidateHealthKitWeight
                    } else {
                        healthKitWeight = nil
                    }
                    updated = Self.replacing(updated, weightKilograms: .some(localWeight ?? healthKitWeight))
                }

                try upsertHealthSnapshot(updated, for: day)
            }
            var sampleIndexUpdates: [UUID: HealthKitSampleIndexUpdate] = [:]
            for sample in page.samples where sample.metric.rawValue == stream {
                let update = HealthKitSampleIndexUpdate(
                    sample: sample,
                    pendingDayKeys: Self.unresolvedDayKeys(
                        for: sample,
                        stream: stream,
                        replacementsByDay: replacementsByDay
                    )
                )
                if let existing = sampleIndexUpdates[sample.id] {
                    sampleIndexUpdates[sample.id] = existing.merged(with: update)
                } else {
                    sampleIndexUpdates[sample.id] = update
                }
            }
            for replacement in replacements {
                for sample in replacement.samples where sample.metric.rawValue == stream {
                    let update = HealthKitSampleIndexUpdate(
                        sample: sample,
                        pendingDayKeys: Self.unresolvedDayKeys(
                            for: sample,
                            stream: stream,
                            replacementsByDay: replacementsByDay
                        )
                    )
                    if let existing = sampleIndexUpdates[sample.id] {
                        sampleIndexUpdates[sample.id] = existing.merged(with: update)
                    } else {
                        sampleIndexUpdates[sample.id] = update
                    }
                }
            }
            try upsertHealthKitSampleIndexes(
                sampleIndexUpdates,
                stream: stream,
                replacementsByDay: replacementsByDay
            )
            // Samples present in this update supersede same-page deletions; remaining IDs stay tombstoned.
            let reintroducedSampleIDs = Set(sampleIndexUpdates.keys)
            try markHealthKitSampleIndexesForRequery(
                sampleIDs: Set(page.deletedSampleIDs).subtracting(reintroducedSampleIDs),
                stream: stream
            )
            var pendingIndexUpdates: [(record: HealthKitSampleIndexRecord, dayKeys: Set<String>)] = []
            var deletedTombstones: [HealthKitSampleIndexRecord] = []
            let availableDayKeys = Self.availableDayKeys(in: replacementsByDay)
            try forEachPendingHealthKitSampleIndex(stream: stream) { records in
                for record in records {
                    let pendingDayKeys = Self.pendingDayKeys(for: record)
                    let remainingDayKeys = pendingDayKeys.subtracting(availableDayKeys)
                    guard remainingDayKeys != pendingDayKeys else { continue }
                    if remainingDayKeys.isEmpty, record.isDeleted {
                        deletedTombstones.append(record)
                    } else {
                        pendingIndexUpdates.append((record: record, dayKeys: remainingDayKeys))
                    }
                }
            }
            // Finish paging before changing any indexed rows. Mutating a fetched page can shift
            // later offsets, and re-querying hundreds of UUIDs adds expensive SwiftData predicates.
            for update in pendingIndexUpdates {
                Self.setPendingDayKeys(update.dayKeys, on: update.record)
            }
            for record in deletedTombstones {
                modelContext.delete(record)
            }
            if let cursor = try cursorRecord(stream: stream) {
                cursor.anchorData = nextAnchorData
                cursor.lastSuccessfulAt = lastSuccessfulAt
                if cursor.lookbackStart == nil { cursor.lookbackStart = lookbackStart }
                cursor.updatedAt = Date()
            } else {
                modelContext.insert(HealthKitImportCursor(
                    stream: stream,
                    anchorData: nextAnchorData,
                    lastSuccessfulAt: lastSuccessfulAt,
                    lookbackStart: lookbackStart
                ))
            }
        }
    }

    func applyHealthAggregates(
        _ buckets: [HealthAggregateBucket],
        metric: HealthMetricID,
        stream: String,
        lookbackStart: Date,
        lastSuccessfulAt: Date = Date()
    ) throws {
        let calendar = Calendar.current
        let bucketsByDay = Dictionary(
            buckets.map { (calendar.startOfDay(for: $0.startDate), $0) },
            uniquingKeysWith: { _, newest in newest }
        )
        let days = Array(bucketsByDay.keys)
        let containsMeasuredValues = buckets.contains { $0.readState == .available && $0.value != nil }
        try write(affecting: days) { _ in
            for (day, bucket) in bucketsByDay {
                let value = bucket.value
                var snapshot = try healthSnapshot(for: day) ?? Self.emptyHealthSnapshot(for: day)
                var readStates = snapshot.healthReadStates ?? [:]
                readStates[metric.rawValue] = bucket.readState
                snapshot = Self.replacing(
                    snapshot,
                    activeEnergyKcal: metric == .activeEnergy && bucket.readState == .available && value != nil ? value : snapshot.activeEnergyKcal,
                    restingEnergyKcal: metric == .restingEnergy && bucket.readState == .available && value != nil ? value : snapshot.restingEnergyKcal,
                    stepCount: metric == .stepCount && bucket.readState == .available && value != nil ? value : snapshot.stepCount,
                    exerciseMinutes: metric == .exerciseMinutes && bucket.readState == .available && value != nil ? value : snapshot.exerciseMinutes,
                    healthReadStates: readStates
                )
                try upsertHealthSnapshot(snapshot, for: day)
            }
            if let cursor = try cursorRecord(stream: stream) {
                if cursor.lookbackStart == nil { cursor.lookbackStart = lookbackStart }
                if containsMeasuredValues { cursor.lastSuccessfulAt = lastSuccessfulAt }
                cursor.updatedAt = lastSuccessfulAt
            } else {
                modelContext.insert(HealthKitImportCursor(
                    stream: stream,
                    lastSuccessfulAt: containsMeasuredValues ? lastSuccessfulAt : nil,
                    lookbackStart: lookbackStart
                ))
            }
        }
    }

    private func apply(_ snapshot: WorkoutSnapshot, to workout: WorkoutRecord) {
        let resolvedEnergy = snapshot.resolvedEnergy
        workout.date = snapshot.startedAt
        workout.type = snapshot.activityType
        workout.durationMinutes = Int((snapshot.duration / 60).rounded())
        workout.estimatedCaloriesBurned = Int((resolvedEnergy?.kilocalories ?? 0).rounded())
        workout.healthKitUUID = snapshot.healthKitUUID
        workout.logicalSessionID = snapshot.logicalSessionID
        workout.workoutOrigin = snapshot.origin.rawValue
        workout.energySource = resolvedEnergy?.source.rawValue
        workout.sourceBundleIdentifier = snapshot.sourceBundleIdentifier
        workout.sourceVersion = snapshot.sourceVersion
        workout.sourceRevision = snapshot.sourceRevision
        workout.deviceName = snapshot.deviceName
        workout.deviceModel = snapshot.deviceModel
        workout.dataQuality = snapshot.dataQuality.rawValue
        workout.routeStatus = snapshot.routeStatus.rawValue
        workout.updatedAt = Date()
    }

    private func write(affecting dates: [Date], _ change: (inout Set<Date>) throws -> Void) throws {
        do {
            var affectedDates = Set(dates)
            try change(&affectedDates)
            for date in affectedDates {
                try DailyMetricsProjector.reproject(on: date, in: modelContext)
            }
            try willSave?()
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    private func enqueue(operation: String, recordID: UUID, syncType: String, receiptID: UUID? = nil) throws {
        let syncIdentifier = "densoso.\(syncType).\(recordID.uuidString.lowercased())"
        let expectedOperations: (upsert: String, delete: String)?
        switch syncType {
        case "meal": expectedOperations = ("upsertMeal", "deleteMeal")
        case "weight": expectedOperations = ("upsertWeight", "deleteWeight")
        default: expectedOperations = nil
        }

        var priorVersion = 0
        var linkedReceiptID = receiptID
        if let expectedOperations {
            let upsertOperation = expectedOperations.upsert
            let deleteOperation = expectedOperations.delete
            let versionPredicate = #Predicate<HealthSyncOutboxEntry> {
                $0.recordID == recordID
                    && ($0.operation == upsertOperation || $0.operation == deleteOperation)
            }
            var versionDescriptor = FetchDescriptor<HealthSyncOutboxEntry>(
                predicate: versionPredicate,
                sortBy: [SortDescriptor(\HealthSyncOutboxEntry.syncVersion, order: .reverse)]
            )
            versionDescriptor.fetchLimit = 1
            priorVersion = try modelContext.fetch(versionDescriptor).first?.syncVersion ?? 0

            if linkedReceiptID == nil {
                let receiptPredicate = #Predicate<HealthSyncOutboxEntry> {
                    $0.recordID == recordID
                        && ($0.operation == upsertOperation || $0.operation == deleteOperation)
                        && $0.receiptID != nil
                }
                var receiptDescriptor = FetchDescriptor<HealthSyncOutboxEntry>(
                    predicate: receiptPredicate,
                    sortBy: [
                        SortDescriptor(\HealthSyncOutboxEntry.syncVersion, order: .reverse),
                        SortDescriptor(\HealthSyncOutboxEntry.createdAt, order: .reverse),
                        SortDescriptor(\HealthSyncOutboxEntry.idempotencyKey, order: .reverse),
                    ]
                )
                receiptDescriptor.fetchLimit = 1
                linkedReceiptID = try modelContext.fetch(receiptDescriptor).first?.receiptID
            }
        }
        modelContext.insert(HealthSyncOutboxEntry(
            operation: operation,
            recordID: recordID,
            receiptID: linkedReceiptID,
            syncIdentifier: syncIdentifier,
            syncVersion: priorVersion + 1
        ))
    }

    static func canonicalSyncIdentifier(operation: String, recordID: UUID) -> String? {
        let normalizedOperation = operation.lowercased()
        let type: String
        if normalizedOperation.contains("meal") {
            type = "meal"
        } else if normalizedOperation.contains("weight") {
            type = "weight"
        } else {
            return nil
        }
        return "densoso.\(type).\(recordID.uuidString.lowercased())"
    }

    private func refreshDailyWeightSnapshot(on date: Date, excluding excludedWeightID: UUID? = nil) throws {
        let day = Calendar.current.startOfDay(for: date)
        var snapshot = try healthSnapshot(for: day) ?? Self.emptyHealthSnapshot(for: day)
        let localWeight = try latestLocalWeightKilograms(on: day, excluding: excludedWeightID)
        let bodyMassReadState = snapshot.healthReadStates?[HealthMetricID.bodyMass.rawValue]
        let candidateImportedWeight = snapshot.healthKitSampleSummary?.aggregate(for: .bodyMass)?.latestValue
        let importedWeight: Double?
        if (bodyMassReadState == nil || bodyMassReadState == .available),
           let candidateImportedWeight,
           candidateImportedWeight.isFinite,
           candidateImportedWeight > 0 {
            importedWeight = candidateImportedWeight
        } else {
            importedWeight = nil
        }
        snapshot = Self.replacing(snapshot, weightKilograms: .some(localWeight ?? importedWeight))
        try upsertHealthSnapshot(snapshot, for: day)
    }

    private func latestLocalWeightKilograms(on date: Date, excluding excludedWeightID: UUID? = nil) throws -> Double? {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: date)
        let nextDay = calendar.date(byAdding: .day, value: 1, to: day) ?? day
        let predicate: Predicate<WeightRecord>
        if let excludedWeightID {
            let excludedID = excludedWeightID
            predicate = #Predicate<WeightRecord> { record in
                record.measuredAt >= day && record.measuredAt < nextDay && record.id != excludedID
            }
        } else {
            predicate = #Predicate<WeightRecord> { record in
                record.measuredAt >= day && record.measuredAt < nextDay
            }
        }
        var descriptor = FetchDescriptor<WeightRecord>(
            predicate: predicate,
            sortBy: [
                SortDescriptor(\WeightRecord.measuredAt, order: .reverse),
                SortDescriptor(\WeightRecord.id, order: .reverse),
            ]
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first?.kilograms
    }

    private func workouts(on day: Date) throws -> [WorkoutRecord] {
        let end = Calendar.current.date(byAdding: .day, value: 1, to: day) ?? day
        let sortBy = [
            SortDescriptor(\WorkoutRecord.date),
            SortDescriptor(\WorkoutRecord.id),
        ]
        var cursor: (date: Date, id: UUID)?
        var workouts: [WorkoutRecord] = []
        while true {
            let predicate: Predicate<WorkoutRecord>
            if let cursor {
                let cursorDate = cursor.date
                let cursorID = cursor.id
                predicate = #Predicate<WorkoutRecord> { workout in
                    workout.date >= day && workout.date < end
                        && (workout.date > cursorDate
                            || (workout.date == cursorDate && workout.id > cursorID))
                }
            } else {
                predicate = #Predicate<WorkoutRecord> { $0.date >= day && $0.date < end }
            }
            var descriptor = FetchDescriptor<WorkoutRecord>(predicate: predicate, sortBy: sortBy)
            descriptor.fetchLimit = Self.workoutEffortFetchBatchSize
            let page = try modelContext.fetch(descriptor)
            guard let lastWorkout = page.last else { break }
            workouts.append(contentsOf: page)
            cursor = (date: lastWorkout.date, id: lastWorkout.id)
            if page.count < Self.workoutEffortFetchBatchSize { break }
        }
        return workouts
    }

    private func forEachPendingHealthKitSampleIndex(
        stream: String,
        _ body: ([HealthKitSampleIndexRecord]) throws -> Void
    ) throws {
        let sortBy = [SortDescriptor(\HealthKitSampleIndexRecord.sampleID)]
        var offset = 0
        while true {
            let predicate = #Predicate<HealthKitSampleIndexRecord> {
                $0.stream == stream && $0.needsRequery
            }
            var descriptor = FetchDescriptor<HealthKitSampleIndexRecord>(predicate: predicate, sortBy: sortBy)
            descriptor.fetchLimit = Self.healthKitSampleIndexBatchSize
            descriptor.fetchOffset = offset
            let records = try modelContext.fetch(descriptor)
            guard !records.isEmpty else { return }
            // Callers collect work here and mutate indexed rows only after traversal completes.
            try body(records)
            if records.count < Self.healthKitSampleIndexBatchSize { return }
            offset += records.count
        }
    }

    private func upsertHealthKitSampleIndexes(
        _ updates: [UUID: HealthKitSampleIndexUpdate],
        stream: String,
        replacementsByDay: [Date: HealthSampleDaySnapshot]
    ) throws {
        let orderedUpdates = updates.values.sorted {
            $0.sample.id.uuidString < $1.sample.id.uuidString
        }
        guard !orderedUpdates.isEmpty else { return }

        var existingByID: [UUID: HealthKitSampleIndexRecord] = [:]
        let sampleIDs = orderedUpdates.map { $0.sample.id }
        var offset = 0
        while offset < sampleIDs.count {
            let batchEnd = min(offset + Self.healthKitSampleIndexPredicateBatchSize, sampleIDs.count)
            let batchIDs = Array(sampleIDs[offset..<batchEnd])
            let predicate = #Predicate<HealthKitSampleIndexRecord> {
                batchIDs.contains($0.sampleID)
            }
            for record in try modelContext.fetch(FetchDescriptor<HealthKitSampleIndexRecord>(predicate: predicate)) {
                existingByID[record.sampleID] = record
            }
            offset = batchEnd
        }

        let availableDayKeys = Self.availableDayKeys(in: replacementsByDay)
        for update in orderedUpdates {
            let sample = update.sample
            let sampleID = sample.id
            let dayKey = Self.dayKey(for: sample.startDate)
            if let record = existingByID[sampleID] {
                let unresolvedDayKeys = Self.pendingDayKeys(for: record)
                    .union(Self.projectionDayKeys(for: record, stream: stream))
                    .union(Self.projectionDayKeys(for: sample, stream: stream))
                    .union(update.pendingDayKeys)
                    .subtracting(availableDayKeys)
                record.stream = stream
                record.dayKey = dayKey
                record.startDate = sample.startDate
                record.endDate = sample.endDate
                record.isDeleted = false
                Self.setPendingDayKeys(unresolvedDayKeys, on: record)
            } else {
                let unresolvedDayKeys = update.pendingDayKeys.subtracting(availableDayKeys)
                modelContext.insert(HealthKitSampleIndexRecord(
                    sampleID: sampleID,
                    stream: stream,
                    dayKey: dayKey,
                    startDate: sample.startDate,
                    endDate: sample.endDate,
                    needsRequery: !unresolvedDayKeys.isEmpty,
                    pendingDayKeys: Array(unresolvedDayKeys),
                    isDeleted: false
                ))
            }
        }
    }

    private func markHealthKitSampleIndexesForRequery(sampleIDs: Set<UUID>, stream: String) throws {
        guard !sampleIDs.isEmpty else { return }
        var offset = 0
        let orderedIDs = sampleIDs.sorted { $0.uuidString < $1.uuidString }
        while offset < orderedIDs.count {
            let batchEnd = min(offset + Self.healthKitSampleIndexPredicateBatchSize, orderedIDs.count)
            let batchIDs = Array(orderedIDs[offset..<batchEnd])
            let predicate = #Predicate<HealthKitSampleIndexRecord> {
                $0.stream == stream && batchIDs.contains($0.sampleID)
            }
            let records = try modelContext.fetch(FetchDescriptor<HealthKitSampleIndexRecord>(predicate: predicate))
            // Keep each UUID predicate bounded and mutate only the exact deletion targets.
            for record in records {
                let pendingDayKeys = Self.pendingDayKeys(for: record)
                    .union(Self.projectionDayKeys(for: record, stream: stream))
                Self.setPendingDayKeys(pendingDayKeys, on: record)
                record.isDeleted = true
            }
            offset = batchEnd
        }
    }

    private func healthSnapshot(for day: Date) throws -> DailyHealthSnapshot? {
        let dayKey = Self.dayKey(for: day)
        guard let record = try healthSnapshotRecord(dayKey: dayKey) else { return nil }
        return try Self.decodeHealthSnapshot(record.payloadData, decoder: JSONDecoder())
    }

    private func upsertHealthSnapshot(_ snapshot: DailyHealthSnapshot, for day: Date) throws {
        let dayKey = Self.dayKey(for: day)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let payloadData = try encoder.encode(snapshot)
        let hash = SHA256.hash(data: payloadData).map { String(format: "%02x", $0) }.joined()
        if let record = try healthSnapshotRecord(dayKey: dayKey) {
            record.timezoneID = snapshot.timezoneIdentifier
            record.payloadData = payloadData
            record.snapshotHash = hash
            record.algorithmVersion = snapshot.algorithmVersion
        } else {
            modelContext.insert(DailyHealthSnapshotRecord(
                dayKey: dayKey,
                timezoneID: snapshot.timezoneIdentifier,
                payloadData: payloadData,
                snapshotHash: hash,
                algorithmVersion: snapshot.algorithmVersion
            ))
        }
    }

    private func healthSnapshotRecord(dayKey: String) throws -> DailyHealthSnapshotRecord? {
        let predicate = #Predicate<DailyHealthSnapshotRecord> { $0.dayKey == dayKey }
        var descriptor = FetchDescriptor<DailyHealthSnapshotRecord>(predicate: predicate)
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func cursorRecord(stream: String) throws -> HealthKitImportCursor? {
        let predicate = #Predicate<HealthKitImportCursor> { $0.stream == stream }
        var descriptor = FetchDescriptor<HealthKitImportCursor>(predicate: predicate)
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private static func decodeHealthSnapshot(_ data: Data, decoder: JSONDecoder) throws -> DailyHealthSnapshot {
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(DailyHealthSnapshot.self, from: data)
    }

    private static func dayKey(for date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    private static func date(fromDayKey key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    private static func sleepWakeDays(startDate: Date, endDate: Date) -> Set<Date> {
        guard startDate.timeIntervalSince1970.isFinite,
              endDate.timeIntervalSince1970.isFinite,
              endDate > startDate else { return [] }
        let calendar = Calendar.current
        let firstDay = calendar.startOfDay(for: startDate)
        let lastDay = calendar.startOfDay(for: endDate)
        guard let dayCount = calendar.dateComponents([.day], from: firstDay, to: lastDay).day,
              dayCount >= 0,
              dayCount <= 366 else { return [] }
        var affected = Set<Date>()
        for offset in 0...dayCount {
            guard let wakeDay = calendar.date(byAdding: .day, value: offset, to: firstDay),
                  let previousDay = calendar.date(byAdding: .day, value: -1, to: wakeDay),
                  let windowStart = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: previousDay),
                  let windowEnd = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: wakeDay) else {
                continue
            }
            if endDate > windowStart && startDate < windowEnd { affected.insert(wakeDay) }
        }
        return affected
    }

    private static func sampleProjectionDays(for sample: HealthSampleSnapshot, stream: String) -> Set<Date> {
        if stream == HealthMetricID.sleepAnalysis.rawValue {
            return sleepWakeDays(startDate: sample.startDate, endDate: sample.endDate)
        }
        return [Calendar.current.startOfDay(for: sample.startDate)]
    }

    private static func unresolvedDayKeys(
        for sample: HealthSampleSnapshot,
        stream: String,
        replacementsByDay: [Date: HealthSampleDaySnapshot]
    ) -> Set<String> {
        let days = sampleProjectionDays(for: sample, stream: stream)
        guard !days.isEmpty else { return [dayKey(for: sample.startDate)] }
        return Set(days.filter { replacementsByDay[$0]?.readState != .available }.map { dayKey(for: $0) })
    }

    private static func projectionDayKeys(for sample: HealthSampleSnapshot, stream: String) -> Set<String> {
        let days = sampleProjectionDays(for: sample, stream: stream)
        guard !days.isEmpty else { return [dayKey(for: sample.startDate)] }
        return Set(days.map { dayKey(for: $0) })
    }

    private static func projectionDayKeys(for record: HealthKitSampleIndexRecord, stream: String) -> Set<String> {
        let days: Set<Date>
        if stream == HealthMetricID.sleepAnalysis.rawValue {
            days = sleepWakeDays(startDate: record.startDate, endDate: record.endDate)
        } else if let day = date(fromDayKey: record.dayKey) {
            days = [day]
        } else {
            days = []
        }
        guard !days.isEmpty else { return [record.dayKey] }
        return Set(days.map { dayKey(for: $0) })
    }

    private static func indexedProjectionDays(for record: HealthKitSampleIndexRecord, stream: String) -> Set<Date> {
        let projectionDayKeys = projectionDayKeys(for: record, stream: stream)
        let keys = pendingDayKeys(for: record).union(projectionDayKeys)
        return Set(keys.compactMap { date(fromDayKey: $0) })
    }

    private static func pendingDays(for record: HealthKitSampleIndexRecord) -> Set<Date> {
        let keys = pendingDayKeys(for: record)
        return Set(keys.compactMap { date(fromDayKey: $0) })
    }

    private static func pendingDayKeys(for record: HealthKitSampleIndexRecord) -> Set<String> {
        let data = Data(record.pendingDayKeysJSON.utf8)
        if let keys = try? JSONDecoder().decode([String].self, from: data), !keys.isEmpty {
            return Set(keys)
        }
        guard record.needsRequery else { return [] }
        return projectionDayKeys(for: record, stream: record.stream)
    }

    private static func setPendingDayKeys(_ keys: Set<String>, on record: HealthKitSampleIndexRecord) {
        let sortedKeys = keys.sorted()
        if let data = try? JSONEncoder().encode(sortedKeys),
           let encoded = String(data: data, encoding: .utf8) {
            record.pendingDayKeysJSON = encoded
        } else {
            record.pendingDayKeysJSON = "[]"
        }
        record.needsRequery = !sortedKeys.isEmpty
    }

    private static func availableDayKeys(
        in replacementsByDay: [Date: HealthSampleDaySnapshot]
    ) -> Set<String> {
        Set(replacementsByDay.compactMap { entry in
            entry.value.readState == .available ? dayKey(for: entry.key) : nil
        })
    }

    private static func emptyHealthSnapshot(for day: Date) -> DailyHealthSnapshot {
        DailyHealthSnapshot(
            dayStart: day,
            timezoneIdentifier: Calendar.current.timeZone.identifier,
            algorithmVersion: DailyHealthSnapshot.currentAlgorithmVersion
        )
    }

    private static func replacing(
        _ source: DailyHealthSnapshot,
        activeEnergyKcal: Double?? = nil,
        restingEnergyKcal: Double?? = nil,
        stepCount: Double?? = nil,
        exerciseMinutes: Double?? = nil,
        weightKilograms: Double?? = nil,
        healthKitSamples: [HealthSampleSnapshot]?? = nil,
        healthKitSampleSummary: DailyHealthSampleSummary?? = nil,
        healthReadStates: [String: HealthReadState]?? = nil
    ) -> DailyHealthSnapshot {
        DailyHealthSnapshot(
            dayStart: source.dayStart,
            timezoneIdentifier: source.timezoneIdentifier,
            energyIntakeKcal: source.energyIntakeKcal,
            activeEnergyKcal: activeEnergyKcal ?? source.activeEnergyKcal,
            restingEnergyKcal: restingEnergyKcal ?? source.restingEnergyKcal,
            stepCount: stepCount ?? source.stepCount,
            exerciseMinutes: exerciseMinutes ?? source.exerciseMinutes,
            weightKilograms: weightKilograms ?? source.weightKilograms,
            healthKitSamples: healthKitSamples ?? source.healthKitSamples,
            healthKitSampleSummary: healthKitSampleSummary ?? source.healthKitSampleSummary,
            healthReadStates: healthReadStates ?? source.healthReadStates,
            algorithmVersion: DailyHealthSnapshot.currentAlgorithmVersion
        )
    }
}

enum HealthRepositoryError: Equatable, SharedErrorDescribing {
    case missingHealthKitAnchor
    case refuseHealthKitEcho

    var sharedErrorDescriptor: SharedErrorDescriptor {
        switch self {
        case .missingHealthKitAnchor:
            SharedErrorDescriptor(
                code: .healthKitUnavailable,
                userMessage: "暂时没能更新今天的状态。",
                subsystem: .healthKit,
                reason: .missingHealthKitAnchor
            )
        case .refuseHealthKitEcho:
            SharedErrorDescriptor(
                code: .actionConflict,
                userMessage: "该健康数据操作暂时无法完成。",
                subsystem: .healthKit,
                reason: .refusedHealthKitEcho
            )
        }
    }
}

struct HealthKitCursorSnapshot: Sendable {
    let anchorData: Data?
    let lastSuccessfulAt: Date?
    let lookbackStart: Date?
}
