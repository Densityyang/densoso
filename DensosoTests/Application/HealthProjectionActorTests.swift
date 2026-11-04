import DensosoDomain
import Dispatch
import Foundation
import SwiftData
import XCTest
@testable import Densoso

@MainActor
final class HealthProjectionActorTests: XCTestCase {
    func testStateRefreshReportsP50P95ForFortyTwoDayLocalDataWindow() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let reference = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 12)))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("densoso-health-refresh-perf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let storeURL = directory.appendingPathComponent("default.store")
        let schema = Schema(versionedSchema: DensosoSchemaV9.self)
        let configuration = ModelConfiguration("HealthStatePerformance", schema: schema, url: storeURL)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970

        for offset in -41...0 {
            let day = try XCTUnwrap(calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: reference)))
            let snapshot = DailyHealthSnapshot(
                dayStart: day,
                timezoneIdentifier: calendar.timeZone.identifier,
                activeEnergyKcal: 480 + Double(offset + 41),
                restingEnergyKcal: 1_400,
                stepCount: 5_000 + Double((offset + 41) * 37),
                exerciseMinutes: 25,
                healthReadStates: [
                    HealthMetricID.activeEnergy.rawValue: .available,
                    HealthMetricID.restingEnergy.rawValue: .available,
                    HealthMetricID.stepCount.rawValue: .available,
                    HealthMetricID.exerciseMinutes.rawValue: .available,
                ],
                algorithmVersion: DailyHealthSnapshot.currentAlgorithmVersion
            )
            context.insert(DailyHealthSnapshotRecord(
                dayKey: dayKey(day, calendar: calendar),
                timezoneID: calendar.timeZone.identifier,
                payloadData: try encoder.encode(snapshot),
                snapshotHash: "health-refresh-perf-\(offset)",
                algorithmVersion: DailyHealthSnapshot.currentAlgorithmVersion
            ))
            let metric = DailyMetrics(
                date: day,
                totalExpenditureKcal: 1_880,
                mealCount: 0,
                energyQuality: "observed",
                projectionVersion: AlgorithmVersions.dailyMetricsProjection,
                sourceFingerprint: "health-refresh-perf-metrics-\(offset)"
            )
            // DailyMetrics normalizes using Calendar.current; align it to this
            // fixture's UTC key before inserting so the query window is stable.
            metric.date = day
            context.insert(metric)
        }
        try context.save()

        let service = HealthIntelligenceService(modelContainer: container, calendar: calendar)
        let warmupCount = 3
        let sampleCount = 20
        for _ in 0..<warmupCount {
            let brief = try await service.refresh(asOf: reference)
            XCTAssertNotNil(brief)
        }

        var durationsNanoseconds: [UInt64] = []
        durationsNanoseconds.reserveCapacity(sampleCount)
        for _ in 0..<sampleCount {
            let startedAt = DispatchTime.now().uptimeNanoseconds
            let brief = try await service.refresh(asOf: reference)
            durationsNanoseconds.append(DispatchTime.now().uptimeNanoseconds - startedAt)
            XCTAssertNotNil(brief)
        }

        let sortedDurations = durationsNanoseconds.sorted()
        let p50 = sortedDurations[(sampleCount - 1) * 50 / 100]
        let p95 = sortedDurations[(sampleCount * 95 + 99) / 100 - 1]
        let environment = ProcessInfo.processInfo.environment
        print(
            "DENSOSO_PERF scenario=health_state_refresh "
                + "device=\(environment["SIMULATOR_DEVICE_NAME"] ?? "iPhone 17 Pro (Gate 11 destination)") "
                + "model=\(environment["SIMULATOR_MODEL_IDENTIFIER"] ?? "iPhone 17 Pro destination") "
                + "os=\(ProcessInfo.processInfo.operatingSystemVersionString) "
                + "dailyMetrics=42 snapshots=42 warmups=\(warmupCount) samples=\(sampleCount) "
                + "p50_ms=\(Double(p50) / 1_000_000) p95_ms=\(Double(p95) / 1_000_000)"
        )
        XCTAssertLessThan(p95, 1_000_000_000, "42-day local health-state refresh p95 exceeded 1 second")
    }

    func testDailyProjectionRunsOffMainActorForFortyTwoDaysAndReportsP50P95() async throws {
        var calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let firstDay = try XCTUnwrap(calendar.date(byAdding: .day, value: -41, to: today))
        let schema = Schema(versionedSchema: DensosoSchemaV4.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        let days = try (0..<42).map { offset in
            try XCTUnwrap(calendar.date(byAdding: .day, value: offset, to: firstDay))
        }

        for (dayIndex, day) in days.enumerated() {
            for mealIndex in 0..<24 {
                context.insert(MealRecord(
                    date: day.addingTimeInterval(Double(mealIndex) * 60),
                    mealType: "lunch",
                    totalCaloriesKcal: 280 + mealIndex,
                    proteinG: 18,
                    fatG: 9,
                    carbsG: 31,
                    sourceActionKey: "projection-perf-\(dayIndex)-\(mealIndex)"
                ))
            }
        }
        try context.save()

        var projectionStarted = false
        var projectionFinished = false
        var durationsNanoseconds: [UInt64] = []
        let responsivenessProbe = Task { @MainActor in
            while !projectionStarted && !projectionFinished {
                await Task.yield()
            }
            return projectionStarted && !projectionFinished
        }
        let projectionTask = Task { @MainActor in
            projectionStarted = true
            defer { projectionFinished = true }
            for day in days {
                let startedAt = DispatchTime.now().uptimeNanoseconds
                try await DailyMetricsProjector.reproject(on: day, in: context)
                durationsNanoseconds.append(DispatchTime.now().uptimeNanoseconds - startedAt)
            }
        }

        try await projectionTask.value
        let actorResumedDuringProjection = await responsivenessProbe.value
        XCTAssertTrue(actorResumedDuringProjection, "Projection calculation blocked MainActor instead of yielding to the detached worker")
        let projectedMetrics = try context.fetch(FetchDescriptor<DailyMetrics>())
        XCTAssertEqual(projectedMetrics.count, 42)
        XCTAssertTrue(projectedMetrics.allSatisfy { $0.mealCount == 24 })

        let sortedDurations = durationsNanoseconds.sorted()
        let p50 = sortedDurations[(sortedDurations.count - 1) * 50 / 100]
        let p95 = sortedDurations[(sortedDurations.count * 95 + 99) / 100 - 1]
        let environment = ProcessInfo.processInfo.environment
        print(
            "DENSOSO_PERF scenario=daily_projection_42_days "
                + "device=\(environment["SIMULATOR_DEVICE_NAME"] ?? "GitHub Actions simulator") "
                + "model=\(environment["SIMULATOR_MODEL_IDENTIFIER"] ?? "CI destination") "
                + "os=\(ProcessInfo.processInfo.operatingSystemVersionString) "
                + "days=42 mealsPerDay=24 p50_ms=\(Double(p50) / 1_000_000) "
                + "p95_ms=\(Double(p95) / 1_000_000)"
        )
        XCTAssertLessThan(p95, 1_000_000_000, "42-day daily projection p95 exceeded 1 second")
    }

    func testOverlappingRepositoryInsertsShareOneContextAndPersistCombinedProjection() async throws {
        let schema = Schema(versionedSchema: DensosoSchemaV4.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        let repository = HealthRepository(modelContext: context)
        let day = Calendar.current.startOfDay(for: Date())
        let currentMealEvidence = try JSONEncoder().encode([
            EvidenceSnapshot(
                grade: .userReported,
                sourceID: "projection-gate-test",
                summary: "Explicit evidence for the projection concurrency fixture."
            ),
        ])
        let firstMeal = MealRecord(
            date: day.addingTimeInterval(9 * 60 * 60),
            mealType: "breakfast",
            totalCaloriesKcal: 420,
            proteinG: 24,
            fatG: 12,
            carbsG: 52,
            sourceActionKey: "projection-gate-first-meal",
            evidenceData: currentMealEvidence
        )
        let secondMeal = MealRecord(
            date: day.addingTimeInterval(13 * 60 * 60),
            mealType: "lunch",
            totalCaloriesKcal: 280,
            proteinG: 18,
            fatG: 9,
            carbsG: 31,
            sourceActionKey: "projection-gate-second-meal",
            evidenceData: currentMealEvidence
        )

        let firstInsert = Task { @MainActor in try await repository.insert(firstMeal) }
        let secondInsert = Task { @MainActor in try await repository.insert(secondMeal) }
        try await firstInsert.value
        try await secondInsert.value

        let meals = try context.fetch(FetchDescriptor<MealRecord>())
        let metrics = try XCTUnwrap(context.fetch(FetchDescriptor<DailyMetrics>()).first)
        XCTAssertEqual(meals.count, 2)
        XCTAssertEqual(metrics.mealCount, 2)
        XCTAssertEqual(metrics.totalIntakeKcal, 700)
        XCTAssertFalse(metrics.requiresRecompute)
    }

    func testTodayNarrativeAndBoundedHistoryShareDeterministicReadModelWithoutCacheWrites() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let today = calendar.startOfDay(for: Date())
        let start = try XCTUnwrap(calendar.date(byAdding: .day, value: -2, to: today))
        let schema = Schema(versionedSchema: DensosoSchemaV4.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970

        for offset in -41...2 {
            let day = try XCTUnwrap(calendar.date(byAdding: .day, value: offset, to: start))
            let snapshot = DailyHealthSnapshot(
                dayStart: day,
                timezoneIdentifier: calendar.timeZone.identifier,
                stepCount: Double(5_000 + offset + 41),
                healthReadStates: [HealthMetricID.stepCount.rawValue: .available],
                algorithmVersion: DailyHealthSnapshot.currentAlgorithmVersion
            )
            context.insert(DailyHealthSnapshotRecord(
                dayKey: dayKey(day, calendar: calendar),
                timezoneID: snapshot.timezoneIdentifier,
                payloadData: try encoder.encode(snapshot),
                snapshotHash: "projection-actor-\(offset)",
                algorithmVersion: snapshot.algorithmVersion
            ))
        }
        let futureDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: today))
        let futureSnapshot = DailyHealthSnapshot(
            dayStart: futureDay,
            timezoneIdentifier: calendar.timeZone.identifier,
            stepCount: 99_999,
            healthReadStates: [HealthMetricID.stepCount.rawValue: .available],
            algorithmVersion: "outside-query-window"
        )
        context.insert(DailyHealthSnapshotRecord(
            dayKey: dayKey(futureDay, calendar: calendar),
            timezoneID: futureSnapshot.timezoneIdentifier,
            payloadData: try encoder.encode(futureSnapshot),
            snapshotHash: "outside-query-window",
            algorithmVersion: futureSnapshot.algorithmVersion
        ))
        try context.save()

        let actor = HealthProjectionActor(modelContainer: container, calendar: calendar)
        let service = HealthIntelligenceService(modelContainer: container, calendar: calendar)
        let beforeDailyBriefs = try context.fetchCount(FetchDescriptor<DailyBriefRecord>())
        let beforeWeeklyBriefs = try context.fetchCount(FetchDescriptor<WeeklyBriefRecord>())

        let actorState = try await actor.todayHealthState(asOf: today)
        let narrativeContext = try await actor.healthNarrativeContext(asOf: today)
        let actorHistory = try await actor.healthHistory(from: start, through: today)
        let serviceHistory = try await service.healthHistory(from: start, through: today)

        XCTAssertNotNil(actorState)
        XCTAssertEqual(narrativeContext.healthState, actorState)
        XCTAssertNotNil(narrativeContext.aggregateSummary)
        XCTAssertEqual(actorHistory, serviceHistory)
        XCTAssertEqual(actorHistory.map(\.date), [
            start,
            try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: start)),
            today,
        ])
        XCTAssertEqual(
            actorState?.domains.first(where: { $0.domain == .activity })?.currentValue,
            5_043
        )
        XCTAssertFalse(actorHistory.contains { $0.state.domains.contains { $0.currentValue == 99_999 } })
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DailyBriefRecord>()), beforeDailyBriefs)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<WeeklyBriefRecord>()), beforeWeeklyBriefs)
    }

    func testActorHistoryRetainsExistingRangeValidation() async throws {
        let schema = Schema(versionedSchema: DensosoSchemaV4.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let actor = HealthProjectionActor(modelContainer: container)
        let today = Calendar.current.startOfDay(for: Date())
        let oversizedStart = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -14, to: today))

        do {
            _ = try await actor.healthHistory(from: oversizedStart, through: today)
            XCTFail("Expected the existing fourteen-day bound to reject this query")
        } catch {
            XCTAssertEqual(error as? HealthHistoryQueryError, .rangeTooLarge)
        }
    }

    func testHealthContextSummaryReadsCanonicalDailyMetricsProteinOnlyWhenUsable() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let today = calendar.startOfDay(for: Date())
        let schema = Schema(versionedSchema: DensosoSchemaV4.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        let mealProtein = 2_000.0
        context.insert(DailyMetrics(
            date: today,
            proteinG: mealProtein,
            mealCount: 12,
            dataCoverageJSON: #"{"protein":true}"#,
            projectionVersion: AlgorithmVersions.dailyMetricsProjection,
            sourceFingerprint: "canonical-protein-available"
        ))
        let previousDay = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: today))
        context.insert(DailyMetrics(
            date: previousDay,
            proteinG: 900,
            mealCount: 1,
            dataCoverageJSON: #"{"protein":false}"#,
            projectionVersion: AlgorithmVersions.dailyMetricsProjection,
            sourceFingerprint: "canonical-protein-unavailable"
        ))
        try context.save()

        let actor = HealthProjectionActor(modelContainer: container, calendar: calendar)
        let result = try await actor.healthContextSummary(asOf: today.addingTimeInterval(12 * 60 * 60))
        let summary = try XCTUnwrap(result)

        XCTAssertEqual(summary.sevenDay.averageProteinGrams, mealProtein)
    }

    func testReadModelKeepsImportedWorkoutWhenDailyAuthorizationCoverageIsUnknown() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 23)))
        let authorizationBoundary = try XCTUnwrap(
            calendar.date(bySettingHour: 12, minute: 0, second: 0, of: day)
        )
        let workoutStart = authorizationBoundary.addingTimeInterval(60 * 60)
        let asOf = day.addingTimeInterval(23 * 60 * 60)
        let schema = Schema(versionedSchema: DensosoSchemaV14.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        let workoutID = UUID(uuidString: "00000000-0000-0000-0000-00000000A041")!
        context.insert(WorkoutRecord(
            date: workoutStart,
            type: "running",
            durationMinutes: 30,
            estimatedCaloriesBurned: 150,
            intensity: "moderate",
            healthKitUUID: workoutID,
            workoutOrigin: WorkoutOrigin.externalHealthKit.rawValue,
            energySource: WorkoutEnergySource.measured.rawValue
        ))

        let snapshot = DailyHealthSnapshot(
            dayStart: day,
            timezoneIdentifier: calendar.timeZone.identifier,
            healthReadStates: [
                HealthMetricID.workout.rawValue: .dataUnavailableOrReadScopeUnknown,
                HealthMetricID.workoutEffort.rawValue: .dataUnavailableOrReadScopeUnknown,
            ],
            algorithmVersion: DailyHealthSnapshot.currentAlgorithmVersion
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        context.insert(DailyHealthSnapshotRecord(
            dayKey: dayKey(day, calendar: calendar),
            timezoneID: calendar.timeZone.identifier,
            payloadData: try encoder.encode(snapshot),
            snapshotHash: "unknown-workout-coverage-with-imported-record",
            algorithmVersion: snapshot.algorithmVersion
        ))
        context.insert(HealthKitImportCursor(
            stream: "workouts",
            anchorData: Data([1]),
            lastSuccessfulAt: asOf,
            lookbackStart: authorizationBoundary
        ))
        try context.save()

        let readModel = HealthIntelligenceReadModel(calendar: calendar)
        let days = try readModel.loadDays(through: asOf, in: context)
        let projectedDay = try XCTUnwrap(days.first(where: { $0.dayStart == day }))
        XCTAssertEqual(projectedDay.workouts.count, 1)
        XCTAssertEqual(projectedDay.workouts.first?.startedAt, workoutStart)
        XCTAssertEqual(try XCTUnwrap(projectedDay.workouts.first).durationMinutes, 30, accuracy: 0.001)
        XCTAssertEqual(
            projectedDay.healthReadStates?[HealthMetricID.workout.rawValue],
            .dataUnavailableOrReadScopeUnknown
        )
        XCTAssertEqual(projectedDay.healthQueryStartByMetric?[HealthMetricID.workout.rawValue], authorizationBoundary)

        let state = try XCTUnwrap(readModel.todayHealthState(asOf: asOf, in: context))
        XCTAssertEqual(state.trainingLoad.dataCoverage, .partial)
        XCTAssertEqual(projectedDay.workouts.first?.intensity, "unknown")
        XCTAssertEqual(state.trainingLoad.recentSevenDayLoad, 0, accuracy: 0.001)
        XCTAssertEqual(state.trainingLoad.unavailableEffortCount, 1)
        XCTAssertEqual(state.trainingLoad.estimatedWorkoutCount, 0)
    }

    func testTimezoneChangeReassignsHealthSamplesToCurrentLocalDaysAcrossDST() throws {
        var currentCalendar = Calendar(identifier: .gregorian)
        currentCalendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        var oldCalendar = Calendar(identifier: .gregorian)
        oldCalendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let firstDay = try XCTUnwrap(currentCalendar.date(from: DateComponents(year: 2026, month: 11, day: 1)))
        let secondDay = try XCTUnwrap(currentCalendar.date(byAdding: .day, value: 1, to: firstDay))
        let thirdDay = try XCTUnwrap(currentCalendar.date(byAdding: .day, value: 1, to: secondDay))
        let oldSecondDay = try XCTUnwrap(oldCalendar.date(from: DateComponents(year: 2026, month: 11, day: 2)))
        let oldAbsoluteSampleDate = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-02T09:30:00Z"))
        let currentAbsoluteSampleDate = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-02T07:30:00Z"))
        let staleSample = HealthSampleSnapshot(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000805")!,
            metric: .heartRate,
            startDate: oldAbsoluteSampleDate,
            endDate: oldAbsoluteSampleDate.addingTimeInterval(60),
            value: 99
        )
        let currentSample = HealthSampleSnapshot(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000806")!,
            metric: .heartRate,
            startDate: currentAbsoluteSampleDate,
            endDate: currentAbsoluteSampleDate.addingTimeInterval(60),
            value: 72
        )
        let mismatchedSample = HealthSampleSnapshot(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000807")!,
            metric: .heartRate,
            startDate: oldAbsoluteSampleDate,
            endDate: oldAbsoluteSampleDate.addingTimeInterval(60),
            value: 88
        )
        let schema = Schema(versionedSchema: DensosoSchemaV14.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let currentTimeZoneIdentifier = currentCalendar.timeZone.identifier
        let heartRateReadState = [HealthMetricID.heartRate.rawValue: HealthReadState.available]

        let staleSnapshot = DailyHealthSnapshot(
            dayStart: oldSecondDay,
            timezoneIdentifier: oldCalendar.timeZone.identifier,
            healthKitSampleSummary: DailyHealthSampleSummary(samples: [staleSample], dayStart: oldSecondDay),
            healthReadStates: heartRateReadState,
            algorithmVersion: DailyHealthSnapshot.currentAlgorithmVersion
        )
        context.insert(DailyHealthSnapshotRecord(
            dayKey: dayKey(secondDay, calendar: currentCalendar),
            timezoneID: oldCalendar.timeZone.identifier,
            payloadData: try encoder.encode(staleSnapshot),
            snapshotHash: "timezone-stale-day-absolute-time",
            algorithmVersion: staleSnapshot.algorithmVersion
        ))

        let currentSnapshot = DailyHealthSnapshot(
            dayStart: firstDay,
            timezoneIdentifier: currentTimeZoneIdentifier,
            healthKitSampleSummary: DailyHealthSampleSummary(samples: [currentSample], dayStart: firstDay),
            healthReadStates: heartRateReadState,
            algorithmVersion: DailyHealthSnapshot.currentAlgorithmVersion
        )
        context.insert(DailyHealthSnapshotRecord(
            dayKey: dayKey(firstDay, calendar: currentCalendar),
            timezoneID: currentTimeZoneIdentifier,
            payloadData: try encoder.encode(currentSnapshot),
            snapshotHash: "timezone-current-dst-day",
            algorithmVersion: currentSnapshot.algorithmVersion
        ))

        let mismatchedDayKeySnapshot = DailyHealthSnapshot(
            dayStart: secondDay,
            timezoneIdentifier: currentTimeZoneIdentifier,
            healthKitSampleSummary: DailyHealthSampleSummary(samples: [mismatchedSample], dayStart: secondDay),
            healthReadStates: heartRateReadState,
            algorithmVersion: DailyHealthSnapshot.currentAlgorithmVersion
        )
        context.insert(DailyHealthSnapshotRecord(
            dayKey: dayKey(thirdDay, calendar: currentCalendar),
            timezoneID: currentTimeZoneIdentifier,
            payloadData: try encoder.encode(mismatchedDayKeySnapshot),
            snapshotHash: "timezone-daykey-payload-mismatch",
            algorithmVersion: mismatchedDayKeySnapshot.algorithmVersion
        ))
        try context.save()

        let days = try HealthIntelligenceReadModel(calendar: currentCalendar).loadDays(
            through: thirdDay,
            in: context
        )
        let first = try XCTUnwrap(days.first { $0.dayStart == firstDay })
        let second = try XCTUnwrap(days.first { $0.dayStart == secondDay })
        let third = try XCTUnwrap(days.first { $0.dayStart == thirdDay })

        XCTAssertTrue(currentCalendar.isDate(currentAbsoluteSampleDate, inSameDayAs: firstDay))
        XCTAssertEqual(first.heartRateSamples, [72])
        XCTAssertEqual(second.heartRateSamples, [])
        XCTAssertEqual(third.heartRateSamples, [])
        XCTAssertEqual(second.healthReadStates?[HealthMetricID.heartRate.rawValue], .dataUnavailableOrReadScopeUnknown)
        XCTAssertEqual(third.healthReadStates?[HealthMetricID.heartRate.rawValue], .dataUnavailableOrReadScopeUnknown)
    }

    func testReadModelFailsClosedForOldSnapshotAndSleepAlgorithmVersions() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let firstDay = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 1)))
        let secondDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: firstDay))
        let schema = Schema(versionedSchema: DensosoSchemaV14.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let sample = HealthSampleSnapshot(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000809")!,
            metric: .heartRate,
            startDate: firstDay.addingTimeInterval(12 * 60 * 60),
            endDate: firstDay.addingTimeInterval(12 * 60 * 60 + 60),
            value: 86
        )
        let outdatedSnapshot = DailyHealthSnapshot(
            dayStart: firstDay,
            timezoneIdentifier: calendar.timeZone.identifier,
            healthKitSampleSummary: DailyHealthSampleSummary(samples: [sample], dayStart: firstDay),
            healthReadStates: [HealthMetricID.heartRate.rawValue: .available],
            algorithmVersion: "daily-health-snapshot-v2"
        )
        context.insert(DailyHealthSnapshotRecord(
            dayKey: dayKey(firstDay, calendar: calendar),
            timezoneID: calendar.timeZone.identifier,
            payloadData: try encoder.encode(outdatedSnapshot),
            snapshotHash: "stale-snapshot-algorithm",
            algorithmVersion: outdatedSnapshot.algorithmVersion
        ))
        let outdatedSleep = SleepSummary(
            wakeDate: secondDay,
            totalAsleepMinutes: 300,
            mainSleepMinutes: 300,
            napMinutes: 0,
            stageCoverage: nil,
            stages: nil,
            selectedSourceBundleIdentifier: "com.example.health",
            algorithmVersion: SleepSummary.legacyAlgorithmVersion
        )
        let currentSnapshotWithStaleSleep = DailyHealthSnapshot(
            dayStart: secondDay,
            timezoneIdentifier: calendar.timeZone.identifier,
            healthKitSampleSummary: DailyHealthSampleSummary(
                metrics: [],
                sleep: outdatedSleep,
                workoutEffort: []
            ),
            healthReadStates: [HealthMetricID.sleepAnalysis.rawValue: .available],
            algorithmVersion: DailyHealthSnapshot.currentAlgorithmVersion
        )
        context.insert(DailyHealthSnapshotRecord(
            dayKey: dayKey(secondDay, calendar: calendar),
            timezoneID: calendar.timeZone.identifier,
            payloadData: try encoder.encode(currentSnapshotWithStaleSleep),
            snapshotHash: "stale-sleep-algorithm",
            algorithmVersion: currentSnapshotWithStaleSleep.algorithmVersion
        ))
        try context.save()

        let days = try HealthIntelligenceReadModel(calendar: calendar).loadDays(
            through: secondDay,
            in: context
        )
        let first = try XCTUnwrap(days.first { $0.dayStart == firstDay })
        let second = try XCTUnwrap(days.first { $0.dayStart == secondDay })
        XCTAssertEqual(first.heartRateSamples, [])
        XCTAssertEqual(first.healthReadStates?[HealthMetricID.heartRate.rawValue], .dataUnavailableOrReadScopeUnknown)
        XCTAssertNil(second.sleepSummary)
        XCTAssertEqual(second.healthReadStates?[HealthMetricID.sleepAnalysis.rawValue], .dataUnavailableOrReadScopeUnknown)
    }

    func testTrainingLoadCanonicalizesOnlyMatchingLogicalWorkoutSessions() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 4)))
        let start = day.addingTimeInterval(9 * 60 * 60)
        let logicalSessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000810")!
        let sessionWithEffortID = UUID(uuidString: "00000000-0000-0000-0000-000000000811")!
        let sessionWithoutEffortID = UUID(uuidString: "00000000-0000-0000-0000-000000000812")!
        let sessionWithoutID1 = UUID(uuidString: "00000000-0000-0000-0000-000000000813")!
        let sessionWithoutID2 = UUID(uuidString: "00000000-0000-0000-0000-000000000814")!
        let crossSourceID1 = UUID(uuidString: "00000000-0000-0000-0000-000000000816")!
        let crossSourceID2 = UUID(uuidString: "00000000-0000-0000-0000-000000000817")!
        let differentTypeID1 = UUID(uuidString: "00000000-0000-0000-0000-000000000818")!
        let differentTypeID2 = UUID(uuidString: "00000000-0000-0000-0000-000000000819")!
        let sameSourceID1 = UUID(uuidString: "00000000-0000-0000-0000-000000000820")!
        let sameSourceID2 = UUID(uuidString: "00000000-0000-0000-0000-000000000821")!
        func workout(
            id: UUID,
            logicalSessionID: UUID?,
            durationMinutes: Int,
            dataQuality: WorkoutDataQuality,
            date: Date? = nil,
            type: String = "running",
            sourceBundleIdentifier: String? = nil,
            origin: WorkoutOrigin = .watchHealthKit
        ) -> WorkoutRecord {
            let record = WorkoutRecord(
                date: date ?? start,
                type: type,
                durationMinutes: durationMinutes,
                intensity: "unknown",
                logicalSessionID: logicalSessionID,
                workoutOrigin: origin.rawValue,
                sourceBundleIdentifier: sourceBundleIdentifier,
                dataQuality: dataQuality.rawValue
            )
            record.id = id
            return record
        }

        let sessionWithEffort = workout(
            id: sessionWithEffortID,
            logicalSessionID: logicalSessionID,
            durationMinutes: 35,
            dataQuality: .partial
        )
        let sessionWithoutEffort = workout(
            id: sessionWithoutEffortID,
            logicalSessionID: logicalSessionID,
            durationMinutes: 80,
            dataQuality: .complete
        )
        let independent1 = workout(
            id: sessionWithoutID1,
            logicalSessionID: nil,
            durationMinutes: 20,
            dataQuality: .complete
        )
        let independent2 = workout(
            id: sessionWithoutID2,
            logicalSessionID: nil,
            durationMinutes: 20,
            dataQuality: .complete
        )
        let crossSourceDuplicate1 = workout(
            id: crossSourceID1,
            logicalSessionID: nil,
            durationMinutes: 30,
            dataQuality: .partial,
            date: start.addingTimeInterval(2 * 60),
            sourceBundleIdentifier: "com.example.health.phone",
            origin: .externalHealthKit
        )
        let crossSourceDuplicate2Start = start.addingTimeInterval(2 * 60 + 30)
        let crossSourceDuplicate2 = workout(
            id: crossSourceID2,
            logicalSessionID: nil,
            durationMinutes: 30,
            dataQuality: .complete,
            date: crossSourceDuplicate2Start,
            sourceBundleIdentifier: "com.example.health.watch",
            origin: .watchHealthKit
        )
        let differentTypeStart = start.addingTimeInterval(5 * 60)
        let differentType1 = workout(
            id: differentTypeID1,
            logicalSessionID: nil,
            durationMinutes: 30,
            dataQuality: .complete,
            date: differentTypeStart,
            type: "running",
            sourceBundleIdentifier: "com.example.health.phone",
            origin: .externalHealthKit
        )
        let differentType2 = workout(
            id: differentTypeID2,
            logicalSessionID: nil,
            durationMinutes: 30,
            dataQuality: .complete,
            date: differentTypeStart.addingTimeInterval(30),
            type: "cycling",
            sourceBundleIdentifier: "com.example.health.watch",
            origin: .watchHealthKit
        )
        let sameSourceStart = start.addingTimeInterval(10 * 60)
        let sameSource1 = workout(
            id: sameSourceID1,
            logicalSessionID: nil,
            durationMinutes: 30,
            dataQuality: .complete,
            date: sameSourceStart,
            sourceBundleIdentifier: "com.example.health.same-source",
            origin: .externalHealthKit
        )
        let sameSource2 = workout(
            id: sameSourceID2,
            logicalSessionID: nil,
            durationMinutes: 30,
            dataQuality: .complete,
            date: sameSourceStart.addingTimeInterval(30),
            sourceBundleIdentifier: "com.example.health.same-source",
            origin: .externalHealthKit
        )
        let effortSample = HealthSampleSnapshot(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000815")!,
            metric: .workoutEffort,
            startDate: start,
            endDate: start.addingTimeInterval(35 * 60),
            value: 8
        )
        let sampleSummary = DailyHealthSampleSummary(
            samples: [effortSample],
            dayStart: day,
            workoutEffort: [WorkoutEffortDailyAggregate(workoutRecordID: sessionWithEffortID, score: 8)]
        )
        let snapshot = DailyHealthSnapshot(
            dayStart: day,
            timezoneIdentifier: calendar.timeZone.identifier,
            healthKitSampleSummary: sampleSummary,
            healthReadStates: [HealthMetricID.workoutEffort.rawValue: .available],
            algorithmVersion: DailyHealthSnapshot.currentAlgorithmVersion
        )
        let schema = Schema(versionedSchema: DensosoSchemaV14.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        context.insert(DailyHealthSnapshotRecord(
            dayKey: dayKey(day, calendar: calendar),
            timezoneID: calendar.timeZone.identifier,
            payloadData: try encoder.encode(snapshot),
            snapshotHash: "logical-session-effort-fixture",
            algorithmVersion: snapshot.algorithmVersion
        ))
        let originalRecords = [
            sessionWithEffort,
            sessionWithoutEffort,
            independent1,
            independent2,
            crossSourceDuplicate1,
            crossSourceDuplicate2,
            differentType1,
            differentType2,
            sameSource1,
            sameSource2,
        ]
        for record in originalRecords {
            context.insert(record)
        }
        try context.save()

        let days = try HealthIntelligenceReadModel(calendar: calendar).loadDays(
            through: day,
            in: context
        )
        let projectedDay = try XCTUnwrap(days.first(where: { $0.dayStart == day }))
        XCTAssertEqual(projectedDay.workouts.count, 8)
        XCTAssertTrue(projectedDay.workouts.contains(TrainingWorkoutInput(
            startedAt: start,
            durationMinutes: 35,
            effortScore: 8,
            intensity: "unknown"
        )), "The duplicate with valid effort is the canonical session input")
        XCTAssertTrue(projectedDay.workouts.contains(TrainingWorkoutInput(
            startedAt: crossSourceDuplicate2Start,
            durationMinutes: 30,
            effortScore: nil,
            intensity: "unknown"
        )), "A cross-source pair with matching activity and near-identical bounds merges to its higher-quality record")
        XCTAssertTrue(projectedDay.workouts.contains(where: { $0.startedAt == differentTypeStart }))
        XCTAssertTrue(projectedDay.workouts.contains(where: { $0.startedAt == differentTypeStart.addingTimeInterval(30) }))
        XCTAssertTrue(projectedDay.workouts.contains(where: { $0.startedAt == sameSourceStart }))
        XCTAssertTrue(projectedDay.workouts.contains(where: { $0.startedAt == sameSourceStart.addingTimeInterval(30) }))
        XCTAssertEqual(try context.fetch(FetchDescriptor<WorkoutRecord>()).count, originalRecords.count)
    }

    func testLegacyImportedWorkoutModerateDefaultIsNotUsedAsEffortEstimate() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 4)))
        let start = day.addingTimeInterval(9 * 60 * 60)
        let imported = WorkoutRecord(
            date: start,
            type: "running",
            durationMinutes: 45,
            intensity: "moderate",
            healthKitUUID: UUID(uuidString: "00000000-0000-0000-0000-000000000822")!,
            workoutOrigin: WorkoutOrigin.externalHealthKit.rawValue
        )
        let manual = WorkoutRecord(
            date: start.addingTimeInterval(2 * 60 * 60),
            type: "running",
            durationMinutes: 30,
            intensity: "moderate"
        )
        let snapshot = DailyHealthSnapshot(
            dayStart: day,
            timezoneIdentifier: calendar.timeZone.identifier,
            healthKitSampleSummary: DailyHealthSampleSummary(metrics: [], sleep: nil, workoutEffort: []),
            healthReadStates: [
                HealthMetricID.workout.rawValue: .available,
                HealthMetricID.workoutEffort.rawValue: .available,
            ],
            algorithmVersion: DailyHealthSnapshot.currentAlgorithmVersion
        )
        let schema = Schema(versionedSchema: DensosoSchemaV14.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        context.insert(DailyHealthSnapshotRecord(
            dayKey: dayKey(day, calendar: calendar),
            timezoneID: calendar.timeZone.identifier,
            payloadData: try encoder.encode(snapshot),
            snapshotHash: "legacy-imported-workout-intensity",
            algorithmVersion: snapshot.algorithmVersion
        ))
        context.insert(imported)
        context.insert(manual)
        try context.save()

        let projectedDay = try XCTUnwrap(
            HealthIntelligenceReadModel(calendar: calendar).loadDays(through: day, in: context)
                .first(where: { $0.dayStart == day })
        )
        XCTAssertTrue(projectedDay.workouts.contains(TrainingWorkoutInput(
            startedAt: start,
            durationMinutes: 45,
            effortScore: nil,
            intensity: "unknown"
        )))
        XCTAssertTrue(projectedDay.workouts.contains(TrainingWorkoutInput(
            startedAt: manual.date,
            durationMinutes: 30,
            effortScore: nil,
            intensity: "moderate"
        )))

        let trainingLoad = HealthIntelligenceEngine(calendar: calendar).trainingLoad(
            workouts: projectedDay.workouts,
            asOf: day
        )
        XCTAssertEqual(trainingLoad.unavailableEffortCount, 1)
        XCTAssertEqual(trainingLoad.estimatedWorkoutCount, 1)
    }

    func testLoadDaysIncludesAllWorkoutsAcrossStableFetchPages() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let today = calendar.startOfDay(for: Date())
        let workoutDate = try XCTUnwrap(calendar.date(bySettingHour: 12, minute: 0, second: 0, of: today))
        let schema = Schema(versionedSchema: DensosoSchemaV4.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        let workoutCount = HealthIntelligenceReadModel.workoutFetchBatchSize + 1
        for index in 0..<workoutCount {
            let workout = WorkoutRecord(
                date: workoutDate,
                type: "walking",
                durationMinutes: index + 1
            )
            workout.id = try XCTUnwrap(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012X", index + 1)))
            context.insert(workout)
        }
        let tomorrow = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: today))
        context.insert(WorkoutRecord(
            date: tomorrow.addingTimeInterval(12 * 60 * 60),
            type: "cycling",
            durationMinutes: 10_000
        ))
        try context.save()

        let readModel = HealthIntelligenceReadModel(calendar: calendar)
        let days = try readModel.loadDays(through: today, in: context)
        let todayWorkouts = try XCTUnwrap(days.first(where: { $0.dayStart == today })).workouts

        XCTAssertEqual(todayWorkouts.count, workoutCount)
        XCTAssertEqual(todayWorkouts.reduce(0) { $0 + $1.durationMinutes }, Double((1...workoutCount).reduce(0, +)))
    }

    func testLoadDaysIncludesAllWeightsAcrossStableFetchPages() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let today = calendar.startOfDay(for: Date())
        let measuredAt = try XCTUnwrap(calendar.date(bySettingHour: 12, minute: 0, second: 0, of: today))
        let schema = Schema(versionedSchema: DensosoSchemaV4.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        let weightCount = HealthIntelligenceReadModel.weightFetchBatchSize + 1
        for index in 0..<weightCount {
            context.insert(WeightRecord(
                id: try XCTUnwrap(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012X", index + 1))),
                sourceActionKey: String(format: "projection-weight-%04d", index),
                measuredAt: measuredAt,
                kilograms: Double(index + 1)
            ))
        }
        let tomorrow = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: today))
        context.insert(WeightRecord(
            sourceActionKey: "projection-weight-outside-window",
            measuredAt: tomorrow.addingTimeInterval(12 * 60 * 60),
            kilograms: 10_000
        ))
        try context.save()

        let readModel = HealthIntelligenceReadModel(calendar: calendar)
        let days = try readModel.loadDays(through: today, in: context)
        let todayWeights = try XCTUnwrap(days.first(where: { $0.dayStart == today })).weightSamplesKilograms

        XCTAssertEqual(todayWeights.count, weightCount)
        XCTAssertEqual(todayWeights.reduce(0, +), Double((1...weightCount).reduce(0, +)))
    }

    func testConfirmedPlanEntriesDecodeAndSortBothPlanTypesAndIgnoreOrdinaryEvents() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let today = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 16)))
        let tomorrow = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: today))
        let schema = Schema(versionedSchema: DensosoSchemaV4.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)

        let todayWorkout = ConfirmedWorkoutPlanEntry(
            actionID: UUID(uuidString: "00000000-0000-0000-0000-000000000A01")!,
            idempotencyKey: "daily-loop-today-workout",
            draft: WorkoutPlanDraft(
                name: "今日步行",
                activity: .walking,
                scheduledAt: today.addingTimeInterval(12 * 60 * 60)
            )
        )
        let tomorrowWorkout = ConfirmedWorkoutPlanEntry(
            actionID: UUID(uuidString: "00000000-0000-0000-0000-000000000A02")!,
            idempotencyKey: "daily-loop-tomorrow-workout",
            draft: WorkoutPlanDraft(
                name: "明日骑行",
                activity: .cycling,
                scheduledAt: tomorrow.addingTimeInterval(9 * 60 * 60)
            )
        )
        let olderTrainingSessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000A21")!
        let newerTrainingSessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000A22")!
        let olderTrainingPlan = ConfirmedTrainingPlanEntry(
            actionID: UUID(uuidString: "00000000-0000-0000-0000-000000000A03")!,
            idempotencyKey: "daily-loop-older-training-plan",
            draft: TrainingPlanDraft(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000A13")!,
                name: "旧多日计划",
                createdAt: today.addingTimeInterval(-200),
                sessions: [TrainingSessionDraft(id: olderTrainingSessionID, date: today, activity: .walking, reason: "计划训练")]
            )
        )
        let newerTrainingPlan = ConfirmedTrainingPlanEntry(
            actionID: UUID(uuidString: "00000000-0000-0000-0000-000000000A04")!,
            idempotencyKey: "daily-loop-newer-training-plan",
            draft: TrainingPlanDraft(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000A14")!,
                name: "新多日计划",
                createdAt: today.addingTimeInterval(-100),
                sessions: [
                    TrainingSessionDraft(id: newerTrainingSessionID, date: today, activity: .cycling, reason: "计划骑行"),
                    TrainingSessionDraft(date: tomorrow, activity: nil, reason: "休息日"),
                ]
            )
        )

        context.insert(ScheduleEvent(
            date: today,
            title: "普通日程",
            notes: "not-a-confirmed-plan",
            startTime: today
        ))
        context.insert(ScheduleEvent(
            date: today,
            title: olderTrainingPlan.draft.name,
            notes: try olderTrainingPlan.encodedNotes(),
            startTime: today
        ))
        context.insert(ScheduleEvent(
            date: tomorrow,
            title: tomorrowWorkout.draft.name,
            notes: try tomorrowWorkout.encodedNotes(),
            startTime: tomorrow
        ))
        context.insert(ScheduleEvent(
            date: today,
            title: todayWorkout.draft.name,
            notes: try todayWorkout.encodedNotes(),
            startTime: today
        ))
        context.insert(ScheduleEvent(
            date: today,
            title: newerTrainingPlan.draft.name,
            notes: try newerTrainingPlan.encodedNotes(),
            startTime: today
        ))
        try context.save()
        let countBefore = try context.fetchCount(FetchDescriptor<ScheduleEvent>())

        let actor = HealthProjectionActor(modelContainer: container, calendar: calendar)
        let plans = try await actor.confirmedPlanEntries()

        XCTAssertEqual(plans.workoutPlans.map(\.actionID), [tomorrowWorkout.actionID, todayWorkout.actionID])
        XCTAssertEqual(plans.trainingPlans.map(\.actionID), [newerTrainingPlan.actionID, olderTrainingPlan.actionID])
        XCTAssertEqual(plans.trainingPlans.first?.draft.sessions.count, 2)

        let asOf = today.addingTimeInterval(10 * 60 * 60)
        let activeAction = PendingAction(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000A05")!,
            idempotencyKey: "daily-loop-active-action",
            clientRequestID: UUID(),
            createdAt: asOf.addingTimeInterval(-60),
            expiresAt: asOf.addingTimeInterval(3_600),
            payload: .trainingPlan(newerTrainingPlan.draft),
            state: .pending
        )
        let expiredAction = PendingAction(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000A06")!,
            idempotencyKey: "daily-loop-expired-action",
            clientRequestID: UUID(),
            createdAt: asOf.addingTimeInterval(-120),
            expiresAt: asOf.addingTimeInterval(-1),
            payload: .trainingPlan(olderTrainingPlan.draft),
            state: .pending
        )
        let snapshot = try await actor.dailyLoopSnapshot(
            asOf: asOf,
            dailyBrief: nil,
            dailyBriefSourceFingerprint: nil,
            dailyBriefValidatedAt: nil,
            pendingActions: [expiredAction, activeAction]
        )
        XCTAssertEqual(snapshot.phase, .morning)
        XCTAssertNil(snapshot.todaySummary)
        XCTAssertEqual(snapshot.pendingActions.map(\.actionID), [activeAction.id])
        XCTAssertTrue(snapshot.pendingActions.first?.requiresPhoneReview == true)
        XCTAssertEqual(snapshot.workoutPlans.map(\.actionID), [
            olderTrainingSessionID,
            newerTrainingSessionID,
            todayWorkout.actionID,
            tomorrowWorkout.actionID,
        ])
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ScheduleEvent>()), countBefore)
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<ScheduleEvent>()).first(where: { $0.title == "普通日程" })?.notes,
            "not-a-confirmed-plan"
        )
    }

    func testConfirmedPlanEntriesPageHistoricalPlansAndDailySnapshotRetainsOnlyCurrentSessions() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let today = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 16)))
        let tomorrow = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: today))
        let afterTomorrow = try XCTUnwrap(calendar.date(byAdding: .day, value: 2, to: today))
        let schema = Schema(versionedSchema: DensosoSchemaV4.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)

        let historicalPlanCount = 65
        var historicalActionIDs: [UUID] = []
        for index in 0..<historicalPlanCount {
            let actionID = try XCTUnwrap(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012X", index + 1_000)))
            historicalActionIDs.append(actionID)
            let scheduledAt = try XCTUnwrap(calendar.date(byAdding: .day, value: -200 + index, to: today))
                .addingTimeInterval(12 * 60 * 60)
            let entry = ConfirmedWorkoutPlanEntry(
                actionID: actionID,
                idempotencyKey: "daily-loop-historical-\(index)",
                draft: WorkoutPlanDraft(name: "历史计划 \(index)", activity: .walking, scheduledAt: scheduledAt)
            )
            context.insert(ScheduleEvent(
                date: scheduledAt,
                title: entry.draft.name,
                notes: try entry.encodedNotes(),
                startTime: scheduledAt
            ))
        }

        let todaySessionID = UUID(uuidString: "00000000-0000-0000-0000-00000000B001")!
        let todaySessionDate = today.addingTimeInterval(11 * 60 * 60)
        let trainingEntry = ConfirmedTrainingPlanEntry(
            actionID: UUID(uuidString: "00000000-0000-0000-0000-00000000B002")!,
            idempotencyKey: "daily-loop-current-training-plan",
            draft: TrainingPlanDraft(
                name: "当前多日计划",
                createdAt: today,
                sessions: [
                    TrainingSessionDraft(id: todaySessionID, date: todaySessionDate, activity: .cycling, reason: "今日骑行"),
                    TrainingSessionDraft(date: tomorrow, activity: nil, reason: "明日休息"),
                    TrainingSessionDraft(
                        date: afterTomorrow.addingTimeInterval(12 * 60 * 60),
                        activity: .walking,
                        reason: "后日步行"
                    ),
                ]
            )
        )
        context.insert(ScheduleEvent(
            date: today,
            title: trainingEntry.draft.name,
            notes: try trainingEntry.encodedNotes(),
            startTime: todaySessionDate
        ))
        try context.save()
        let eventCountBefore = try context.fetchCount(FetchDescriptor<ScheduleEvent>())

        let actor = HealthProjectionActor(modelContainer: container, calendar: calendar)
        let allPlans = try await actor.confirmedPlanEntries()
        XCTAssertEqual(allPlans.workoutPlans.count, historicalPlanCount)
        XCTAssertEqual(allPlans.workoutPlans.first?.actionID, historicalActionIDs.last)
        XCTAssertEqual(allPlans.workoutPlans.last?.actionID, historicalActionIDs.first)
        XCTAssertEqual(allPlans.trainingPlans.map(\.actionID), [trainingEntry.actionID])
        XCTAssertEqual(allPlans.trainingPlans.first?.draft.sessions.count, 3)

        let snapshot = try await actor.dailyLoopSnapshot(
            asOf: today.addingTimeInterval(10 * 60 * 60),
            dailyBrief: nil,
            dailyBriefSourceFingerprint: nil,
            dailyBriefValidatedAt: nil,
            pendingActions: []
        )
        XCTAssertEqual(snapshot.workoutPlans.map(\.actionID), [todaySessionID])
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ScheduleEvent>()), eventCountBefore)
    }

    func testDailyLoopSnapshotRetainsTenEarliestPlanSessionsAcrossPages() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let today = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 16)))
        let schema = Schema(versionedSchema: DensosoSchemaV4.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)

        for index in 0..<70 {
            let actionID = try XCTUnwrap(
                UUID(uuidString: String(format: "00000000-0000-0000-0000-%012X", 0xD000 + index))
            )
            let scheduledAt = today.addingTimeInterval(11 * 60 * 60 + Double(index) * 60)
            let entry = ConfirmedWorkoutPlanEntry(
                actionID: actionID,
                idempotencyKey: "watch-daily-plan-\(index)",
                draft: WorkoutPlanDraft(name: "计划 \(index)", activity: .walking, scheduledAt: scheduledAt),
                state: .scheduled
            )
            context.insert(ScheduleEvent(
                date: scheduledAt,
                title: entry.draft.name,
                notes: try entry.encodedNotes(),
                startTime: scheduledAt
            ))
        }

        let trainingActionID = UUID(uuidString: "00000000-0000-0000-0000-00000000B001")!
        let trainingSessionIDs = (1...4).map {
            UUID(uuidString: String(format: "00000000-0000-0000-0000-%012X", 0xC000 + $0))!
        }
        let trainingSessions = trainingSessionIDs.enumerated().map { index, id in
            TrainingSessionDraft(
                id: id,
                date: today.addingTimeInterval(10 * 60 * 60 + Double(index) * 60),
                activity: .cycling,
                reason: "多日计划训练 \(index)"
            )
        } + [TrainingSessionDraft(
            date: today.addingTimeInterval(10 * 60 * 60 + 4 * 60),
            activity: nil,
            reason: "计划休息"
        )]
        let trainingEntry = ConfirmedTrainingPlanEntry(
            actionID: trainingActionID,
            idempotencyKey: "watch-daily-training-plan",
            draft: TrainingPlanDraft(name: "多日计划", createdAt: today, sessions: trainingSessions),
            state: .scheduled
        )
        context.insert(ScheduleEvent(
            date: today,
            title: trainingEntry.draft.name,
            notes: try trainingEntry.encodedNotes(),
            startTime: today
        ))

        let terminalActionID = UUID(uuidString: "00000000-0000-0000-0000-00000000B002")!
        let terminalTime = today.addingTimeInterval(9 * 60 * 60)
        let terminalEntry = ConfirmedWorkoutPlanEntry(
            actionID: terminalActionID,
            idempotencyKey: "watch-daily-terminal-plan",
            draft: WorkoutPlanDraft(name: "已终止计划", activity: .running, scheduledAt: terminalTime),
            state: .terminal
        )
        context.insert(ScheduleEvent(
            date: terminalTime,
            title: terminalEntry.draft.name,
            notes: try terminalEntry.encodedNotes(),
            startTime: terminalTime
        ))
        context.insert(ScheduleEvent(
            date: terminalTime,
            title: "普通日程",
            notes: "not-a-confirmed-plan",
            startTime: terminalTime
        ))
        context.insert(DailyMetrics(
            date: today,
            totalExpenditureKcal: 1_820,
            totalIntakeKcal: 500,
            deficitKcal: 1_320,
            proteinG: 25,
            fatG: 20,
            carbsG: 60,
            mealCount: 1,
            energyQuality: "observed",
            dataCoverageJSON: #"{"intake":true,"protein":true,"fat":true,"carbs":true}"#,
            projectionVersion: AlgorithmVersions.dailyMetricsProjection,
            sourceFingerprint: "daily-loop-coverage-fixture"
        ))
        try context.save()

        let actor = HealthProjectionActor(modelContainer: container, calendar: calendar)
        let snapshot = try await actor.dailyLoopSnapshot(
            asOf: today.addingTimeInterval(8 * 60 * 60),
            dailyBrief: nil,
            dailyBriefSourceFingerprint: nil,
            dailyBriefValidatedAt: nil,
            pendingActions: []
        )
        let expectedSinglePlanIDs = (0..<6).map {
            UUID(uuidString: String(format: "00000000-0000-0000-0000-%012X", 0xD000 + $0))!
        }

        XCTAssertEqual(snapshot.workoutPlans.count, 10)
        XCTAssertEqual(snapshot.workoutPlans.map(\.actionID), trainingSessionIDs + expectedSinglePlanIDs)
        XCTAssertFalse(snapshot.workoutPlans.contains { $0.actionID == terminalActionID })
        XCTAssertEqual(snapshot.coverage.intake, .estimated)
        XCTAssertEqual(snapshot.coverage.expenditure, .observed)
        XCTAssertEqual(snapshot.refreshState, .refreshRequired)
        XCTAssertNotNil(snapshot.sourceFingerprint)
    }

    func testPlannedWorkoutTomorrowPagesTerminalPlansUntilActiveTrainingPlan() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let today = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 16)))
        let tomorrow = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: today))
        let schema = Schema(versionedSchema: DensosoSchemaV4.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        let readModel = HealthIntelligenceReadModel(calendar: calendar)

        XCTAssertNil(try readModel.plannedWorkoutTomorrow(asOf: today, in: context))

        let ordinaryEventTime = tomorrow.addingTimeInterval(30 * 60)
        context.insert(ScheduleEvent(
            date: ordinaryEventTime,
            title: "普通日程",
            notes: "普通日程备注",
            startTime: ordinaryEventTime
        ))
        try context.save()
        XCTAssertEqual(try readModel.plannedWorkoutTomorrow(asOf: today, in: context), Optional(false))

        for index in 0..<HealthIntelligenceReadModel.schedulePlanFetchBatchSize {
            let actionID = try XCTUnwrap(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012X", index + 2_000)))
            let scheduledAt = tomorrow.addingTimeInterval(Double(index + 1) * 60)
            let entry = ConfirmedWorkoutPlanEntry(
                actionID: actionID,
                idempotencyKey: "planned-tomorrow-terminal-\(index)",
                draft: WorkoutPlanDraft(name: "已终止计划 \(index)", activity: .walking, scheduledAt: scheduledAt),
                state: .terminal
            )
            context.insert(ScheduleEvent(
                date: scheduledAt,
                title: entry.draft.name,
                notes: try entry.encodedNotes(),
                startTime: scheduledAt
            ))
        }
        try context.save()
        XCTAssertEqual(try readModel.plannedWorkoutTomorrow(asOf: today, in: context), Optional(false))

        let activeSessionTime = tomorrow.addingTimeInterval(
            Double(HealthIntelligenceReadModel.schedulePlanFetchBatchSize + 1) * 60
        )
        let activeTrainingEntry = ConfirmedTrainingPlanEntry(
            actionID: UUID(uuidString: "00000000-0000-0000-0000-00000000C001")!,
            idempotencyKey: "planned-tomorrow-active-training",
            draft: TrainingPlanDraft(
                name: "有效多日计划",
                createdAt: today,
                sessions: [
                    TrainingSessionDraft(date: activeSessionTime, activity: .cycling, reason: "明日骑行"),
                ]
            )
        )
        context.insert(ScheduleEvent(
            date: activeSessionTime,
            title: activeTrainingEntry.draft.name,
            notes: try activeTrainingEntry.encodedNotes(),
            startTime: activeSessionTime
        ))
        try context.save()

        XCTAssertEqual(try readModel.plannedWorkoutTomorrow(asOf: today, in: context), Optional(true))
    }

    private func dayKey(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
