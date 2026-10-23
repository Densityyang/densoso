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
            context.insert(DailyMetrics(
                date: day,
                totalExpenditureKcal: 1_880,
                mealCount: 0,
                energyQuality: "observed",
                projectionVersion: AlgorithmVersions.dailyMetricsProjection,
                sourceFingerprint: "health-refresh-perf-metrics-\(offset)"
            ))
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
                algorithmVersion: "projection-actor-fixture-v1"
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
