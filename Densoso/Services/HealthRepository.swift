import Foundation
import CryptoKit
import SwiftData
import DensosoDomain

private struct HealthKitSampleIndexUpdate {
    let sample: HealthSampleSnapshot
    let needsRequery: Bool
}

/// Coordinates local health-record writes and their derived daily metrics.
/// SwiftData persists both the source change and its projection with one save.
@MainActor
final class HealthRepository: HealthSyncRepository {
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
            let importedWorkouts = try modelContext.fetch(
                FetchDescriptor<WorkoutRecord>(predicate: importedPredicate)
            )
            var workoutsByHealthKitUUID: [UUID: WorkoutRecord] = [:]
            // Keep the global one-record-per-HealthKit-UUID invariant while
            // avoiding materializing local workouts that have no HealthKit ID.
            for workout in importedWorkouts.sorted(by: Self.preferredImportedWorkout) {
                guard let healthKitUUID = workout.healthKitUUID else { continue }
                if workoutsByHealthKitUUID[healthKitUUID] == nil {
                    workoutsByHealthKitUUID[healthKitUUID] = workout
                } else {
                    affectedDates.insert(workout.date)
                    modelContext.delete(workout)
                }
            }

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
            let batchSize = 400
            var offset = 0
            while offset < requestedIDs.count {
                let batchEnd = min(offset + batchSize, requestedIDs.count)
                let sampleIDs = Array(requestedIDs[offset..<batchEnd])
                let predicate = #Predicate<HealthKitSampleIndexRecord> {
                    $0.stream == stream && sampleIDs.contains($0.sampleID)
                }
                for record in try modelContext.fetch(FetchDescriptor<HealthKitSampleIndexRecord>(predicate: predicate)) {
                    if stream == HealthMetricID.sleepAnalysis.rawValue {
                        days.formUnion(Self.sleepWakeDays(startDate: record.startDate, endDate: record.endDate))
                    } else if let day = Self.date(fromDayKey: record.dayKey) {
                        days.insert(day)
                    }
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
        let pendingPredicate = #Predicate<HealthKitSampleIndexRecord> {
            $0.stream == stream && $0.needsRequery
        }
        for record in try modelContext.fetch(FetchDescriptor<HealthKitSampleIndexRecord>(predicate: pendingPredicate)) {
            if stream == HealthMetricID.sleepAnalysis.rawValue {
                days.formUnion(Self.sleepWakeDays(startDate: record.startDate, endDate: record.endDate))
            } else if let day = Self.date(fromDayKey: record.dayKey) {
                days.insert(day)
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
                    let nextDay = calendar.date(byAdding: .day, value: 1, to: day) ?? day
                    let localWeightPredicate = #Predicate<WeightRecord> {
                        $0.measuredAt >= day && $0.measuredAt < nextDay
                    }
                    let localWeight = try modelContext.fetch(
                        FetchDescriptor<WeightRecord>(predicate: localWeightPredicate)
                    ).max { $0.measuredAt < $1.measuredAt }?.kilograms
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
            try markHealthKitSampleIndexesForRequery(
                sampleIDs: Set(page.deletedSampleIDs),
                stream: stream
            )
            var sampleIndexUpdates: [UUID: HealthKitSampleIndexUpdate] = [:]
            for sample in page.samples where sample.metric.rawValue == stream {
                let requiredDays = Self.sampleProjectionDays(for: sample, stream: stream)
                let needsRequery = requiredDays.isEmpty || !requiredDays.allSatisfy {
                    replacementsByDay[$0]?.readState == .available
                }
                sampleIndexUpdates[sample.id] = HealthKitSampleIndexUpdate(
                    sample: sample,
                    needsRequery: needsRequery
                )
            }
            for replacement in replacements {
                for sample in replacement.samples where sample.metric.rawValue == stream {
                    let requiredDays = Self.sampleProjectionDays(for: sample, stream: stream)
                    sampleIndexUpdates[sample.id] = HealthKitSampleIndexUpdate(
                        sample: sample,
                        needsRequery: requiredDays.isEmpty || !requiredDays.allSatisfy {
                            replacementsByDay[$0]?.readState == .available
                        }
                    )
                }
            }
            try upsertHealthKitSampleIndexes(sampleIndexUpdates, stream: stream)
            let pendingPredicate = #Predicate<HealthKitSampleIndexRecord> {
                $0.stream == stream && $0.needsRequery
            }
            let pendingRecords = try modelContext.fetch(
                FetchDescriptor<HealthKitSampleIndexRecord>(predicate: pendingPredicate)
            )
            for record in pendingRecords {
                let requiredDays = stream == HealthMetricID.sleepAnalysis.rawValue
                    ? Self.sleepWakeDays(startDate: record.startDate, endDate: record.endDate)
                    : Set([Self.date(fromDayKey: record.dayKey)].compactMap { $0 })
                guard !requiredDays.isEmpty,
                      requiredDays.allSatisfy({ replacementsByDay[$0]?.readState == .available }) else {
                    continue
                }
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
        let normalizedBuckets = Dictionary(
            buckets.map { (calendar.startOfDay(for: $0.startDate), $0.value) },
            uniquingKeysWith: { _, newest in newest }
        )
        let days = Array(normalizedBuckets.keys)
        let containsMeasuredValues = buckets.contains { $0.readState == .available && $0.value != nil }
        try write(affecting: days) { _ in
            for (day, value) in normalizedBuckets {
                guard let bucket = buckets.last(where: { calendar.startOfDay(for: $0.startDate) == day }) else {
                    continue
                }
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
        let priorEntries = try modelContext.fetch(FetchDescriptor<HealthSyncOutboxEntry>())
            .filter { existing in
                guard let canonical = Self.canonicalSyncIdentifier(
                    operation: existing.operation,
                    recordID: existing.recordID
                ) else { return false }
                return canonical == syncIdentifier
            }
        let priorVersion = priorEntries
            .map(\.syncVersion)
            .max() ?? 0
        let linkedReceiptID = receiptID ?? priorEntries
            .filter { $0.receiptID != nil }
            .max(by: { $0.syncVersion < $1.syncVersion })?.receiptID
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
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: date)
        let nextDay = calendar.date(byAdding: .day, value: 1, to: day) ?? day
        var snapshot = try healthSnapshot(for: day) ?? Self.emptyHealthSnapshot(for: day)
        let weightPredicate = #Predicate<WeightRecord> {
            $0.measuredAt >= day && $0.measuredAt < nextDay
        }
        let localWeight = try modelContext.fetch(FetchDescriptor<WeightRecord>(predicate: weightPredicate))
            .filter { excludedWeightID == nil || $0.id != excludedWeightID }
            .max { $0.measuredAt < $1.measuredAt }?.kilograms
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

    private func workouts(on day: Date) throws -> [WorkoutRecord] {
        let end = Calendar.current.date(byAdding: .day, value: 1, to: day) ?? day
        let predicate = #Predicate<WorkoutRecord> { $0.date >= day && $0.date < end }
        return try modelContext.fetch(FetchDescriptor<WorkoutRecord>(predicate: predicate))
    }

    private func upsertHealthKitSampleIndexes(
        _ updates: [UUID: HealthKitSampleIndexUpdate],
        stream: String
    ) throws {
        let orderedUpdates = updates.values.sorted {
            $0.sample.id.uuidString < $1.sample.id.uuidString
        }
        guard !orderedUpdates.isEmpty else { return }

        var existingByID: [UUID: HealthKitSampleIndexRecord] = [:]
        let sampleIDs = orderedUpdates.map { $0.sample.id }
        let batchSize = 400
        var offset = 0
        while offset < sampleIDs.count {
            let batchEnd = min(offset + batchSize, sampleIDs.count)
            let batchIDs = Array(sampleIDs[offset..<batchEnd])
            let predicate = #Predicate<HealthKitSampleIndexRecord> {
                batchIDs.contains($0.sampleID)
            }
            for record in try modelContext.fetch(FetchDescriptor<HealthKitSampleIndexRecord>(predicate: predicate)) {
                existingByID[record.sampleID] = record
            }
            offset = batchEnd
        }

        for update in orderedUpdates {
            let sample = update.sample
            let sampleID = sample.id
            let dayKey = Self.dayKey(for: sample.startDate)
            if let record = existingByID[sampleID] {
                record.stream = stream
                record.dayKey = dayKey
                record.startDate = sample.startDate
                record.endDate = sample.endDate
                record.needsRequery = update.needsRequery
            } else {
                modelContext.insert(HealthKitSampleIndexRecord(
                    sampleID: sampleID,
                    stream: stream,
                    dayKey: dayKey,
                    startDate: sample.startDate,
                    endDate: sample.endDate,
                    needsRequery: update.needsRequery
                ))
            }
        }
    }

    private func markHealthKitSampleIndexesForRequery(sampleIDs: Set<UUID>, stream: String) throws {
        let orderedIDs = sampleIDs.sorted { $0.uuidString < $1.uuidString }
        let batchSize = 400
        var offset = 0
        while offset < orderedIDs.count {
            let batchEnd = min(offset + batchSize, orderedIDs.count)
            let batchIDs = Array(orderedIDs[offset..<batchEnd])
            let predicate = #Predicate<HealthKitSampleIndexRecord> {
                $0.stream == stream && batchIDs.contains($0.sampleID)
            }
            let records = try modelContext.fetch(FetchDescriptor<HealthKitSampleIndexRecord>(predicate: predicate))
            for record in records { record.needsRequery = true }
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

enum HealthRepositoryError: Error, Equatable {
    case missingHealthKitAnchor
    case refuseHealthKitEcho
}

struct HealthKitCursorSnapshot: Sendable {
    let anchorData: Data?
    let lastSuccessfulAt: Date?
    let lookbackStart: Date?
}
