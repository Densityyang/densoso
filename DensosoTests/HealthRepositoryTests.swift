import SwiftData
import XCTest
@testable import Densoso
import DensosoDomain

@MainActor
final class HealthRepositoryTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        container = try ModelContainer(
            for: UserProfile.self, MealRecord.self, DishEntry.self, WorkoutRecord.self, DailyMetrics.self,
                DailyHealthSnapshotRecord.self, WeightRecord.self, ProfileRevisionRecord.self,
                HealthSyncOutboxEntry.self, HealthKitImportCursor.self, HealthKitSampleIndexRecord.self,
                WeeklyReport.self, DailyBriefRecord.self, WeeklyBriefRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
        context.insert(UserProfile())
        try context.save()
    }

    func testProjectionAffectedDaysDeduplicatesAndSortsLocalDays() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let firstDay = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 20)))
        let secondDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: firstDay))
        let affectedDates: Set<Date> = [
            firstDay.addingTimeInterval(3_600),
            firstDay.addingTimeInterval(72_000),
            secondDay.addingTimeInterval(14_400),
        ]

        XCTAssertEqual(
            HealthRepository.affectedProjectionDays(from: affectedDates, calendar: calendar),
            [firstDay, secondDay]
        )
    }

    func testHealthKitSnapshotRebuildInvalidatesOverlappingWeeklyReportsAndPreservesManualSources() throws {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
        let start = try XCTUnwrap(calendar.date(byAdding: .day, value: -41, to: today))
        let end = today
        let inWindowDay = try XCTUnwrap(calendar.date(byAdding: .day, value: -3, to: today))
        let outsideDay = try XCTUnwrap(calendar.date(byAdding: .day, value: -14, to: start))
        let inWindowWeek = try XCTUnwrap(calendar.dateInterval(of: .weekOfYear, for: inWindowDay))
        let outsideWeek = try XCTUnwrap(calendar.dateInterval(of: .weekOfYear, for: outsideDay))
        let overlappingReport = WeeklyReport(
            weekStartDate: inWindowWeek.start,
            weekEndDate: inWindowWeek.end.addingTimeInterval(-1),
            totalDeficitKcal: 4_200
        )
        let outsideReport = WeeklyReport(
            weekStartDate: outsideWeek.start,
            weekEndDate: outsideWeek.end.addingTimeInterval(-1),
            totalDeficitKcal: 2_100
        )
        let meal = MealRecord(date: inWindowDay, totalCaloriesKcal: 500)
        let manualWeight = WeightRecord(
            sourceActionKey: "snapshot-rebuild-manual-weight",
            measuredAt: inWindowDay,
            kilograms: 68,
            source: "manual",
            algorithmVersion: "weight-v3"
        )
        context.insert(overlappingReport)
        context.insert(outsideReport)
        context.insert(meal)
        context.insert(manualWeight)
        try context.save()

        try HealthRepository(modelContext: context).prepareHealthKitSnapshotRebuild(
            for: [.stepCount],
            from: start,
            through: end
        )

        let reports = try context.fetch(FetchDescriptor<WeeklyReport>())
        XCTAssertEqual(reports.map(\.weekStartDate), [outsideWeek.start])
        XCTAssertTrue(try context.fetch(FetchDescriptor<MealRecord>()).contains(where: { $0.id == meal.id }))
        XCTAssertTrue(try context.fetch(FetchDescriptor<WeightRecord>()).contains(where: {
            $0.id == manualWeight.id && $0.source == "manual"
        }))
    }

    override func tearDown() {
        context = nil
        container = nil
        super.tearDown()
    }

    func testInsertAndDeleteReprojectsTheSameDay() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let repository = HealthRepository(modelContext: context)
        let meal = MealRecord(
            date: date,
            totalCaloriesKcal: 500,
            proteinG: 30,
            fatG: 10,
            carbsG: 70,
            evidenceData: try mealEvidenceData(grade: .userReported)
        )
        let workout = WorkoutRecord(date: date, type: "walking", durationMinutes: 30, estimatedCaloriesBurned: 120)

        try repository.insert(meal)
        let activeEnergyWithoutWorkout = try XCTUnwrap(context.fetch(FetchDescriptor<DailyMetrics>()).first?.activeCaloriesKcal)
        try repository.insert(workout)

        var metrics = try context.fetch(FetchDescriptor<DailyMetrics>())
        XCTAssertEqual(metrics.count, 1)
        XCTAssertEqual(metrics[0].mealCount, 1)
        XCTAssertEqual(metrics[0].workoutCount, 1)
        XCTAssertEqual(metrics[0].totalIntakeKcal, 500)
        XCTAssertEqual(metrics[0].activeCaloriesKcal, activeEnergyWithoutWorkout)
        XCTAssertEqual(try context.fetch(FetchDescriptor<HealthSyncOutboxEntry>()).count, 1)

        try repository.delete(meal)
        metrics = try context.fetch(FetchDescriptor<DailyMetrics>())
        XCTAssertEqual(metrics.count, 1)
        XCTAssertEqual(metrics[0].mealCount, 0)
        XCTAssertEqual(metrics[0].workoutCount, 1)
        XCTAssertEqual(metrics[0].totalIntakeKcal, 0)
        XCTAssertEqual(metrics[0].activeCaloriesKcal, activeEnergyWithoutWorkout)
        XCTAssertEqual(try context.fetch(FetchDescriptor<HealthSyncOutboxEntry>()).count, 2)
    }

    func testMeasuredDailyActivityAggregateFeedsProjectionWithoutWorkoutEnergy() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: now)
        let components = calendar.dateComponents([.year, .month, .day], from: day)
        let dayKey = String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
        let snapshot = DailyHealthSnapshot(
            dayStart: day,
            timezoneIdentifier: calendar.timeZone.identifier,
            activeEnergyKcal: 510,
            restingEnergyKcal: 1_420,
            healthReadStates: [
                HealthMetricID.activeEnergy.rawValue: .available,
                HealthMetricID.restingEnergy.rawValue: .available,
            ],
            algorithmVersion: DailyHealthSnapshot.currentAlgorithmVersion
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        context.insert(DailyHealthSnapshotRecord(
            dayKey: dayKey,
            timezoneID: calendar.timeZone.identifier,
            payloadData: try encoder.encode(snapshot),
            snapshotHash: "measured-energy-projection-fixture",
            algorithmVersion: snapshot.algorithmVersion
        ))
        context.insert(WorkoutRecord(
            date: now,
            type: "running",
            durationMinutes: 60,
            estimatedCaloriesBurned: 420
        ))

        try DailyMetricsProjector.reproject(on: day, now: now, in: context)

        let metrics = try XCTUnwrap(context.fetch(FetchDescriptor<DailyMetrics>()).first)
        XCTAssertEqual(metrics.bmrKcal, 1_420)
        XCTAssertEqual(metrics.activeCaloriesKcal, 510)
        XCTAssertEqual(metrics.totalExpenditureKcal, 1_930)
        XCTAssertEqual(metrics.energyQuality, "observed")
        XCTAssertEqual(metrics.workoutCount, 1)
    }

    func testLegacyPointEstimateIsNotProjectedAsCurrentIntakeOrMacros() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let meal = MealRecord(
            date: date,
            totalCaloriesKcal: 640,
            proteinG: 28,
            fatG: 18,
            carbsG: 75,
            energyLowKcal: 640,
            energyLikelyKcal: 640,
            energyHighKcal: 640,
            proteinLowG: 28,
            proteinLikelyG: 28,
            proteinHighG: 28,
            fatLowG: 18,
            fatLikelyG: 18,
            fatHighG: 18,
            carbsLowG: 75,
            carbsLikelyG: 75,
            carbsHighG: 75,
            evidenceData: try mealEvidenceData(grade: .legacyPointEstimate)
        )

        let projection = CaloricEngine.computeDailyMetrics(
            date: date,
            calendar: .current,
            meals: [meal],
            workouts: [],
            effectiveProfile: nil,
            effectiveWeight: nil
        )
        let readResult = DailyMetricsReadModelMapper.make(projection)

        XCTAssertEqual(projection.totalIntakeKcal, 0)
        XCTAssertEqual(readResult.coverage.intake.availableDays, 0)
        XCTAssertEqual(readResult.coverage.intake.unavailableDays, 1)
        XCTAssertNil(readResult.intake.value)
        XCTAssertNil(readResult.proteinG.value)
        XCTAssertNil(readResult.fatG.value)
        XCTAssertNil(readResult.carbsG.value)
        XCTAssertNil(readResult.deficit.value)
    }

    func testOutboxEnqueueReadsMatchingVersionsAndLatestReceiptAmongManyRows() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let recordID = UUID(uuidString: "00000000-0000-0000-0000-000000000601")!
        let syncIdentifier = "densoso.meal.\(recordID.uuidString.lowercased())"
        let olderReceiptID = UUID()
        let latestReceiptID = UUID()
        let otherTypeReceiptID = UUID()
        let olderWeightReceiptID = UUID()
        let latestWeightReceiptID = UUID()
        let meal = MealRecord(id: recordID, date: date, totalCaloriesKcal: 420)
        let weight = WeightRecord(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000602")!,
            sourceActionKey: "outbox-enqueue-weight",
            measuredAt: date.addingTimeInterval(60),
            kilograms: 69
        )
        context.insert(meal)
        context.insert(weight)
        context.insert(HealthSyncOutboxEntry(
            operation: "upsertMeal",
            recordID: recordID,
            receiptID: olderReceiptID,
            syncIdentifier: syncIdentifier,
            syncVersion: 3
        ))
        context.insert(HealthSyncOutboxEntry(
            operation: "upsertMeal",
            recordID: recordID,
            receiptID: latestReceiptID,
            syncIdentifier: syncIdentifier,
            syncVersion: 7
        ))
        context.insert(HealthSyncOutboxEntry(
            operation: "deleteMeal",
            recordID: recordID,
            syncIdentifier: syncIdentifier,
            syncVersion: 8
        ))
        context.insert(HealthSyncOutboxEntry(
            operation: "upsertWeight",
            recordID: recordID,
            receiptID: otherTypeReceiptID,
            syncIdentifier: "densoso.weight.\(recordID.uuidString.lowercased())",
            syncVersion: 99
        ))
        context.insert(HealthSyncOutboxEntry(
            operation: "upsertWeight",
            recordID: weight.id,
            receiptID: olderWeightReceiptID,
            syncIdentifier: "densoso.weight.\(weight.id.uuidString.lowercased())",
            syncVersion: 4
        ))
        context.insert(HealthSyncOutboxEntry(
            operation: "deleteWeight",
            recordID: weight.id,
            syncIdentifier: "densoso.weight.\(weight.id.uuidString.lowercased())",
            syncVersion: 6
        ))
        context.insert(HealthSyncOutboxEntry(
            operation: "upsertWeight",
            recordID: weight.id,
            receiptID: latestWeightReceiptID,
            syncIdentifier: "densoso.weight.\(weight.id.uuidString.lowercased())",
            syncVersion: 5
        ))
        context.insert(HealthSyncOutboxEntry(
            operation: "upsertMeal",
            recordID: weight.id,
            receiptID: otherTypeReceiptID,
            syncIdentifier: "densoso.meal.\(weight.id.uuidString.lowercased())",
            syncVersion: 999
        ))
        for index in 0..<200 {
            context.insert(HealthSyncOutboxEntry(
                operation: "upsertMeal",
                recordID: UUID(),
                receiptID: UUID(),
                syncVersion: 1_000 + index
            ))
        }
        try context.save()

        let repository = HealthRepository(modelContext: context)
        try repository.update(meal)
        try repository.update(weight)

        let targetPredicate = #Predicate<HealthSyncOutboxEntry> { $0.recordID == recordID }
        let targetEntries = try context.fetch(FetchDescriptor<HealthSyncOutboxEntry>(predicate: targetPredicate))
        let appended = try XCTUnwrap(targetEntries.first { $0.syncVersion == 9 })
        XCTAssertEqual(appended.operation, "upsertMeal")
        XCTAssertEqual(appended.syncIdentifier, syncIdentifier)
        XCTAssertEqual(appended.receiptID, latestReceiptID)
        XCTAssertEqual(targetEntries.count, 5)

        let weightRecordID = weight.id
        let weightPredicate = #Predicate<HealthSyncOutboxEntry> { $0.recordID == weightRecordID }
        let weightEntries = try context.fetch(FetchDescriptor<HealthSyncOutboxEntry>(predicate: weightPredicate))
        let appendedWeight = try XCTUnwrap(weightEntries.first { $0.syncVersion == 7 })
        XCTAssertEqual(appendedWeight.operation, "upsertWeight")
        XCTAssertEqual(appendedWeight.receiptID, latestWeightReceiptID)
        XCTAssertEqual(weightEntries.count, 5)
    }

    func testConfirmedFoodHistoryRepositoryPagesMealsAndDeduplicatesFoodIDs() async throws {
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let mealCount = ConfirmedFoodHistoryReadLimits.mealPageSize + 1
        let amount = try EstimateRange.point(1)
        let nutrients = NutrientEstimate(energyKcal: amount)

        for index in 0..<mealCount {
            let meal = MealRecord(date: baseDate.addingTimeInterval(Double(index)))
            meal.createdAt = baseDate.addingTimeInterval(Double(index))
            let foodID = index == mealCount - 1 ? "later-page-only" : "shared-\(index % 3)"
            let ingredientData = try JSONEncoder().encode([
                MealIngredientDraft(
                    foodID: foodID,
                    name: "燕麦",
                    amountGrams: amount,
                    nutrients: nutrients
                ),
            ])
            let dish = DishEntry(
                dishName: "燕麦",
                ingredientJSON: String(decoding: ingredientData, as: UTF8.self)
            )
            meal.dishes = [dish]
            context.insert(meal)
            context.insert(dish)
        }
        try context.save()

        let repository = SwiftDataConfirmedFoodHistoryRepository(modelContainer: container)
        let identifiers = try await repository.confirmedFoodIDs(matching: "燕麦")

        XCTAssertEqual(identifiers, Set(["shared-0", "shared-1", "shared-2", "later-page-only"]))
    }

    func testDeletingLatestSameDayWeightFallsBackToNextLocalThenHealthKitWeight() throws {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
        let morning = try XCTUnwrap(calendar.date(bySettingHour: 8, minute: 0, second: 0, of: day))
        let afternoon = try XCTUnwrap(calendar.date(bySettingHour: 17, minute: 0, second: 0, of: day))
        let importedAt = try XCTUnwrap(calendar.date(bySettingHour: 19, minute: 0, second: 0, of: day))
        let importedSample = HealthSampleSnapshot(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000061")!,
            metric: .bodyMass,
            startDate: importedAt,
            endDate: importedAt,
            value: 68
        )
        let snapshot = DailyHealthSnapshot(
            dayStart: day,
            timezoneIdentifier: calendar.timeZone.identifier,
            weightKilograms: 67,
            healthKitSampleSummary: DailyHealthSampleSummary(samples: [importedSample], dayStart: day),
            healthReadStates: [HealthMetricID.bodyMass.rawValue: .available],
            algorithmVersion: "daily-weight-delete-fixture"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        context.insert(DailyHealthSnapshotRecord(
            dayKey: Self.dayKey(day),
            timezoneID: calendar.timeZone.identifier,
            payloadData: try encoder.encode(snapshot),
            snapshotHash: "daily-weight-delete-fixture",
            algorithmVersion: snapshot.algorithmVersion
        ))

        let morningWeight = WeightRecord(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000062")!,
            sourceActionKey: "daily-weight-morning",
            measuredAt: morning,
            kilograms: 70
        )
        let tiedLowerIDWeight = WeightRecord(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000063")!,
            sourceActionKey: "daily-weight-tied-lower-id",
            measuredAt: afternoon,
            kilograms: 72
        )
        let tiedHigherIDWeight = WeightRecord(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000064")!,
            sourceActionKey: "daily-weight-tied-higher-id",
            measuredAt: afternoon,
            kilograms: 73
        )
        context.insert(morningWeight)
        context.insert(tiedLowerIDWeight)
        context.insert(tiedHigherIDWeight)
        try context.save()

        let repository = HealthRepository(modelContext: context)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        func savedWeight() throws -> Double? {
            let record = try XCTUnwrap(context.fetch(FetchDescriptor<DailyHealthSnapshotRecord>()).first)
            return try decoder.decode(DailyHealthSnapshot.self, from: record.payloadData).weightKilograms
        }

        try repository.delete(tiedHigherIDWeight)
        XCTAssertEqual(try savedWeight(), 72)

        try repository.delete(tiedLowerIDWeight)
        XCTAssertEqual(try savedWeight(), 70)

        try repository.delete(morningWeight)
        XCTAssertEqual(try savedWeight(), 68)
    }

    func testProjectionUsesEffectiveProfileAndHistoricalWeightWithoutBorrowingFutureData() throws {
        let calendar = Calendar.current
        let targetDate = Date(timeIntervalSince1970: 1_700_000_000)
        let targetDay = calendar.startOfDay(for: targetDate)
        let twoDaysLater = calendar.date(byAdding: .day, value: 2, to: targetDay)!
        let threeDaysLater = calendar.date(byAdding: .day, value: 3, to: targetDay)!
        let tenDaysLater = calendar.date(byAdding: .day, value: 10, to: targetDay)!
        let twentyDaysLater = calendar.date(byAdding: .day, value: 20, to: targetDay)!
        let birthDate = Date(timeIntervalSince1970: 315_532_800)
        context.insert(ProfileRevisionRecord(
            profileKey: "primary",
            effectiveFrom: calendar.date(byAdding: .day, value: -365, to: targetDay)!,
            dateOfBirth: birthDate,
            biologicalSex: "female",
            heightCm: 165,
            weightKg: 70,
            activityLevel: "moderate",
            source: "userEdited"
        ))
        context.insert(ProfileRevisionRecord(
            profileKey: "primary",
            effectiveFrom: tenDaysLater,
            dateOfBirth: birthDate,
            biologicalSex: "female",
            heightCm: 165,
            weightKg: 85,
            activityLevel: "active",
            source: "userEdited"
        ))
        context.insert(WeightRecord(
            sourceActionKey: "projection-historical-weight",
            measuredAt: twoDaysLater,
            kilograms: 65
        ))
        context.insert(WeightRecord(
            sourceActionKey: "projection-future-weight",
            measuredAt: calendar.date(byAdding: .day, value: 50, to: targetDay)!,
            kilograms: 95
        ))

        let futureBodyMass = HealthSampleSnapshot(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000025")!,
            metric: .bodyMass,
            startDate: twentyDaysLater,
            endDate: twentyDaysLater,
            value: 120
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        for (day, activeEnergy, samples) in [
            (targetDay, 500.0, [HealthSampleSnapshot]()),
            (twentyDaysLater, 999.0, [futureBodyMass]),
        ] {
            let snapshot = DailyHealthSnapshot(
                dayStart: day,
                timezoneIdentifier: calendar.timeZone.identifier,
                activeEnergyKcal: activeEnergy,
                healthKitSamples: samples,
                healthReadStates: [HealthMetricID.activeEnergy.rawValue: .available],
                algorithmVersion: "projector-boundary-fixture"
            )
            context.insert(DailyHealthSnapshotRecord(
                dayKey: Self.dayKey(day),
                timezoneID: snapshot.timezoneIdentifier,
                payloadData: try encoder.encode(snapshot),
                snapshotHash: "projector-\(activeEnergy)",
                algorithmVersion: snapshot.algorithmVersion
            ))
        }
        try context.save()

        let repository = HealthRepository(modelContext: context)
        try repository.insert(WorkoutRecord(date: targetDay))
        let firstMetric = try XCTUnwrap(context.fetch(FetchDescriptor<DailyMetrics>()).first {
            calendar.isDate($0.date, inSameDayAs: targetDay)
        })
        XCTAssertEqual(firstMetric.weightKg, 70)
        XCTAssertEqual(firstMetric.activeCaloriesKcal, 500)

        try repository.insert(WorkoutRecord(date: threeDaysLater))
        let laterMetric = try XCTUnwrap(context.fetch(FetchDescriptor<DailyMetrics>()).first {
            calendar.isDate($0.date, inSameDayAs: threeDaysLater)
        })
        XCTAssertEqual(laterMetric.weightKg, 65)
    }

    func testHealthKitWeightProjectionPagesIndexRowsAndSkipsUnknownDays() throws {
        let calendar = Calendar.current
        let targetDay = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
        let olderDay = calendar.date(byAdding: .day, value: -200, to: targetDay)!
        let tombstoneDay = calendar.date(byAdding: .day, value: -140, to: targetDay)!
        let unknownDay = calendar.date(byAdding: .day, value: -150, to: targetDay)!
        let olderSample = HealthSampleSnapshot(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000039")!,
            metric: .bodyMass,
            startDate: calendar.date(byAdding: .hour, value: 12, to: olderDay)!,
            endDate: calendar.date(byAdding: .hour, value: 12, to: olderDay)!,
            value: 70
        )
        let deletedSample = HealthSampleSnapshot(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000000003B")!,
            metric: .bodyMass,
            startDate: calendar.date(byAdding: .hour, value: 12, to: tombstoneDay)!,
            endDate: calendar.date(byAdding: .hour, value: 12, to: tombstoneDay)!,
            value: 88
        )
        let unknownSample = HealthSampleSnapshot(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000000003A")!,
            metric: .bodyMass,
            startDate: calendar.date(byAdding: .hour, value: 12, to: unknownDay)!,
            endDate: calendar.date(byAdding: .hour, value: 12, to: unknownDay)!,
            value: 95
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        for (day, sample, state) in [
            (olderDay, olderSample, HealthReadState.available),
            (tombstoneDay, deletedSample, HealthReadState.available),
            (unknownDay, unknownSample, HealthReadState.dataUnavailableOrReadScopeUnknown),
        ] {
            let snapshot = DailyHealthSnapshot(
                dayStart: day,
                timezoneIdentifier: calendar.timeZone.identifier,
                healthKitSampleSummary: DailyHealthSampleSummary(samples: [sample], dayStart: day),
                healthReadStates: [HealthMetricID.bodyMass.rawValue: state],
                algorithmVersion: DailyHealthSnapshot.currentAlgorithmVersion
            )
            context.insert(DailyHealthSnapshotRecord(
                dayKey: Self.dayKey(day),
                timezoneID: snapshot.timezoneIdentifier,
                payloadData: try encoder.encode(snapshot),
                snapshotHash: "weight-index-\(Self.dayKey(day))",
                algorithmVersion: snapshot.algorithmVersion
            ))
        }
        context.insert(HealthKitSampleIndexRecord(
            sampleID: olderSample.id,
            stream: HealthMetricID.bodyMass.rawValue,
            dayKey: Self.dayKey(olderDay),
            startDate: olderSample.startDate,
            endDate: olderSample.endDate
        ))
        context.insert(HealthKitSampleIndexRecord(
            sampleID: deletedSample.id,
            stream: HealthMetricID.bodyMass.rawValue,
            dayKey: Self.dayKey(tombstoneDay),
            startDate: deletedSample.startDate,
            endDate: deletedSample.endDate,
            needsRequery: true,
            pendingDayKeys: [Self.dayKey(tombstoneDay)],
            isTombstoned: true
        ))
        context.insert(HealthKitSampleIndexRecord(
            sampleID: unknownSample.id,
            stream: HealthMetricID.bodyMass.rawValue,
            dayKey: Self.dayKey(unknownDay),
            startDate: unknownSample.startDate,
            endDate: unknownSample.endDate,
            needsRequery: true,
            pendingDayKeys: [Self.dayKey(unknownDay)]
        ))
        for offset in 1...130 {
            let day = calendar.date(byAdding: .day, value: -offset, to: targetDay)!
            let measuredAt = calendar.date(byAdding: .hour, value: 12, to: day)!
            context.insert(HealthKitSampleIndexRecord(
                sampleID: UUID(),
                stream: HealthMetricID.bodyMass.rawValue,
                dayKey: Self.dayKey(day),
                startDate: measuredAt,
                endDate: measuredAt,
                needsRequery: true,
                pendingDayKeys: [Self.dayKey(day)]
            ))
        }
        try context.save()

        try DailyMetricsProjector.reproject(on: targetDay, in: context)

        let metric = try XCTUnwrap(context.fetch(FetchDescriptor<DailyMetrics>()).first)
        XCTAssertEqual(metric.weightKg, 70)
    }

    func testBodyMassReplacementPrefersLatestSameDayLocalWeightOverHealthKitSummary() throws {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
        let morning = try XCTUnwrap(calendar.date(bySettingHour: 8, minute: 0, second: 0, of: day))
        let afternoon = try XCTUnwrap(calendar.date(bySettingHour: 17, minute: 0, second: 0, of: day))
        let importedAt = try XCTUnwrap(calendar.date(bySettingHour: 19, minute: 0, second: 0, of: day))
        let sample = HealthSampleSnapshot(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000065")!,
            metric: .bodyMass,
            startDate: importedAt,
            endDate: importedAt,
            value: 75
        )
        context.insert(WeightRecord(
            sourceActionKey: "replacement-weight-morning",
            measuredAt: morning,
            kilograms: 70
        ))
        context.insert(WeightRecord(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000066")!,
            sourceActionKey: "replacement-weight-tied-lower-id",
            measuredAt: afternoon,
            kilograms: 72
        ))
        context.insert(WeightRecord(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000067")!,
            sourceActionKey: "replacement-weight-tied-higher-id",
            measuredAt: afternoon,
            kilograms: 73
        ))
        try context.save()

        try HealthRepository(modelContext: context).applyImportedHealthSamples(
            HealthSamplePage(
                samples: [sample],
                nextAnchorData: Data([1]),
                readState: .available
            ),
            stream: HealthMetricID.bodyMass.rawValue,
            lastSuccessfulAt: importedAt,
            lookbackStart: day,
            replacements: [HealthSampleDaySnapshot(dayStart: day, samples: [sample], readState: .available)]
        )

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let record = try XCTUnwrap(context.fetch(FetchDescriptor<DailyHealthSnapshotRecord>()).first)
        let updated = try decoder.decode(DailyHealthSnapshot.self, from: record.payloadData)
        XCTAssertEqual(updated.healthKitSampleSummary?.aggregate(for: .bodyMass)?.latestValue, 75)
        XCTAssertEqual(updated.weightKilograms, 73)
    }

    func testWorkoutEffortReprojectionPagesSameDayWorkoutsAcross64RowBoundary() throws {
        let day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
        var targetWorkoutID: UUID?
        var targetWorkoutStart: Date?
        for index in 0..<65 {
            let workoutStart = day.addingTimeInterval(TimeInterval(index * 600))
            let workout = WorkoutRecord(date: workoutStart, type: "walking", durationMinutes: 5)
            context.insert(workout)
            if index == 64 {
                targetWorkoutID = workout.id
                targetWorkoutStart = workoutStart
            }
        }
        try context.save()

        let workoutID = try XCTUnwrap(targetWorkoutID)
        let workoutStart = try XCTUnwrap(targetWorkoutStart)
        let sample = HealthSampleSnapshot(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000068")!,
            metric: .workoutEffort,
            startDate: workoutStart,
            endDate: workoutStart.addingTimeInterval(5 * 60),
            value: 8
        )
        try HealthRepository(modelContext: context).applyImportedHealthSamples(
            HealthSamplePage(samples: [sample], nextAnchorData: Data([1]), readState: .available),
            stream: HealthMetricID.workoutEffort.rawValue,
            lastSuccessfulAt: sample.endDate,
            lookbackStart: day,
            replacements: [HealthSampleDaySnapshot(
                dayStart: day,
                samples: [sample],
                readState: .available
            )]
        )

        let record = try XCTUnwrap(context.fetch(FetchDescriptor<DailyHealthSnapshotRecord>()).first)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let snapshot = try decoder.decode(DailyHealthSnapshot.self, from: record.payloadData)
        XCTAssertEqual(snapshot.healthKitSampleSummary?.workoutEffort.map(\.workoutRecordID), [workoutID])
        XCTAssertEqual(snapshot.healthKitSampleSummary?.effortScore(for: workoutID), 8)
    }

    func testLocalWeightProjectionPagesAndPreservesLatestIDTieWinner() throws {
        let calendar = Calendar.current
        let targetDay = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
        for offset in 1...130 {
            let day = calendar.date(byAdding: .day, value: -offset, to: targetDay)!
            context.insert(WeightRecord(
                sourceActionKey: "invalid-source-\(offset)",
                measuredAt: calendar.date(byAdding: .hour, value: 12, to: day)!,
                kilograms: 88,
                source: "unrecognized",
                confidence: 0.9
            ))
        }
        let tiedAt = calendar.date(byAdding: .day, value: -200, to: targetDay)!
            .addingTimeInterval(12 * 60 * 60)
        context.insert(WeightRecord(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000051")!,
            sourceActionKey: "valid-lower-id",
            measuredAt: tiedAt,
            kilograms: 65,
            source: "manual",
            confidence: 0.9
        ))
        context.insert(WeightRecord(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000052")!,
            sourceActionKey: "valid-higher-id",
            measuredAt: tiedAt,
            kilograms: 66,
            source: "manual",
            confidence: 0.9
        ))
        try context.save()

        try DailyMetricsProjector.reproject(on: targetDay, in: context)

        let metric = try XCTUnwrap(context.fetch(FetchDescriptor<DailyMetrics>()).first)
        XCTAssertEqual(metric.weightKg, 66)
    }

    func testImportedWorkoutDeduplicatesByHealthKitUUIDAndPersistsAnchor() throws {
        let repository = HealthRepository(modelContext: context)
        let healthKitUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000020")!
        let logicalSessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000021")!
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let first = try WorkoutSnapshot(
            healthKitUUID: healthKitUUID,
            logicalSessionID: logicalSessionID,
            startedAt: date,
            duration: 1_800,
            activityType: "running",
            energyInput: .init(measuredKilocalories: 250),
            origin: .watchHealthKit,
            sourceBundleIdentifier: "com.densoso.densoso",
            dataQuality: .complete
        )
        let updated = try WorkoutSnapshot(
            healthKitUUID: healthKitUUID,
            logicalSessionID: logicalSessionID,
            startedAt: date,
            duration: 1_800,
            activityType: "running",
            energyInput: .init(measuredKilocalories: 275),
            origin: .watchHealthKit,
            sourceBundleIdentifier: "com.densoso.densoso",
            dataQuality: .complete
        )

        let priorDay = Calendar.current.date(byAdding: .day, value: -2, to: date)!
        let duplicateDay = Calendar.current.date(byAdding: .day, value: -1, to: date)!
        let otherHealthKitUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000022")!
        let olderCopy = WorkoutRecord(date: priorDay, type: "old-copy", notes: "preferred", healthKitUUID: healthKitUUID)
        olderCopy.createdAt = Date(timeIntervalSince1970: 1_699_900_000)
        let newerCopy = WorkoutRecord(date: duplicateDay, type: "duplicate-copy", notes: "discarded", healthKitUUID: healthKitUUID)
        newerCopy.createdAt = Date(timeIntervalSince1970: 1_699_950_000)
        let unrelatedDay = Calendar.current.date(byAdding: .day, value: 5, to: date)!
        let unrelatedDuplicateDay = Calendar.current.date(byAdding: .day, value: 6, to: date)!
        let unrelatedOlderCopy = WorkoutRecord(
            date: unrelatedDay,
            notes: "unrelated-preferred",
            healthKitUUID: otherHealthKitUUID
        )
        unrelatedOlderCopy.createdAt = Date(timeIntervalSince1970: 1_699_800_000)
        let unrelatedNewerCopy = WorkoutRecord(
            date: unrelatedDuplicateDay,
            notes: "unrelated-discarded",
            healthKitUUID: otherHealthKitUUID
        )
        unrelatedNewerCopy.createdAt = Date(timeIntervalSince1970: 1_699_850_000)
        let manualWorkout = WorkoutRecord(date: unrelatedDay, type: "manual")
        context.insert(newerCopy)
        context.insert(olderCopy)
        context.insert(unrelatedNewerCopy)
        context.insert(unrelatedOlderCopy)
        context.insert(manualWorkout)
        try context.save()

        try repository.applyImportedWorkouts([first, updated], deletedHealthKitUUIDs: [], nextAnchorData: Data([1]))

        let workouts = try context.fetch(FetchDescriptor<WorkoutRecord>())
        let importedWorkouts = workouts.filter { $0.healthKitUUID == healthKitUUID }
        XCTAssertEqual(importedWorkouts.count, 1)
        XCTAssertEqual(importedWorkouts[0].notes, "preferred")
        XCTAssertEqual(importedWorkouts[0].date, date)
        XCTAssertEqual(importedWorkouts[0].logicalSessionID, logicalSessionID)
        XCTAssertEqual(importedWorkouts[0].estimatedCaloriesBurned, 275)
        XCTAssertEqual(importedWorkouts[0].energySource, WorkoutEnergySource.measured.rawValue)
        let unrelatedWorkouts = workouts.filter { $0.healthKitUUID == otherHealthKitUUID }
        XCTAssertEqual(unrelatedWorkouts.count, 1)
        XCTAssertEqual(unrelatedWorkouts.first?.notes, "unrelated-preferred")
        XCTAssertTrue(workouts.contains { $0.id == manualWorkout.id && $0.healthKitUUID == nil })
        XCTAssertEqual(try repository.cursor(for: "workouts")?.anchorData, Data([1]))
        XCTAssertEqual(try context.fetch(FetchDescriptor<HealthSyncOutboxEntry>()).count, 0)
        XCTAssertEqual(importedWorkouts.first?.routeStatus, "unavailable")
        let metricsByDay = Dictionary(
            uniqueKeysWithValues: try context.fetch(FetchDescriptor<DailyMetrics>()).map { ($0.date, $0.workoutCount) }
        )
        XCTAssertEqual(metricsByDay[Calendar.current.startOfDay(for: priorDay)], 0)
        XCTAssertEqual(metricsByDay[Calendar.current.startOfDay(for: duplicateDay)], 0)
        XCTAssertEqual(metricsByDay[Calendar.current.startOfDay(for: date)], 1)
        XCTAssertEqual(metricsByDay[Calendar.current.startOfDay(for: unrelatedDay)], 2)
        XCTAssertEqual(metricsByDay[Calendar.current.startOfDay(for: unrelatedDuplicateDay)], 0)

        try repository.applyImportedWorkouts([], deletedHealthKitUUIDs: [healthKitUUID], nextAnchorData: Data([2]))

        XCTAssertEqual(try context.fetch(FetchDescriptor<WorkoutRecord>()).filter {
            $0.healthKitUUID == healthKitUUID
        }.count, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<WorkoutRecord>()).filter {
            $0.healthKitUUID == otherHealthKitUUID
        }.count, 1)
        XCTAssertTrue(try context.fetch(FetchDescriptor<WorkoutRecord>()).contains {
            $0.id == manualWorkout.id && $0.healthKitUUID == nil
        })
        XCTAssertEqual(try repository.cursor(for: "workouts")?.anchorData, Data([2]))
        let metrics = try context.fetch(FetchDescriptor<DailyMetrics>())
        XCTAssertEqual(metrics.first(where: { Calendar.current.isDate($0.date, inSameDayAs: date) })?.workoutCount, 0)
    }

    func testImportedWorkoutDedupProcessesUUIDGroupsAcrossFetchBatchBoundary() throws {
        let repository = HealthRepository(modelContext: context)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        for value in 1...399 {
            let healthKitUUID = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
            context.insert(WorkoutRecord(
                date: date,
                type: "unique-\(value)",
                healthKitUUID: healthKitUUID
            ))
        }

        let repeatedUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000400")!
        let preferred = WorkoutRecord(
            date: date,
            type: "preferred",
            notes: "older-created-row",
            healthKitUUID: repeatedUUID
        )
        preferred.createdAt = Date(timeIntervalSince1970: 100)
        let duplicate = WorkoutRecord(
            date: date,
            type: "duplicate",
            notes: "newer-created-row",
            healthKitUUID: repeatedUUID
        )
        duplicate.createdAt = Date(timeIntervalSince1970: 200)
        context.insert(preferred)
        context.insert(duplicate)
        try context.save()

        try repository.applyImportedWorkouts([], deletedHealthKitUUIDs: [], nextAnchorData: Data([9]))

        let stored = try context.fetch(FetchDescriptor<WorkoutRecord>())
        XCTAssertEqual(stored.count, 400)
        let repeatedRows = stored.filter { $0.healthKitUUID == repeatedUUID }
        XCTAssertEqual(repeatedRows.count, 1)
        XCTAssertEqual(repeatedRows.first?.id, preferred.id)
        XCTAssertEqual(repeatedRows.first?.notes, "older-created-row")
        XCTAssertEqual(try repository.cursor(for: "workouts")?.anchorData, Data([9]))
    }

    func testImportedWorkoutAndAnchorRollbackTogetherWhenSaveFails() throws {
        let repository = HealthRepository(modelContext: context, willSave: { throw TestSaveError.injected })
        let snapshot = try WorkoutSnapshot(
            healthKitUUID: UUID(uuidString: "00000000-0000-0000-0000-000000000023")!,
            logicalSessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000024")!,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            duration: 1_800,
            activityType: "running",
            energyInput: .init(measuredKilocalories: 250),
            origin: .watchHealthKit,
            sourceBundleIdentifier: "com.densoso.densoso",
            dataQuality: .complete
        )

        XCTAssertThrowsError(try repository.applyImportedWorkouts(
            [snapshot], deletedHealthKitUUIDs: [], nextAnchorData: Data([7])
        ))
        XCTAssertTrue(try context.fetch(FetchDescriptor<WorkoutRecord>()).isEmpty)
        XCTAssertNil(try repository.cursor(for: "workouts"))
        XCTAssertTrue(try context.fetch(FetchDescriptor<DailyMetrics>()).isEmpty)
    }

    func testCursorAndSampleProjectionRollbackTogetherWhenSaveFails() throws {
        let repository = HealthRepository(modelContext: context, willSave: { throw TestSaveError.injected })
        let sample = HealthSampleSnapshot(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000030")!,
            metric: .bodyMass,
            startDate: Date(timeIntervalSince1970: 1_700_000_000),
            endDate: Date(timeIntervalSince1970: 1_700_000_000),
            value: 71.5
        )
        let page = HealthSamplePage(
            samples: [sample],
            nextAnchorData: Data([3]),
            readState: .available
        )

        let day = Calendar.current.startOfDay(for: sample.startDate)
        XCTAssertThrowsError(try repository.applyImportedHealthSamples(
            page,
            stream: "bodyMass",
            lastSuccessfulAt: Date(),
            lookbackStart: nil,
            replacements: [HealthSampleDaySnapshot(dayStart: day, samples: [sample], readState: .available)]
        ))
        XCTAssertNil(try repository.cursor(for: "bodyMass"))
        XCTAssertTrue(try context.fetch(FetchDescriptor<DailyHealthSnapshotRecord>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<DailyMetrics>()).isEmpty)
    }

    func testHealthSamplePagesUpdateDeleteAndDeduplicateByHealthKitUUID() throws {
        let repository = HealthRepository(modelContext: context)
        let sampleID = UUID(uuidString: "00000000-0000-0000-0000-000000000031")!
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let first = HealthSampleSnapshot(id: sampleID, metric: .bodyMass, startDate: date, endDate: date, value: 70)
        let updated = HealthSampleSnapshot(id: sampleID, metric: .bodyMass, startDate: date, endDate: date, value: 71)

        try repository.applyImportedHealthSamples(
            HealthSamplePage(samples: [first], nextAnchorData: Data([1]), readState: .available),
            stream: "bodyMass",
            lastSuccessfulAt: Date(),
            lookbackStart: date,
            replacements: [HealthSampleDaySnapshot(
                dayStart: Calendar.current.startOfDay(for: date),
                samples: [first],
                readState: .available
            )]
        )
        try repository.applyImportedHealthSamples(
            HealthSamplePage(samples: [updated, updated], nextAnchorData: Data([2]), readState: .available),
            stream: "bodyMass",
            lastSuccessfulAt: Date(),
            lookbackStart: date,
            replacements: [HealthSampleDaySnapshot(
                dayStart: Calendar.current.startOfDay(for: date),
                samples: [updated],
                readState: .available
            )]
        )

        let stored = try XCTUnwrap(context.fetch(FetchDescriptor<DailyHealthSnapshotRecord>()).first)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let snapshot = try decoder.decode(DailyHealthSnapshot.self, from: stored.payloadData)
        XCTAssertNil(snapshot.healthKitSamples)
        XCTAssertEqual(snapshot.healthKitSampleSummary?.aggregate(for: .bodyMass)?.sampleCount, 1)
        XCTAssertEqual(snapshot.healthKitSampleSummary?.aggregate(for: .bodyMass)?.latestValue, 71)
        XCTAssertEqual(snapshot.weightKilograms, 71)
        XCTAssertEqual(try context.fetch(FetchDescriptor<HealthKitSampleIndexRecord>()).count, 1)
        XCTAssertEqual(try repository.cursor(for: "bodyMass")?.anchorData, Data([2]))

        try repository.applyImportedHealthSamples(
            HealthSamplePage(samples: [], deletedSampleIDs: [sampleID], nextAnchorData: Data([3]), readState: .available),
            stream: "bodyMass",
            lastSuccessfulAt: Date(),
            lookbackStart: date,
            replacements: [HealthSampleDaySnapshot(
                dayStart: Calendar.current.startOfDay(for: date),
                samples: [],
                readState: .available
            )]
        )
        let afterDeletion = try decoder.decode(DailyHealthSnapshot.self, from: XCTUnwrap(
            context.fetch(FetchDescriptor<DailyHealthSnapshotRecord>()).first
        ).payloadData)
        XCTAssertNil(afterDeletion.healthKitSamples)
        XCTAssertNil(afterDeletion.healthKitSampleSummary?.aggregate(for: .bodyMass))
        XCTAssertNil(afterDeletion.weightKilograms)
        XCTAssertTrue(try context.fetch(FetchDescriptor<HealthKitSampleIndexRecord>()).isEmpty)
        XCTAssertEqual(try repository.cursor(for: "bodyMass")?.anchorData, Data([3]))

        try repository.applyImportedHealthSamples(
            HealthSamplePage(samples: [], nextAnchorData: Data([4]), readState: .dataUnavailableOrReadScopeUnknown),
            stream: "bodyMass",
            lastSuccessfulAt: Date(),
            lookbackStart: date,
            replacements: []
        )
        XCTAssertEqual(try repository.cursor(for: "bodyMass")?.anchorData, Data([4]))
        XCTAssertNotNil(try repository.cursor(for: "bodyMass")?.lastSuccessfulAt)

        try repository.resetHealthKitCursors()
        XCTAssertNil(try repository.cursor(for: "bodyMass")?.anchorData)
        XCTAssertNil(try repository.cursor(for: "bodyMass")?.lastSuccessfulAt)
    }

    func testAmbiguousDayRequeryKeepsOldSummaryAndRetriesDeletion() throws {
        let repository = HealthRepository(modelContext: context)
        let sampleID = UUID(uuidString: "00000000-0000-0000-0000-000000000033")!
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let day = Calendar.current.startOfDay(for: date)
        let sample = HealthSampleSnapshot(
            id: sampleID,
            metric: .bodyMass,
            startDate: date,
            endDate: date,
            value: 69
        )
        try repository.applyImportedHealthSamples(
            HealthSamplePage(samples: [sample], nextAnchorData: Data([1]), readState: .available),
            stream: HealthMetricID.bodyMass.rawValue,
            lastSuccessfulAt: date,
            lookbackStart: day,
            replacements: [HealthSampleDaySnapshot(dayStart: day, samples: [sample], readState: .available)]
        )
        try repository.applyImportedHealthSamples(
            HealthSamplePage(
                samples: [],
                deletedSampleIDs: [sampleID],
                nextAnchorData: Data([2]),
                readState: .available
            ),
            stream: HealthMetricID.bodyMass.rawValue,
            lastSuccessfulAt: date.addingTimeInterval(60),
            lookbackStart: day,
            replacements: [HealthSampleDaySnapshot(
                dayStart: day,
                samples: [],
                readState: .dataUnavailableOrReadScopeUnknown
            )]
        )

        let record = try XCTUnwrap(context.fetch(FetchDescriptor<DailyHealthSnapshotRecord>()).first)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let snapshot = try decoder.decode(DailyHealthSnapshot.self, from: record.payloadData)
        XCTAssertEqual(snapshot.healthKitSampleSummary?.aggregate(for: .bodyMass)?.latestValue, 69)
        XCTAssertEqual(snapshot.healthReadStates?[HealthMetricID.bodyMass.rawValue], .dataUnavailableOrReadScopeUnknown)
        XCTAssertNil(snapshot.weightKilograms)
        XCTAssertNil(try context.fetch(FetchDescriptor<DailyMetrics>()).first?.weightKg)
        let pendingIndex = try XCTUnwrap(context.fetch(FetchDescriptor<HealthKitSampleIndexRecord>()).first)
        XCTAssertEqual(pendingIndex.sampleID, sampleID)
        XCTAssertTrue(pendingIndex.needsRequery)
        XCTAssertTrue(pendingIndex.isTombstoned)
        XCTAssertEqual(
            try JSONDecoder().decode([String].self, from: Data(pendingIndex.pendingDayKeysJSON.utf8)),
            [Self.dayKey(day)]
        )

        try repository.applyImportedHealthSamples(
            HealthSamplePage(samples: [], nextAnchorData: Data([3]), readState: .available),
            stream: HealthMetricID.bodyMass.rawValue,
            lastSuccessfulAt: date.addingTimeInterval(120),
            lookbackStart: day,
            replacements: [HealthSampleDaySnapshot(dayStart: day, samples: [], readState: .available)]
        )
        let confirmedDeletion = try decoder.decode(
            DailyHealthSnapshot.self,
            from: XCTUnwrap(context.fetch(FetchDescriptor<DailyHealthSnapshotRecord>()).first).payloadData
        )
        XCTAssertNil(confirmedDeletion.healthKitSampleSummary?.aggregate(for: .bodyMass))
        XCTAssertEqual(confirmedDeletion.healthReadStates?[HealthMetricID.bodyMass.rawValue], .available)
        XCTAssertTrue(try context.fetch(FetchDescriptor<HealthKitSampleIndexRecord>()).isEmpty)
    }

    func testAnchoredAdditionStaysIndexedWhenFullDayReadIsUnknown() throws {
        let repository = HealthRepository(modelContext: context)
        let sampleID = UUID(uuidString: "00000000-0000-0000-0000-000000000034")!
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let day = Calendar.current.startOfDay(for: date)
        let sample = HealthSampleSnapshot(
            id: sampleID,
            metric: .bodyMass,
            startDate: date,
            endDate: date,
            value: 71
        )
        try repository.applyImportedHealthSamples(
            HealthSamplePage(samples: [sample], nextAnchorData: Data([1]), readState: .available),
            stream: HealthMetricID.bodyMass.rawValue,
            lastSuccessfulAt: date,
            lookbackStart: day,
            replacements: [HealthSampleDaySnapshot(
                dayStart: day,
                samples: [],
                readState: .dataUnavailableOrReadScopeUnknown
            )]
        )

        let index = try XCTUnwrap(context.fetch(FetchDescriptor<HealthKitSampleIndexRecord>()).first)
        XCTAssertEqual(index.sampleID, sampleID)
        XCTAssertEqual(index.dayKey, Self.dayKey(day))
        XCTAssertTrue(index.needsRequery)
        XCTAssertFalse(index.isTombstoned)
        XCTAssertEqual(
            try JSONDecoder().decode([String].self, from: Data(index.pendingDayKeysJSON.utf8)),
            [Self.dayKey(day)]
        )
        let stored = try XCTUnwrap(context.fetch(FetchDescriptor<DailyHealthSnapshotRecord>()).first)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let snapshot = try decoder.decode(DailyHealthSnapshot.self, from: stored.payloadData)
        XCTAssertEqual(snapshot.healthReadStates?[HealthMetricID.bodyMass.rawValue], .dataUnavailableOrReadScopeUnknown)
        XCTAssertNil(snapshot.healthKitSampleSummary?.aggregate(for: .bodyMass))
    }

    func testRepeatedAnchoredSampleIDsKeepDeterministicIndexWinnerWhenRequeryIsUnknown() throws {
        let repository = HealthRepository(modelContext: context)
        let calendar = Calendar.current
        let firstDay = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        let secondDay = calendar.date(byAdding: .day, value: 1, to: firstDay)!
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000036")!
        let tiedID = UUID(uuidString: "00000000-0000-0000-0000-000000000037")!
        let olderVersion = HealthSampleSnapshot(
            id: firstID,
            metric: .bodyMass,
            startDate: calendar.date(byAdding: .hour, value: 8, to: firstDay)!,
            endDate: calendar.date(byAdding: .hour, value: 8, to: firstDay)!,
            value: 69,
            syncVersion: 1
        )
        let newerVersion = HealthSampleSnapshot(
            id: firstID,
            metric: .bodyMass,
            startDate: calendar.date(byAdding: .hour, value: 8, to: secondDay)!,
            endDate: calendar.date(byAdding: .hour, value: 8, to: secondDay)!,
            value: 70,
            syncVersion: 2
        )
        let laterTie = HealthSampleSnapshot(
            id: tiedID,
            metric: .bodyMass,
            startDate: calendar.date(byAdding: .hour, value: 9, to: secondDay)!,
            endDate: calendar.date(byAdding: .hour, value: 9, to: secondDay)!,
            value: 72,
            syncVersion: 7
        )
        let earlierTie = HealthSampleSnapshot(
            id: tiedID,
            metric: .bodyMass,
            startDate: calendar.date(byAdding: .hour, value: 9, to: firstDay)!,
            endDate: calendar.date(byAdding: .hour, value: 9, to: firstDay)!,
            value: 71,
            syncVersion: 7
        )
        let unknownReplacements = [
            HealthSampleDaySnapshot(dayStart: firstDay, samples: [], readState: .dataUnavailableOrReadScopeUnknown),
            HealthSampleDaySnapshot(dayStart: secondDay, samples: [], readState: .dataUnavailableOrReadScopeUnknown),
        ]

        try repository.applyImportedHealthSamples(
            HealthSamplePage(
                samples: [olderVersion, newerVersion, laterTie, earlierTie],
                nextAnchorData: Data([1]),
                readState: .available
            ),
            stream: HealthMetricID.bodyMass.rawValue,
            lastSuccessfulAt: firstDay,
            lookbackStart: firstDay,
            replacements: unknownReplacements
        )
        try repository.applyImportedHealthSamples(
            HealthSamplePage(
                samples: [earlierTie, laterTie, newerVersion, olderVersion],
                nextAnchorData: Data([2]),
                readState: .available
            ),
            stream: HealthMetricID.bodyMass.rawValue,
            lastSuccessfulAt: secondDay,
            lookbackStart: firstDay,
            replacements: unknownReplacements
        )

        let indexes = try context.fetch(FetchDescriptor<HealthKitSampleIndexRecord>())
        let indexByID = Dictionary(uniqueKeysWithValues: indexes.map { ($0.sampleID, $0) })
        let versionedIndex = try XCTUnwrap(indexByID[firstID])
        XCTAssertEqual(versionedIndex.dayKey, Self.dayKey(secondDay))
        XCTAssertEqual(versionedIndex.startDate, newerVersion.startDate)
        XCTAssertTrue(versionedIndex.needsRequery)
        let tiedIndex = try XCTUnwrap(indexByID[tiedID])
        XCTAssertEqual(tiedIndex.dayKey, Self.dayKey(firstDay))
        XCTAssertEqual(tiedIndex.startDate, earlierTie.startDate)
        XCTAssertTrue(tiedIndex.needsRequery)
        XCTAssertEqual(
            try repository.affectedHealthSampleDays(
                for: HealthSamplePage(samples: [], nextAnchorData: Data([3]), readState: .available),
                stream: HealthMetricID.bodyMass.rawValue
            ),
            [firstDay, secondDay]
        )
    }

    func testAffectedHealthSampleDaysReadsPendingIndexesInBoundedBatches() throws {
        let repository = HealthRepository(modelContext: context)
        let calendar = Calendar.current
        let firstDay = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        var expectedDays = Set<Date>()
        for offset in 0..<401 {
            let day = calendar.date(byAdding: .day, value: offset, to: firstDay)!
            expectedDays.insert(day)
            context.insert(HealthKitSampleIndexRecord(
                sampleID: UUID(),
                stream: HealthMetricID.bodyMass.rawValue,
                dayKey: Self.dayKey(day),
                startDate: day,
                endDate: day,
                needsRequery: true
            ))
        }
        try context.save()

        let page = HealthSamplePage(samples: [], nextAnchorData: Data([1]), readState: .available)
        let affectedDays = try repository.affectedHealthSampleDays(
            for: page,
            stream: HealthMetricID.bodyMass.rawValue
        )

        XCTAssertEqual(affectedDays.count, 401)
        XCTAssertEqual(Set(affectedDays), expectedDays)
    }

    func testPendingDeletedSampleIndexesFinishCleanupAcrossMutatingPages() throws {
        let repository = HealthRepository(modelContext: context)
        let day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        let dayKey = Self.dayKey(day)
        for index in 1...401 {
            let sampleID = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!
            context.insert(HealthKitSampleIndexRecord(
                sampleID: sampleID,
                stream: HealthMetricID.bodyMass.rawValue,
                dayKey: dayKey,
                startDate: day,
                endDate: day,
                needsRequery: true,
                pendingDayKeys: [dayKey],
                isTombstoned: true
            ))
        }
        try context.save()

        try repository.applyImportedHealthSamples(
            HealthSamplePage(samples: [], nextAnchorData: Data([4]), readState: .available),
            stream: HealthMetricID.bodyMass.rawValue,
            lastSuccessfulAt: day,
            lookbackStart: day,
            replacements: [HealthSampleDaySnapshot(dayStart: day, samples: [], readState: .available)]
        )

        XCTAssertTrue(try context.fetch(FetchDescriptor<HealthKitSampleIndexRecord>()).isEmpty)
    }

    func testSleepDeletionTargetsOnlyWakeDaysIntersectingTheStoredInterval() throws {
        let repository = HealthRepository(modelContext: context)
        let calendar = Calendar.current
        let startDay = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
        let wakeDay = calendar.date(byAdding: .day, value: 1, to: startDay)!
        let sampleStart = calendar.date(bySettingHour: 22, minute: 0, second: 0, of: startDay)!
        let sampleEnd = calendar.date(bySettingHour: 6, minute: 0, second: 0, of: wakeDay)!
        let sampleID = UUID(uuidString: "00000000-0000-0000-0000-000000000035")!
        let sample = HealthSampleSnapshot(
            id: sampleID,
            metric: .sleepAnalysis,
            startDate: sampleStart,
            endDate: sampleEnd,
            categoryValue: "asleepCore",
            sourceBundleIdentifier: "com.example.health",
            deviceModel: "Watch6,1"
        )
        try repository.applyImportedHealthSamples(
            HealthSamplePage(samples: [sample], nextAnchorData: Data([1]), readState: .available),
            stream: HealthMetricID.sleepAnalysis.rawValue,
            lastSuccessfulAt: sampleEnd,
            lookbackStart: startDay,
            replacements: [HealthSampleDaySnapshot(
                dayStart: wakeDay,
                samples: [sample],
                readState: .available
            )]
        )

        let deletionPage = HealthSamplePage(
            samples: [],
            deletedSampleIDs: [sampleID],
            nextAnchorData: Data([2]),
            readState: .available
        )
        XCTAssertEqual(
            try repository.affectedHealthSampleDays(for: deletionPage, stream: HealthMetricID.sleepAnalysis.rawValue),
            [wakeDay]
        )
    }

    func testUpdatedSampleMovingToAnotherDayRemovesOldProjection() throws {
        let repository = HealthRepository(modelContext: context)
        let sampleID = UUID(uuidString: "00000000-0000-0000-0000-000000000032")!
        let firstDate = Date(timeIntervalSince1970: 1_700_000_000)
        let movedDate = Calendar.current.date(byAdding: .day, value: 2, to: firstDate)!
        let first = HealthSampleSnapshot(
            id: sampleID,
            metric: .bodyMass,
            startDate: firstDate,
            endDate: firstDate,
            value: 70
        )
        let moved = HealthSampleSnapshot(
            id: sampleID,
            metric: .bodyMass,
            startDate: movedDate,
            endDate: movedDate,
            value: 72
        )
        try repository.applyImportedHealthSamples(
            HealthSamplePage(samples: [first], nextAnchorData: Data([1]), readState: .available),
            stream: "bodyMass",
            lastSuccessfulAt: Date(),
            lookbackStart: firstDate,
            replacements: [HealthSampleDaySnapshot(
                dayStart: Calendar.current.startOfDay(for: firstDate),
                samples: [first],
                readState: .available
            )]
        )
        try repository.applyImportedHealthSamples(
            HealthSamplePage(samples: [moved], nextAnchorData: Data([2]), readState: .available),
            stream: "bodyMass",
            lastSuccessfulAt: Date(),
            lookbackStart: firstDate,
            replacements: [
                HealthSampleDaySnapshot(
                    dayStart: Calendar.current.startOfDay(for: firstDate),
                    samples: [],
                    readState: .available
                ),
                HealthSampleDaySnapshot(
                    dayStart: Calendar.current.startOfDay(for: movedDate),
                    samples: [moved],
                    readState: .available
                ),
            ]
        )

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let snapshots = try context.fetch(FetchDescriptor<DailyHealthSnapshotRecord>())
            .map { try decoder.decode(DailyHealthSnapshot.self, from: $0.payloadData) }
        let originalDay = try XCTUnwrap(snapshots.first(where: { Calendar.current.isDate($0.dayStart, inSameDayAs: firstDate) }))
        let movedDay = try XCTUnwrap(snapshots.first(where: { Calendar.current.isDate($0.dayStart, inSameDayAs: movedDate) }))
        XCTAssertNil(originalDay.healthKitSamples)
        XCTAssertNil(originalDay.healthKitSampleSummary?.aggregate(for: .bodyMass))
        XCTAssertNil(originalDay.weightKilograms)
        XCTAssertNil(movedDay.healthKitSamples)
        XCTAssertEqual(movedDay.healthKitSampleSummary?.aggregate(for: .bodyMass)?.latestSampleID, sampleID)
        XCTAssertEqual(movedDay.healthKitSampleSummary?.aggregate(for: .bodyMass)?.latestValue, 72)
        XCTAssertEqual(movedDay.weightKilograms, 72)
    }

    func testUnknownDayRequeryForMovedSampleRetainsBothDaysUntilEachIsAvailable() throws {
        let repository = HealthRepository(modelContext: context)
        let calendar = Calendar.current
        let firstDay = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        let secondDay = calendar.date(byAdding: .day, value: 1, to: firstDay)!
        let sampleID = UUID(uuidString: "00000000-0000-0000-0000-000000000038")!
        let original = HealthSampleSnapshot(
            id: sampleID,
            metric: .bodyMass,
            startDate: calendar.date(byAdding: .hour, value: 8, to: firstDay)!,
            endDate: calendar.date(byAdding: .hour, value: 8, to: firstDay)!,
            value: 70,
            syncVersion: 1
        )
        let moved = HealthSampleSnapshot(
            id: sampleID,
            metric: .bodyMass,
            startDate: calendar.date(byAdding: .hour, value: 8, to: secondDay)!,
            endDate: calendar.date(byAdding: .hour, value: 8, to: secondDay)!,
            value: 72,
            syncVersion: 2
        )

        try repository.applyImportedHealthSamples(
            HealthSamplePage(samples: [original], nextAnchorData: Data([1]), readState: .available),
            stream: HealthMetricID.bodyMass.rawValue,
            lastSuccessfulAt: firstDay,
            lookbackStart: firstDay,
            replacements: [HealthSampleDaySnapshot(dayStart: firstDay, samples: [original], readState: .available)]
        )
        try repository.applyImportedHealthSamples(
            HealthSamplePage(samples: [moved], nextAnchorData: Data([2]), readState: .available),
            stream: HealthMetricID.bodyMass.rawValue,
            lastSuccessfulAt: secondDay,
            lookbackStart: firstDay,
            replacements: [
                HealthSampleDaySnapshot(
                    dayStart: firstDay,
                    samples: [],
                    readState: .dataUnavailableOrReadScopeUnknown
                ),
                HealthSampleDaySnapshot(
                    dayStart: secondDay,
                    samples: [moved],
                    readState: .dataUnavailableOrReadScopeUnknown
                ),
            ]
        )

        let movedIndex = try XCTUnwrap(context.fetch(FetchDescriptor<HealthKitSampleIndexRecord>()).first)
        XCTAssertEqual(movedIndex.dayKey, Self.dayKey(secondDay))
        XCTAssertFalse(movedIndex.isTombstoned)
        XCTAssertTrue(movedIndex.needsRequery)
        XCTAssertEqual(
            try JSONDecoder().decode([String].self, from: Data(movedIndex.pendingDayKeysJSON.utf8)),
            [Self.dayKey(firstDay), Self.dayKey(secondDay)].sorted()
        )
        XCTAssertEqual(
            try repository.affectedHealthSampleDays(
                for: HealthSamplePage(samples: [], nextAnchorData: Data([3]), readState: .available),
                stream: HealthMetricID.bodyMass.rawValue
            ),
            [firstDay, secondDay]
        )

        try repository.applyImportedHealthSamples(
            HealthSamplePage(samples: [], nextAnchorData: Data([3]), readState: .available),
            stream: HealthMetricID.bodyMass.rawValue,
            lastSuccessfulAt: secondDay.addingTimeInterval(60),
            lookbackStart: firstDay,
            replacements: [
                HealthSampleDaySnapshot(
                    dayStart: firstDay,
                    samples: [],
                    readState: .dataUnavailableOrReadScopeUnknown
                ),
                HealthSampleDaySnapshot(dayStart: secondDay, samples: [moved], readState: .available),
            ]
        )
        let partiallyResolvedIndex = try XCTUnwrap(
            context.fetch(FetchDescriptor<HealthKitSampleIndexRecord>()).first
        )
        XCTAssertTrue(partiallyResolvedIndex.needsRequery)
        XCTAssertEqual(
            try JSONDecoder().decode([String].self, from: Data(partiallyResolvedIndex.pendingDayKeysJSON.utf8)),
            [Self.dayKey(firstDay)]
        )

        try repository.applyImportedHealthSamples(
            HealthSamplePage(samples: [], nextAnchorData: Data([4]), readState: .available),
            stream: HealthMetricID.bodyMass.rawValue,
            lastSuccessfulAt: secondDay.addingTimeInterval(120),
            lookbackStart: firstDay,
            replacements: [HealthSampleDaySnapshot(dayStart: firstDay, samples: [], readState: .available)]
        )
        let resolvedIndex = try XCTUnwrap(context.fetch(FetchDescriptor<HealthKitSampleIndexRecord>()).first)
        XCTAssertFalse(resolvedIndex.needsRequery)
        XCTAssertFalse(resolvedIndex.isTombstoned)
        XCTAssertEqual(
            try JSONDecoder().decode([String].self, from: Data(resolvedIndex.pendingDayKeysJSON.utf8)),
            []
        )
        XCTAssertEqual(resolvedIndex.dayKey, Self.dayKey(secondDay))
    }

    func testUnknownAggregateStateDoesNotReuseAStaleMeasuredEnergyValue() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let day = Calendar.current.startOfDay(for: date)
        let components = Calendar.current.dateComponents([.year, .month, .day], from: day)
        let dayKey = String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
        let snapshot = DailyHealthSnapshot(
            dayStart: day,
            timezoneIdentifier: Calendar.current.timeZone.identifier,
            activeEnergyKcal: 640,
            restingEnergyKcal: 1_410,
            healthReadStates: [
                HealthMetricID.activeEnergy.rawValue: .available,
                HealthMetricID.restingEnergy.rawValue: .available,
            ],
            algorithmVersion: "v3"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        context.insert(DailyHealthSnapshotRecord(
            dayKey: dayKey,
            timezoneID: Calendar.current.timeZone.identifier,
            payloadData: try encoder.encode(snapshot),
            snapshotHash: "fixture",
            algorithmVersion: "v3"
        ))
        try context.save()

        try HealthRepository(modelContext: context).applyHealthAggregates(
            [HealthAggregateBucket(
                startDate: day,
                endDate: Calendar.current.date(byAdding: .day, value: 1, to: day)!,
                value: nil
            )],
            metric: .activeEnergy,
            stream: "activeEnergy",
            lookbackStart: day
        )

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let savedSnapshot = try decoder.decode(
            DailyHealthSnapshot.self,
            from: XCTUnwrap(context.fetch(FetchDescriptor<DailyHealthSnapshotRecord>()).first).payloadData
        )
        XCTAssertEqual(savedSnapshot.activeEnergyKcal, 640)
        XCTAssertEqual(savedSnapshot.healthReadStates?[HealthMetricID.activeEnergy.rawValue], .dataUnavailableOrReadScopeUnknown)
        let metric = try XCTUnwrap(context.fetch(FetchDescriptor<DailyMetrics>()).first)
        XCTAssertEqual(metric.activeCaloriesKcal, 0)
        XCTAssertEqual(metric.energyQuality, "unavailable")
    }

    func testDuplicateHealthAggregateBucketsKeepLastBucketPerDay() throws {
        let day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        try HealthRepository(modelContext: context).applyHealthAggregates(
            [
                HealthAggregateBucket(
                    startDate: day,
                    endDate: Calendar.current.date(byAdding: .day, value: 1, to: day)!,
                    value: 500
                ),
                HealthAggregateBucket(
                    startDate: day.addingTimeInterval(60 * 60),
                    endDate: Calendar.current.date(byAdding: .day, value: 1, to: day)!,
                    value: 640
                ),
            ],
            metric: .activeEnergy,
            stream: HealthMetricID.activeEnergy.rawValue,
            lookbackStart: day
        )

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let snapshot = try decoder.decode(
            DailyHealthSnapshot.self,
            from: XCTUnwrap(context.fetch(FetchDescriptor<DailyHealthSnapshotRecord>()).first).payloadData
        )
        XCTAssertEqual(snapshot.activeEnergyKcal, 640)
        XCTAssertEqual(snapshot.healthReadStates?[HealthMetricID.activeEnergy.rawValue], .available)
        let metric = try XCTUnwrap(context.fetch(FetchDescriptor<DailyMetrics>()).first)
        XCTAssertEqual(metric.activeEnergyKcal, 640)
        XCTAssertEqual(metric.activeCaloriesKcal, 0)
        XCTAssertEqual(metric.energyQuality, "unavailable")
        XCTAssertTrue(metric.requiresRecompute)
    }

    func testHealthSnapshotUpsertUpdatesOnlyTheMatchingDayKey() throws {
        let targetDate = Date(timeIntervalSince1970: 1_700_000_000)
        let targetDay = Calendar.current.startOfDay(for: targetDate)
        let neighboringDay = Calendar.current.date(byAdding: .day, value: 1, to: targetDay)!
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        for (day, energy) in [(targetDay, 100.0), (neighboringDay, 200.0)] {
            let snapshot = DailyHealthSnapshot(
                dayStart: day,
                timezoneIdentifier: Calendar.current.timeZone.identifier,
                activeEnergyKcal: energy,
                healthReadStates: [HealthMetricID.activeEnergy.rawValue: .available],
                algorithmVersion: "lookup-fixture"
            )
            context.insert(DailyHealthSnapshotRecord(
                dayKey: Self.dayKey(day),
                timezoneID: snapshot.timezoneIdentifier,
                payloadData: try encoder.encode(snapshot),
                snapshotHash: "lookup-\(energy)",
                algorithmVersion: snapshot.algorithmVersion
            ))
        }
        try context.save()

        try HealthRepository(modelContext: context).applyHealthAggregates(
            [HealthAggregateBucket(
                startDate: targetDay,
                endDate: Calendar.current.date(byAdding: .day, value: 1, to: targetDay)!,
                value: 640
            )],
            metric: .activeEnergy,
            stream: "activeEnergy",
            lookbackStart: targetDay
        )

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let snapshots = try context.fetch(FetchDescriptor<DailyHealthSnapshotRecord>())
            .map { try decoder.decode(DailyHealthSnapshot.self, from: $0.payloadData) }
        XCTAssertEqual(snapshots.count, 2)
        XCTAssertEqual(snapshots.first(where: { Calendar.current.isDate($0.dayStart, inSameDayAs: targetDay) })?.activeEnergyKcal, 640)
        XCTAssertEqual(snapshots.first(where: { Calendar.current.isDate($0.dayStart, inSameDayAs: neighboringDay) })?.activeEnergyKcal, 200)
    }

    private static func dayKey(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    private func mealEvidenceData(grade: EvidenceGrade) throws -> Data {
        try JSONEncoder().encode([
            EvidenceSnapshot(
                grade: grade,
                sourceID: "test-meal-evidence",
                summary: "Regression fixture meal evidence."
            ),
        ])
    }
}

private enum TestSaveError: Error {
    case injected
}
