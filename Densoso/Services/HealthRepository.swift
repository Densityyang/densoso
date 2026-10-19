import Foundation
import CryptoKit
import SwiftData
import DensosoDomain

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
            let workouts = try modelContext.fetch(FetchDescriptor<WorkoutRecord>())
            var workoutsByHealthKitUUID: [UUID: WorkoutRecord] = [:]
            for workout in workouts.sorted(by: {
                $0.createdAt == $1.createdAt
                    ? $0.id.uuidString < $1.id.uuidString
                    : $0.createdAt < $1.createdAt
            }) {
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

            for healthKitUUID in deletedHealthKitUUIDs {
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

    func applyImportedHealthSamples(
        _ page: HealthSamplePage,
        stream: String,
        lastSuccessfulAt: Date = Date(),
        lookbackStart: Date? = nil
    ) throws {
        guard let nextAnchorData = page.nextAnchorData else {
            throw HealthRepositoryError.missingHealthKitAnchor
        }

        let calendar = Calendar.current
        let records = try modelContext.fetch(FetchDescriptor<DailyHealthSnapshotRecord>())
        var snapshotsByDay: [Date: DailyHealthSnapshot] = [:]
        for record in records {
            if let snapshot = try? Self.decodeHealthSnapshot(record.payloadData, decoder: JSONDecoder()) {
                snapshotsByDay[calendar.startOfDay(for: snapshot.dayStart)] = snapshot
            }
        }

        var affectedDays = Set<Date>()
        var samplesByDay: [Date: [UUID: HealthSampleSnapshot]] = [:]
        var dayBySampleID: [UUID: Date] = [:]
        for day in snapshotsByDay.keys.sorted() {
            for sample in (snapshotsByDay[day]?.healthKitSamples ?? []).sorted(by: { $0.startDate < $1.startDate }) {
                if let duplicateDay = dayBySampleID[sample.id] {
                    samplesByDay[duplicateDay]?.removeValue(forKey: sample.id)
                    affectedDays.insert(duplicateDay)
                }
                samplesByDay[day, default: [:]][sample.id] = sample
                dayBySampleID[sample.id] = day
            }
        }

        for sampleID in page.deletedSampleIDs {
            guard let day = dayBySampleID.removeValue(forKey: sampleID) else { continue }
            samplesByDay[day]?.removeValue(forKey: sampleID)
            affectedDays.insert(day)
        }

        for sample in page.samples {
            if let previousDay = dayBySampleID[sample.id] {
                samplesByDay[previousDay]?.removeValue(forKey: sample.id)
                affectedDays.insert(previousDay)
            }
            let day = calendar.startOfDay(for: sample.startDate)
            samplesByDay[day, default: [:]][sample.id] = sample
            dayBySampleID[sample.id] = day
            affectedDays.insert(day)
        }

        for day in affectedDays {
            let snapshot = snapshotsByDay[day] ?? Self.emptyHealthSnapshot(for: day)
            let samples = (samplesByDay[day] ?? [:]).values.sorted { $0.startDate < $1.startDate }
            var readStates = snapshot.healthReadStates ?? [:]
            readStates[stream] = page.readState
            snapshotsByDay[day] = Self.replacing(
                snapshot,
                healthKitSamples: samples,
                healthReadStates: readStates
            )
        }

        for day in affectedDays {
            guard let snapshot = snapshotsByDay[day] else { continue }
            let healthKitWeight = (snapshot.healthKitSamples ?? [])
                .filter { $0.metric == .bodyMass }
                .max { $0.endDate < $1.endDate }?.value
            let endOfDay = calendar.date(byAdding: .day, value: 1, to: day) ?? day
            let localWeight = try modelContext.fetch(FetchDescriptor<WeightRecord>())
                .filter { $0.measuredAt >= day && $0.measuredAt < endOfDay }
                .max { $0.measuredAt < $1.measuredAt }?.kilograms
            // Double?? distinguishes "leave unchanged" from "clear the projection".
            // Wrap the computed optional explicitly so a missing local value still
            // updates the projection from imported HealthKit samples (or clears it).
            snapshotsByDay[day] = Self.replacing(snapshot, weightKilograms: .some(localWeight ?? healthKitWeight))
        }

        try write(affecting: Array(affectedDays)) { _ in
            for day in affectedDays {
                if let snapshot = snapshotsByDay[day] {
                    try upsertHealthSnapshot(snapshot, for: day)
                }
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
        let localWeight = try modelContext.fetch(FetchDescriptor<WeightRecord>())
            .filter { record in
                if let excludedWeightID, record.id == excludedWeightID { return false }
                return record.measuredAt >= day && record.measuredAt < nextDay
            }
            .max { $0.measuredAt < $1.measuredAt }?.kilograms
        let importedWeight = (snapshot.healthKitSamples ?? [])
            .filter { $0.metric == .bodyMass }
            .max { $0.endDate < $1.endDate }?.value
        snapshot = Self.replacing(snapshot, weightKilograms: .some(localWeight ?? importedWeight))
        try upsertHealthSnapshot(snapshot, for: day)
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

    private static func emptyHealthSnapshot(for day: Date) -> DailyHealthSnapshot {
        DailyHealthSnapshot(
            dayStart: day,
            timezoneIdentifier: Calendar.current.timeZone.identifier,
            algorithmVersion: "v3"
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
            healthReadStates: healthReadStates ?? source.healthReadStates,
            algorithmVersion: source.algorithmVersion
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
