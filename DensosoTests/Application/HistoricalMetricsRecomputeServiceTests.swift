import DensosoDomain
import SwiftData
import XCTest
@testable import Densoso

@MainActor
final class HistoricalMetricsRecomputeServiceTests: XCTestCase {
    func testRecomputesOnlyExistingEligiblePendingMetricsWithinBatch() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let calendar = Calendar.current
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 12)))
        let today = calendar.startOfDay(for: now)
        try insertValidProfileAndWeight(in: context, effectiveAt: today)

        let oldestPendingDay = try XCTUnwrap(calendar.date(byAdding: .day, value: -2, to: today))
        let nextPendingDay = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: today))
        let nonPendingDay = try XCTUnwrap(calendar.date(byAdding: .day, value: -3, to: today))
        let outsideWindowDay = try XCTUnwrap(calendar.date(byAdding: .day, value: -100, to: today))
        let oldestPending = DailyMetrics(
            date: oldestPendingDay,
            totalExpenditureKcal: 1_700,
            energyQuality: "legacy",
            requiresRecompute: true
        )
        let nextPending = DailyMetrics(
            date: nextPendingDay,
            totalExpenditureKcal: 1_800,
            energyQuality: "legacy",
            requiresRecompute: true
        )
        let nonPending = DailyMetrics(
            date: nonPendingDay,
            energyQuality: "legacy",
            projectionVersion: AlgorithmVersions.dailyMetricsProjection,
            sourceFingerprint: "current-non-pending"
        )
        let outsideWindow = DailyMetrics(
            date: outsideWindowDay,
            totalExpenditureKcal: 1_600,
            energyQuality: "legacy",
            requiresRecompute: true
        )
        [oldestPending, nextPending, nonPending, outsideWindow].forEach(context.insert)
        try context.save()

        let service = HistoricalMetricsRecomputeService(modelContainer: container)
        let firstBatch = try await service.recomputePendingMetrics(
            now: now,
            batchSize: 1,
            shouldStop: { false }
        )

        XCTAssertEqual(firstBatch.processedCount, 1)
        XCTAssertTrue(firstBatch.hasMoreEligibleWork)
        XCTAssertFalse(firstBatch.stoppedEarly)

        let afterFirstBatch = try fetchMetrics(in: container)
        let firstResult = try XCTUnwrap(afterFirstBatch.first { Calendar.current.isDate($0.date, inSameDayAs: oldestPendingDay) })
        let secondResult = try XCTUnwrap(afterFirstBatch.first { Calendar.current.isDate($0.date, inSameDayAs: nextPendingDay) })
        let nonPendingResult = try XCTUnwrap(afterFirstBatch.first { Calendar.current.isDate($0.date, inSameDayAs: nonPendingDay) })
        let oldResult = try XCTUnwrap(afterFirstBatch.first { Calendar.current.isDate($0.date, inSameDayAs: outsideWindowDay) })
        XCTAssertFalse(firstResult.requiresRecompute)
        XCTAssertEqual(firstResult.energyQuality, "estimated")
        XCTAssertFalse(firstResult.sourceFingerprint.isEmpty)
        XCTAssertTrue(secondResult.requiresRecompute)
        XCTAssertFalse(nonPendingResult.requiresRecompute)
        XCTAssertTrue(oldResult.requiresRecompute)
        XCTAssertEqual(afterFirstBatch.count, 4)

        let secondBatch = try await service.recomputePendingMetrics(
            now: now,
            batchSize: 10,
            shouldStop: { false }
        )
        XCTAssertEqual(secondBatch.processedCount, 1)
        XCTAssertFalse(secondBatch.hasMoreEligibleWork)
        XCTAssertFalse(try XCTUnwrap(
            fetchMetrics(in: container).first { Calendar.current.isDate($0.date, inSameDayAs: nextPendingDay) }
        ).requiresRecompute)
    }

    func testStaleProjectionVersionIsDiscoveredWithoutPendingFlag() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let calendar = Calendar.current
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 12)))
        let today = calendar.startOfDay(for: now)
        try insertValidProfileAndWeight(in: context, effectiveAt: today)
        let day = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: today))
        context.insert(DailyMetrics(
            date: day,
            totalExpenditureKcal: 1_800,
            energyQuality: "estimated",
            projectionVersion: AlgorithmVersions.calorieAccounting,
            sourceFingerprint: "old-but-present-fingerprint",
            requiresRecompute: false
        ))
        try context.save()

        let result = try await HistoricalMetricsRecomputeService(modelContainer: container)
            .recomputePendingMetrics(now: now, batchSize: 10, shouldStop: { false })

        XCTAssertEqual(result.processedCount, 1)
        let projected = try XCTUnwrap(fetchMetrics(in: container).first)
        XCTAssertEqual(projected.projectionVersion, AlgorithmVersions.dailyMetricsProjection)
        XCTAssertNotEqual(projected.sourceFingerprint, "old-but-present-fingerprint")
        XCTAssertFalse(projected.requiresRecompute)
    }

    func testMissingDOBDoesNotLetObservedEnergyClearRecomputeFlag() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let calendar = Calendar.current
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 12)))
        let day = calendar.startOfDay(for: try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: now)))
        context.insert(ProfileRevisionRecord(
            effectiveFrom: try XCTUnwrap(calendar.date(byAdding: .day, value: -30, to: day)),
            dateOfBirth: nil,
            biologicalSex: "female",
            heightCm: 165,
            weightKg: 60,
            activityLevel: "moderate",
            source: "userEdited"
        ))
        try insertObservedEnergySnapshot(on: day, in: context)
        context.insert(unavailablePendingMetric(on: day))
        try context.save()

        let result = try await HistoricalMetricsRecomputeService(modelContainer: container)
            .recomputePendingMetrics(now: now, batchSize: 10, shouldStop: { false })

        XCTAssertEqual(result.processedCount, 0)
        XCTAssertFalse(result.hasMoreEligibleWork)
        try assertUnavailablePendingMetric(on: day, in: container)
    }

    func testOrdinaryHistoricalReprojectKeepsPendingFlagWhenDOBMissingWithObservedEnergy() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let calendar = Calendar.current
        let day = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: Date())))
        context.insert(ProfileRevisionRecord(
            effectiveFrom: try XCTUnwrap(calendar.date(byAdding: .day, value: -30, to: day)),
            dateOfBirth: nil,
            biologicalSex: "female",
            heightCm: 165,
            weightKg: 60,
            activityLevel: "moderate",
            source: "userEdited"
        ))
        try insertObservedEnergySnapshot(on: day, in: context)
        context.insert(unavailablePendingMetric(on: day))
        try context.save()

        try DailyMetricsProjector.reproject(on: day, in: context)

        try assertUnavailablePendingMetric(on: day, in: container)
    }

    func testCurrentDayReprojectRetainsObservedEnergyBehaviorWithoutProfileOrWeight() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: Date())
        try insertObservedEnergySnapshot(on: day, in: context)
        context.insert(unavailablePendingMetric(on: day))
        try context.save()

        try DailyMetricsProjector.reproject(on: day, in: context)
        try context.save()

        let projected = try XCTUnwrap(
            ModelContext(container).fetch(FetchDescriptor<DailyMetrics>(predicate: #Predicate { $0.date == day })).first
        )
        XCTAssertEqual(projected.energyQuality, "observed")
        XCTAssertEqual(projected.totalExpenditureKcal, 1_900)
        XCTAssertFalse(projected.requiresRecompute)
    }

    func testNewHistoricalProjectionWithoutRequiredInputsIsPersistedAsPending() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let calendar = Calendar.current
        let now = Date()
        let day = try XCTUnwrap(calendar.date(byAdding: .day, value: -2, to: calendar.startOfDay(for: now)))
        try insertObservedEnergySnapshot(on: day, in: context)

        try DailyMetricsProjector.reproject(on: day, now: now, in: context)
        try context.save()

        let projected = try XCTUnwrap(
            ModelContext(container).fetch(FetchDescriptor<DailyMetrics>(predicate: #Predicate { $0.date == day })).first
        )
        XCTAssertEqual(projected.energyQuality, "unavailable")
        XCTAssertTrue(projected.requiresRecompute)
        XCTAssertEqual(projected.totalExpenditureKcal, 0)
    }

    func testCurrentDayUsesProfileAndWeightAddedAfterMidnight() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let calendar = Calendar.current
        let now = Date()
        let day = calendar.startOfDay(for: now)
        context.insert(ProfileRevisionRecord(
            effectiveFrom: now.addingTimeInterval(-3_600),
            dateOfBirth: dateOfBirth(in: calendar),
            biologicalSex: "female",
            heightCm: 165,
            weightKg: nil,
            activityLevel: "moderate",
            source: "userEdited"
        ))
        context.insert(WeightRecord(
            sourceActionKey: "current-day-asof-weight-\(UUID().uuidString.lowercased())",
            measuredAt: now.addingTimeInterval(-1_800),
            kilograms: 62,
            source: "manual",
            algorithmVersion: "test",
            confidence: 0.9
        ))

        try DailyMetricsProjector.reproject(on: day, now: now, in: context)
        try context.save()

        let projected = try XCTUnwrap(
            ModelContext(container).fetch(FetchDescriptor<DailyMetrics>(predicate: #Predicate { $0.date == day })).first
        )
        XCTAssertEqual(projected.energyQuality, "estimated")
        XCTAssertFalse(projected.requiresRecompute)
        XCTAssertGreaterThan(projected.totalExpenditureKcal, 0)
    }

    func testHistoricalProjectionUsesProfileAndWeightEffectiveLaterThatDay() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let calendar = Calendar.current
        let now = Date()
        let day = try XCTUnwrap(calendar.date(byAdding: .day, value: -3, to: calendar.startOfDay(for: now)))
        let effectiveFrom = try XCTUnwrap(calendar.date(byAdding: .hour, value: 6, to: day))
        let measuredAt = try XCTUnwrap(calendar.date(byAdding: .hour, value: 8, to: day))
        context.insert(ProfileRevisionRecord(
            effectiveFrom: effectiveFrom,
            dateOfBirth: dateOfBirth(in: calendar),
            biologicalSex: "female",
            heightCm: 165,
            weightKg: nil,
            activityLevel: "moderate",
            source: "userEdited"
        ))
        context.insert(WeightRecord(
            sourceActionKey: "same-day-historical-weight-\(UUID().uuidString.lowercased())",
            measuredAt: measuredAt,
            kilograms: 62,
            source: "manual",
            algorithmVersion: "test",
            confidence: 0.9
        ))

        try DailyMetricsProjector.reproject(on: day, now: now, in: context)
        try context.save()

        let projected = try XCTUnwrap(
            ModelContext(container).fetch(FetchDescriptor<DailyMetrics>(predicate: #Predicate { $0.date == day })).first
        )
        XCTAssertEqual(projected.energyQuality, "estimated")
        XCTAssertFalse(projected.requiresRecompute)
        XCTAssertGreaterThan(projected.totalExpenditureKcal, 0)
    }

    func testProjectionReferenceUsesTodayAndHistoricalDayEndAcrossDST() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 9, hour: 12)))
        let today = calendar.startOfDay(for: now)
        let historicalDay = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 8)))

        XCTAssertEqual(
            HistoricalMetricsEligibilityPolicy.referenceDate(for: today, now: now, calendar: calendar),
            now
        )
        let historicalAsOf = HistoricalMetricsEligibilityPolicy.referenceDate(
            for: historicalDay,
            now: now,
            calendar: calendar
        )
        XCTAssertTrue(calendar.isDate(historicalAsOf, inSameDayAs: historicalDay))
        XCTAssertEqual(calendar.component(.hour, from: historicalAsOf), 23)
        XCTAssertLessThan(
            historicalAsOf,
            try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: historicalDay))
        )
    }

    func testMissingWeightDoesNotLetObservedEnergyClearRecomputeFlag() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let calendar = Calendar.current
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 12)))
        let day = calendar.startOfDay(for: try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: now)))
        context.insert(ProfileRevisionRecord(
            effectiveFrom: try XCTUnwrap(calendar.date(byAdding: .day, value: -30, to: day)),
            dateOfBirth: dateOfBirth(in: calendar),
            biologicalSex: "female",
            heightCm: 165,
            weightKg: nil,
            activityLevel: "moderate",
            source: "userEdited"
        ))
        try insertObservedEnergySnapshot(on: day, in: context)
        context.insert(unavailablePendingMetric(on: day))
        try context.save()

        let result = try await HistoricalMetricsRecomputeService(modelContainer: container)
            .recomputePendingMetrics(now: now, batchSize: 10, shouldStop: { false })

        XCTAssertEqual(result.processedCount, 0)
        XCTAssertFalse(result.hasMoreEligibleWork)
        try assertUnavailablePendingMetric(on: day, in: container)
    }

    func testCancellationStopsAfterSavedRowAndReportsRetryableWork() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let calendar = Calendar.current
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 12)))
        let today = calendar.startOfDay(for: now)
        try insertValidProfileAndWeight(in: context, effectiveAt: today)
        let earlierDay = try XCTUnwrap(calendar.date(byAdding: .day, value: -2, to: today))
        let laterDay = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: today))
        context.insert(DailyMetrics(date: earlierDay, requiresRecompute: true))
        context.insert(DailyMetrics(date: laterDay, requiresRecompute: true))
        try context.save()

        var stopChecks = 0
        let result = try await HistoricalMetricsRecomputeService(modelContainer: container)
            .recomputePendingMetrics(now: now, batchSize: 10) {
                stopChecks += 1
                return stopChecks >= 2
            }

        XCTAssertEqual(result.processedCount, 1)
        XCTAssertTrue(result.hasMoreEligibleWork)
        XCTAssertTrue(result.stoppedEarly)
        let metrics = try fetchMetrics(in: container)
        XCTAssertFalse(try XCTUnwrap(metrics.first { Calendar.current.isDate($0.date, inSameDayAs: earlierDay) }).requiresRecompute)
        XCTAssertTrue(try XCTUnwrap(metrics.first { Calendar.current.isDate($0.date, inSameDayAs: laterDay) }).requiresRecompute)
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(versionedSchema: DensosoSchemaV9.self)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    private func insertValidProfileAndWeight(in context: ModelContext, effectiveAt day: Date) throws {
        let calendar = Calendar.current
        let profileEffectiveFrom = try XCTUnwrap(calendar.date(byAdding: .day, value: -200, to: day))
        let weightMeasuredAt = try XCTUnwrap(calendar.date(byAdding: .day, value: -150, to: day))
        context.insert(ProfileRevisionRecord(
            effectiveFrom: profileEffectiveFrom,
            dateOfBirth: dateOfBirth(in: calendar),
            biologicalSex: "female",
            heightCm: 165,
            weightKg: nil,
            activityLevel: "moderate",
            source: "userEdited"
        ))
        context.insert(WeightRecord(
            sourceActionKey: "historical-recompute-weight-\(UUID().uuidString.lowercased())",
            measuredAt: weightMeasuredAt,
            kilograms: 62,
            source: "manual",
            algorithmVersion: "test",
            confidence: 0.9
        ))
    }

    private func dateOfBirth(in calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: 1985, month: 4, day: 10))!
    }

    private func unavailablePendingMetric(on day: Date) -> DailyMetrics {
        DailyMetrics(
            date: day,
            totalExpenditureKcal: 0,
            expenditureEnergyLowKcal: 0,
            expenditureEnergyLikelyKcal: 0,
            expenditureEnergyHighKcal: 0,
            energyQuality: "unavailable",
            sourceFingerprint: "unchanged",
            requiresRecompute: true
        )
    }

    private func insertObservedEnergySnapshot(on day: Date, in context: ModelContext) throws {
        let calendar = Calendar.current
        let readStates: [String: HealthReadState] = [
            HealthMetricID.activeEnergy.rawValue: .available,
            HealthMetricID.restingEnergy.rawValue: .available,
        ]
        let snapshot = DailyHealthSnapshot(
            dayStart: day,
            timezoneIdentifier: calendar.timeZone.identifier,
            activeEnergyKcal: 500,
            restingEnergyKcal: 1_400,
            healthReadStates: readStates,
            algorithmVersion: DailyHealthSnapshot.currentAlgorithmVersion
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        context.insert(DailyHealthSnapshotRecord(
            dayKey: dayKey(day, calendar: calendar),
            timezoneID: calendar.timeZone.identifier,
            payloadData: try encoder.encode(snapshot),
            snapshotHash: "historical-recompute-fixture",
            algorithmVersion: DailyHealthSnapshot.currentAlgorithmVersion
        ))
    }

    private func assertUnavailablePendingMetric(on day: Date, in container: ModelContainer) throws {
        let context = ModelContext(container)
        let predicate = #Predicate<DailyMetrics> { $0.date == day }
        let metric = try XCTUnwrap(context.fetch(FetchDescriptor<DailyMetrics>(predicate: predicate)).first)
        XCTAssertTrue(metric.requiresRecompute)
        XCTAssertEqual(metric.energyQuality, "unavailable")
        XCTAssertEqual(metric.totalExpenditureKcal, 0)
        XCTAssertEqual(metric.expenditureEnergyLikelyKcal, 0)
        XCTAssertEqual(metric.sourceFingerprint, "unchanged")
    }

    private func fetchMetrics(in container: ModelContainer) throws -> [DailyMetrics] {
        try ModelContext(container).fetch(FetchDescriptor<DailyMetrics>(sortBy: [SortDescriptor(\.date)]))
    }

    private func dayKey(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }
}
