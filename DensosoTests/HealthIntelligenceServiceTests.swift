import DensosoDomain
import SwiftData
import XCTest
@testable import Densoso

@MainActor
final class HealthIntelligenceServiceTests: XCTestCase {
    func testRefreshBuildsSevenAndTwentyEightDaySummaryAndCachesBySourceHash() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let reference = Date(timeIntervalSince1970: 1_800_000_000)
        let day = Calendar.current.startOfDay(for: reference)
        let key = dayKey(day)
        let sample = HealthSampleSnapshot(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000801")!,
            metric: .bodyMass,
            startDate: reference,
            endDate: reference,
            value: 71.2
        )
        let snapshot = DailyHealthSnapshot(
            dayStart: day,
            timezoneIdentifier: Calendar.current.timeZone.identifier,
            energyIntakeKcal: try EstimateRange(low: 450, likely: 500, high: 600),
            activeEnergyKcal: 420,
            restingEnergyKcal: 1_400,
            stepCount: 7_200,
            exerciseMinutes: 40,
            healthKitSamples: [sample],
            healthReadStates: [
                HealthMetricID.activeEnergy.rawValue: .available,
                HealthMetricID.restingEnergy.rawValue: .available,
            ],
            algorithmVersion: "v3"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        context.insert(DailyHealthSnapshotRecord(
            dayKey: key,
            timezoneID: snapshot.timezoneIdentifier,
            payloadData: try encoder.encode(snapshot),
            snapshotHash: "source-hash-1",
            algorithmVersion: "v3"
        ))
        let metric = DailyMetrics(
            date: day,
            bmrKcal: 1_400,
            activeCaloriesKcal: 420,
            totalExpenditureKcal: 1_820,
            totalIntakeKcal: 500,
            deficitKcal: 1_320,
            proteinG: 25,
            fatG: 20,
            carbsG: 60,
            mealCount: 1,
            workoutCount: 0
        )
        context.insert(metric)
        context.insert(WeightRecord(
            sourceActionKey: "service-test-weight",
            measuredAt: reference,
            kilograms: 71.2
        ))
        context.insert(GoalProfileRecord(
            profileKey: "primary",
            targetWeightKilograms: 68,
            dailyDeficitKcal: 400,
            dailyProteinGrams: 90,
            effectiveFrom: day
        ))
        try context.save()

        let service = HealthIntelligenceService(modelContainer: container)
        let first = try XCTUnwrap(service.refresh(asOf: reference))
        XCTAssertEqual(first.contextSummary.sevenDay.windowDays, 7)
        XCTAssertEqual(first.contextSummary.twentyEightDay.windowDays, 28)
        XCTAssertEqual(first.contextSummary.targetWeightKilograms, 68)
        XCTAssertEqual(first.domains.first(where: { $0.domain == .nutrition })?.currentValue, 500)

        let firstRecord = try XCTUnwrap(
            context.fetch(FetchDescriptor<DailyBriefRecord>()).first(where: { $0.dayKey == key })
        )
        let firstHash = firstRecord.snapshotHash
        let firstPayload = firstRecord.payloadData
        _ = try service.refresh(asOf: reference)
        let unchanged = try XCTUnwrap(context.fetch(FetchDescriptor<DailyBriefRecord>()).first(where: { $0.dayKey == key }))
        XCTAssertEqual(unchanged.snapshotHash, firstHash)
        XCTAssertEqual(unchanged.payloadData, firstPayload)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<WeeklyBriefRecord>()), 1)

        metric.deficitKcal = 900
        try context.save()
        _ = try service.refresh(asOf: reference)
        let changed = try XCTUnwrap(context.fetch(FetchDescriptor<DailyBriefRecord>()).first(where: { $0.dayKey == key }))
        XCTAssertNotEqual(changed.snapshotHash, firstHash)
    }

    func testSavingGoalUpdatesTheSinglePrimaryProfile() throws {
        let container = try makeContainer()
        let service = HealthIntelligenceService(modelContainer: container)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        try service.saveGoalProfile(GoalProfile(effectiveFrom: date, targetWeightKilograms: 68, dailyDeficitKcal: 400))
        try service.saveGoalProfile(GoalProfile(effectiveFrom: date.addingTimeInterval(60), targetWeightKilograms: 66, dailyDeficitKcal: 300))

        let context = ModelContext(container)
        let goals = try context.fetch(FetchDescriptor<GoalProfileRecord>())
        XCTAssertEqual(goals.count, 1)
        XCTAssertEqual(goals[0].targetWeightKilograms, 66)
        XCTAssertEqual(goals[0].dailyDeficitKcal, 300)
    }

    func testPreviousWeekUsesItsFullTwentyEightDayBaselineOnSunday() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let reference = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 26, hour: 12)))
        XCTAssertEqual(calendar.component(.weekday, from: reference), 1, "Fixture date must be Sunday")
        for offset in -41...0 {
            let day = calendar.startOfDay(for: calendar.date(byAdding: .day, value: offset, to: reference)!)
            context.insert(DailyMetrics(
                date: day,
                bmrKcal: 1_400,
                activeCaloriesKcal: 400,
                totalExpenditureKcal: 1_800,
                totalIntakeKcal: 1_600,
                deficitKcal: 200,
                proteinG: 80,
                fatG: 50,
                carbsG: 180,
                mealCount: 1,
                workoutCount: 0
            ))
        }
        try context.save()

        let service = HealthIntelligenceService(modelContainer: container, calendar: calendar)
        _ = try service.refresh(asOf: reference)
        let nutrition = try XCTUnwrap(service.weeklyBrief?.domainStatuses.first(where: { $0.domain == .nutrition }))

        XCTAssertEqual(nutrition.baseline.validDays, 28)
        XCTAssertEqual(nutrition.baseline.readiness, .mature)
    }

    func testHistoryBuildsDailyStatesFromThePriorBaselineWithoutWritingBriefCaches() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 1)))
        let end = try XCTUnwrap(calendar.date(byAdding: .day, value: 2, to: start))
        let container = try makeContainer()
        let context = ModelContext(container)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970

        for offset in -41...2 {
            let day = try XCTUnwrap(calendar.date(byAdding: .day, value: offset, to: start))
            let snapshot = DailyHealthSnapshot(
                dayStart: day,
                timezoneIdentifier: calendar.timeZone.identifier,
                stepCount: Double(5_000 + offset),
                healthReadStates: [HealthMetricID.stepCount.rawValue: .available],
                algorithmVersion: "history-fixture-v4"
            )
            context.insert(DailyHealthSnapshotRecord(
                dayKey: dayKey(day),
                timezoneID: snapshot.timezoneIdentifier,
                payloadData: try encoder.encode(snapshot),
                snapshotHash: "history-\(offset)",
                algorithmVersion: snapshot.algorithmVersion
            ))
        }
        for offset in [-42, 3] {
            let day = try XCTUnwrap(calendar.date(byAdding: .day, value: offset, to: start))
            let snapshot = DailyHealthSnapshot(
                dayStart: day,
                timezoneIdentifier: calendar.timeZone.identifier,
                stepCount: 99_999,
                healthReadStates: [HealthMetricID.stepCount.rawValue: .available],
                algorithmVersion: "outside-history-window"
            )
            context.insert(DailyHealthSnapshotRecord(
                dayKey: dayKey(day),
                timezoneID: snapshot.timezoneIdentifier,
                payloadData: try encoder.encode(snapshot),
                snapshotHash: "outside-history-window-\(offset)",
                algorithmVersion: snapshot.algorithmVersion
            ))
        }
        try context.save()

        let service = HealthIntelligenceService(modelContainer: container, calendar: calendar)
        let history = try service.healthHistory(from: start, through: end)

        XCTAssertEqual(history.map(\.date), [
            start,
            try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: start)),
            end,
        ])
        let firstActivity = try XCTUnwrap(history.first?.state.domains.first(where: { $0.domain == .activity }))
        let lastActivity = try XCTUnwrap(history.last?.state.domains.first(where: { $0.domain == .activity }))
        XCTAssertEqual(firstActivity.currentValue, 5_000)
        XCTAssertEqual(lastActivity.currentValue, 5_002)
        XCTAssertGreaterThanOrEqual(firstActivity.baseline.validDays, 28)
        XCTAssertTrue(history.allSatisfy { $0.state.tomorrowGuidance == nil })
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DailyBriefRecord>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<WeeklyBriefRecord>()), 0)
    }

    func testHealthHistoryRejectsInvalidAndOversizedRanges() throws {
        let container = try makeContainer()
        let service = HealthIntelligenceService(modelContainer: container)
        let start = Date(timeIntervalSince1970: 1_780_000_000)
        let tooLate = Calendar.current.date(byAdding: .day, value: 14, to: start)!

        XCTAssertThrowsError(try service.healthHistory(from: tooLate, through: start))
        XCTAssertThrowsError(try service.healthHistory(from: start, through: tooLate))
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(versionedSchema: DensosoSchemaV4.self)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    private func dayKey(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
