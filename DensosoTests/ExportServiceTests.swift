import DensosoDomain
import SwiftData
import XCTest
@testable import Densoso

@MainActor
final class ExportServiceTests: XCTestCase {
    func testRestoreReprojectsDerivedMetricsInsteadOfTrustingSerializedMetrics() async throws {
        let (sourceContainer, source) = try makeContext()
        _ = sourceContainer
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let profile = UserProfile(dateOfBirth: Calendar.current.date(byAdding: .year, value: -30, to: Date())!)
        source.insert(profile)
        let evidence = Data("gate05-evidence".utf8)
        let meal = MealRecord(
            date: date,
            totalCaloriesKcal: 640,
            proteinG: 32,
            fatG: 20,
            carbsG: 72,
            sourceActionKey: "gate05-source-action",
            energyLowKcal: 520,
            energyLikelyKcal: 640,
            energyHighKcal: 780,
            proteinLowG: nil,
            proteinLikelyG: nil,
            proteinHighG: nil,
            evidenceData: evidence
        )
        meal.dishes = [
            DishEntry(
                dishName: "fixture dish",
                estimatedCaloriesKcal: 640,
                portionLowG: 120,
                portionLikelyG: 180,
                portionHighG: 260,
                evidenceData: evidence,
                algorithmVersion: "meal-estimator-v1"
            )
        ]
        source.insert(meal)
        let healthKitUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000030")!
        let workout = WorkoutRecord(
            date: date,
            type: "walking",
            durationMinutes: 30,
            estimatedCaloriesBurned: 130,
            healthKitUUID: healthKitUUID,
            workoutOrigin: "watchHealthKit",
            energySource: "measured",
            sourceBundleIdentifier: "com.densoso.densoso",
            dataQuality: "complete",
            routeStatus: "pending"
        )
        source.insert(workout)
        try source.save()

        let service = ExportService()
        let url = try await service.exportJSON(context: source)
        defer { try? FileManager.default.removeItem(at: url) }
        let exportedDocument = try JSONDecoder().decode(
            ExportService.BackupDocument.self,
            from: Data(contentsOf: url)
        )
        XCTAssertEqual(exportedDocument.formatVersion, 5)

        let (targetContainer, target) = try makeContext()
        _ = targetContainer
        target.insert(MealRecord(date: date, totalCaloriesKcal: 999))
        try target.save()

        let summary = try await service.restoreJSON(url: url, context: target)
        let meals = try target.fetch(FetchDescriptor<MealRecord>())
        let metrics = try target.fetch(FetchDescriptor<DailyMetrics>())
        XCTAssertEqual(summary.meals, 1)
        XCTAssertEqual(summary.workouts, 1)
        XCTAssertEqual(meals.count, 1)
        XCTAssertEqual(meals[0].totalCaloriesKcal, 640)
        XCTAssertEqual(meals[0].sourceActionKey, "gate05-source-action")
        XCTAssertEqual(meals[0].energyLowKcal, 520)
        XCTAssertNil(meals[0].proteinLikelyG)
        XCTAssertEqual(meals[0].evidenceData, evidence)
        XCTAssertEqual(meals[0].dishes.first?.portionLikelyG, 180)
        XCTAssertEqual(meals[0].dishes.first?.algorithmVersion, "meal-estimator-v1")
        XCTAssertEqual(metrics.count, 1)
        XCTAssertEqual(metrics[0].totalIntakeKcal, 640)
        // Workout energy is descriptive in Phase 6; it is not daily active energy.
        // A current profile revision cannot be projected backward into 2023.
        XCTAssertEqual(metrics[0].activeCaloriesKcal, 0)
        XCTAssertEqual(metrics[0].energyQuality, "unavailable")
        let workouts = try target.fetch(FetchDescriptor<WorkoutRecord>())
        XCTAssertEqual(workouts.count, 1)
        XCTAssertEqual(workouts[0].healthKitUUID, healthKitUUID)
        XCTAssertEqual(workouts[0].workoutOrigin, "watchHealthKit")
        XCTAssertEqual(workouts[0].energySource, "measured")
    }

    func testChecksumFailureLeavesExistingRecordsUntouched() async throws {
        let (sourceContainer, source) = try makeContext()
        _ = sourceContainer
        source.insert(MealRecord(totalCaloriesKcal: 400))
        try source.save()

        let service = ExportService()
        let url = try await service.exportJSON(context: source)
        defer { try? FileManager.default.removeItem(at: url) }
        var document = try JSONDecoder().decode(ExportService.BackupDocument.self, from: Data(contentsOf: url))
        document = .init(formatVersion: document.formatVersion, checksum: "invalid", payload: document.payload)
        try JSONEncoder().encode(document).write(to: url, options: .atomic)

        let (targetContainer, target) = try makeContext()
        _ = targetContainer
        target.insert(MealRecord(totalCaloriesKcal: 777))
        try target.save()

        do {
            _ = try await service.restoreJSON(url: url, context: target)
            XCTFail("Expected checksum validation to fail")
        } catch {
            XCTAssertEqual(error as? ExportService.BackupError, .checksumMismatch)
        }
        let meals = try target.fetch(FetchDescriptor<MealRecord>())
        XCTAssertEqual(meals.count, 1)
        XCTAssertEqual(meals[0].totalCaloriesKcal, 777)
    }

    func testLegacyV2DishPayloadDecodesWithNilGate5Ranges() throws {
        let legacyJSON = Data(
            #"{"dishName":"legacy","cookingMethod":"steam","ingredientJSON":"[]","estimatedCaloriesKcal":100,"estimatedProteinG":0,"estimatedFatG":0,"estimatedCarbsG":0,"confidenceScore":0.5,"userCorrectionFactor":null,"createdAt":0}"#.utf8
        )

        let dish = try JSONDecoder().decode(
            ExportService.BackupPayload.DishExport.self,
            from: legacyJSON
        )

        XCTAssertNil(dish.id)
        XCTAssertNil(dish.energyLowKcal)
        XCTAssertNil(dish.portionLikelyG)
        XCTAssertNil(dish.evidenceData)
    }

    func testLegacyV2BackupStillRestoresAfterGate5EvidenceFieldsWereAdded() async throws {
        let (sourceContainer, source) = try makeContext()
        _ = sourceContainer
        let profile = UserProfile(
            biologicalSex: "female",
            dateOfBirth: Date(timeIntervalSince1970: 631_152_000),
            heightCm: 165,
            weightKg: 70.5,
            activityLevel: "moderate"
        )
        profile.profileNeedsCompletion = false
        source.insert(profile)
        source.insert(MealRecord(totalCaloriesKcal: 350, proteinG: 12, fatG: 8, carbsG: 54))
        try source.save()

        let service = ExportService()
        let currentURL = try await service.exportJSON(context: source)
        defer { try? FileManager.default.removeItem(at: currentURL) }
        let currentObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: currentURL)) as? [String: Any]
        )
        var legacyPayloadObject = try XCTUnwrap(currentObject["payload"] as? [String: Any])
        for key in [
            "weightRecords", "goalProfiles", "dailyHealthSnapshots", "scheduleEvents",
            "dailyBriefs", "weeklyBriefs",
        ] {
            legacyPayloadObject.removeValue(forKey: key)
        }
        var legacyMeals = try XCTUnwrap(legacyPayloadObject["mealRecords"] as? [[String: Any]])
        for index in legacyMeals.indices {
            for key in [
                "sourceActionKey", "energyLowKcal", "energyLikelyKcal", "energyHighKcal",
                "proteinLowG", "proteinLikelyG", "proteinHighG", "fatLowG", "fatLikelyG",
                "fatHighG", "carbsLowG", "carbsLikelyG", "carbsHighG", "evidenceData",
            ] {
                legacyMeals[index].removeValue(forKey: key)
            }
            if var dishes = legacyMeals[index]["dishes"] as? [[String: Any]] {
                for dishIndex in dishes.indices {
                    for key in [
                        "id", "energyLowKcal", "energyLikelyKcal", "energyHighKcal",
                        "proteinLowG", "proteinLikelyG", "proteinHighG", "fatLowG",
                        "fatLikelyG", "fatHighG", "carbsLowG", "carbsLikelyG",
                        "carbsHighG", "portionLowG", "portionLikelyG", "portionHighG",
                        "evidenceData", "algorithmVersion",
                    ] {
                        dishes[dishIndex].removeValue(forKey: key)
                    }
                }
                legacyMeals[index]["dishes"] = dishes
            }
        }
        legacyPayloadObject["mealRecords"] = legacyMeals
        let payloadData = try JSONSerialization.data(
            withJSONObject: legacyPayloadObject,
            options: [.sortedKeys]
        )
        let legacyPayload = try JSONDecoder().decode(
            ExportService.BackupPayload.self,
            from: payloadData
        )
        let legacyDocument = ExportService.BackupDocument(
            formatVersion: 2,
            checksum: try service.checksum(for: legacyPayload),
            payload: legacyPayload
        )
        let legacyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("gate05-legacy-v2-\(UUID().uuidString.lowercased()).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(legacyDocument).write(to: legacyURL)
        defer { try? FileManager.default.removeItem(at: legacyURL) }

        let (targetContainer, target) = try makeContext()
        _ = targetContainer
        let summary = try await service.restoreJSON(url: legacyURL, context: target)

        XCTAssertEqual(summary.meals, 1)
        let restored = try XCTUnwrap(target.fetch(FetchDescriptor<MealRecord>()).first)
        XCTAssertEqual(restored.totalCaloriesKcal, 350)
        XCTAssertEqual(restored.energyLowKcal, 350)
        XCTAssertEqual(restored.energyHighKcal, 350)
    }

    func testLegacyV3BackupStillRestoresMealEvidenceAfterHealthDataWasAdded() async throws {
        let (sourceContainer, source) = try makeContext()
        _ = sourceContainer
        let evidence = Data("v3-evidence".utf8)
        source.insert(MealRecord(
            totalCaloriesKcal: 410,
            proteinG: 18,
            fatG: 12,
            carbsG: 51,
            energyLikelyKcal: 410,
            evidenceData: evidence
        ))
        try source.save()

        let service = ExportService()
        let currentURL = try await service.exportJSON(context: source)
        defer { try? FileManager.default.removeItem(at: currentURL) }
        let currentObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: currentURL)) as? [String: Any]
        )
        var v3PayloadObject = try XCTUnwrap(currentObject["payload"] as? [String: Any])
        for key in [
            "weightRecords", "goalProfiles", "dailyHealthSnapshots", "scheduleEvents",
            "dailyBriefs", "weeklyBriefs", "weeklyReports",
        ] {
            v3PayloadObject.removeValue(forKey: key)
        }
        let payloadData = try JSONSerialization.data(withJSONObject: v3PayloadObject, options: [.sortedKeys])
        let payload = try JSONDecoder().decode(ExportService.BackupPayload.self, from: payloadData)
        let v3Document = ExportService.BackupDocument(
            formatVersion: 3,
            checksum: try service.checksum(for: payload),
            payload: payload
        )
        let v3URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("gate09-legacy-v3-\(UUID().uuidString.lowercased()).json")
        try JSONEncoder().encode(v3Document).write(to: v3URL)
        defer { try? FileManager.default.removeItem(at: v3URL) }

        let (targetContainer, target) = try makeContext()
        _ = targetContainer
        let summary = try await service.restoreJSON(url: v3URL, context: target)

        XCTAssertEqual(summary.meals, 1)
        let restored = try XCTUnwrap(target.fetch(FetchDescriptor<MealRecord>()).first)
        XCTAssertEqual(restored.totalCaloriesKcal, 410)
        XCTAssertEqual(restored.energyLikelyKcal, 410)
        XCTAssertEqual(restored.evidenceData, evidence)
    }

    func testV5BackupRestoresProfileHistoryAndHealthDataWithoutSyncQueueState() async throws {
        let (sourceContainer, source) = try makeContext()
        _ = sourceContainer
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        source.insert(UserProfile())
        source.insert(WeightRecord(
            sourceActionKey: "v4-weight-action",
            measuredAt: date,
            kilograms: 70.5
        ))
        source.insert(DailyMetrics(
            date: date,
            projectionVersion: "energy-accounting-v2",
            sourceFingerprint: "fixture-fingerprint",
            energyQuality: "observed"
        ))
        source.insert(ProfileRevisionRecord(
            profileKey: "primary",
            effectiveFrom: date,
            dateOfBirth: Date(timeIntervalSince1970: 631_152_000),
            biologicalSex: "female",
            heightCm: 165,
            weightKg: 70.5,
            activityLevel: "moderate",
            source: "userEdited"
        ))
        source.insert(GoalProfileRecord(
            profileKey: "primary",
            targetWeightKilograms: 68,
            dailyDeficitKcal: 350,
            dailyProteinGrams: 90,
            effectiveFrom: date
        ))
        let day = Calendar.current.startOfDay(for: date)
        let dayParts = Calendar.current.dateComponents([.year, .month, .day], from: day)
        let dayKey = String(format: "%04d-%02d-%02d", dayParts.year ?? 0, dayParts.month ?? 0, dayParts.day ?? 0)
        let snapshot = DailyHealthSnapshot(
            dayStart: day,
            timezoneIdentifier: Calendar.current.timeZone.identifier,
            energyIntakeKcal: try EstimateRange(low: 450, likely: 500, high: 600),
            stepCount: 7_000,
            algorithmVersion: "v3"
        )
        let snapshotEncoder = JSONEncoder()
        snapshotEncoder.dateEncodingStrategy = .millisecondsSince1970
        source.insert(DailyHealthSnapshotRecord(
            dayKey: dayKey,
            timezoneID: snapshot.timezoneIdentifier,
            payloadData: try snapshotEncoder.encode(snapshot),
            snapshotHash: "v4-health-hash",
            algorithmVersion: "v3"
        ))
        source.insert(ScheduleEvent(
            date: date,
            title: "药物提醒",
            notes: "ordinary user schedule",
            startTime: date
        ))
        source.insert(DailyBriefRecord(
            cacheKey: "daily:\(dayKey)",
            dayKey: dayKey,
            snapshotHash: "v4-health-hash",
            algorithmVersion: "health-intelligence-v1",
            payloadData: Data("daily-brief".utf8)
        ))
        source.insert(WeeklyBriefRecord(
            cacheKey: "weekly:\(dayKey)",
            weekKey: dayKey,
            snapshotHash: "v4-week-hash",
            algorithmVersion: "health-intelligence-v1",
            payloadData: Data("weekly-brief".utf8)
        ))
        source.insert(HealthSyncOutboxEntry(
            operation: "upsertWeight",
            recordID: UUID(),
            idempotencyKey: "source-outbox"
        ))
        source.insert(HealthKitImportCursor(stream: "bodyMass", anchorData: Data([1]))
        )
        try source.save()

        let service = ExportService()
        let url = try await service.exportJSON(context: source)
        defer { try? FileManager.default.removeItem(at: url) }
        let exported = try JSONDecoder().decode(
            ExportService.BackupDocument.self,
            from: Data(contentsOf: url)
        )
        XCTAssertEqual(exported.formatVersion, 5)
        XCTAssertEqual(exported.payload.weightRecords?.count, 1)
        XCTAssertEqual(exported.payload.profileRevisions?.count, 1)
        XCTAssertEqual(exported.payload.dailyMetricsProjection?.first?.sourceFingerprint, "fixture-fingerprint")
        XCTAssertEqual(exported.payload.dailyHealthSnapshots?.count, 1)
        XCTAssertEqual(exported.payload.goalProfiles?.count, 1)
        XCTAssertEqual(exported.payload.dailyBriefs?.count, 1)
        XCTAssertEqual(exported.payload.weeklyBriefs?.count, 1)
        XCTAssertEqual(exported.payload.scheduleEvents?.count, 1)

        let (targetContainer, target) = try makeContext()
        _ = targetContainer
        target.insert(HealthSyncOutboxEntry(operation: "upsertMeal", recordID: UUID()))
        target.insert(HealthKitImportCursor(stream: "workouts", anchorData: Data([9])))
        try target.save()
        let summary = try await service.restoreJSON(url: url, context: target)

        XCTAssertEqual(summary.weights, 1)
        XCTAssertEqual(summary.healthDays, 1)
        XCTAssertEqual(summary.scheduledPlans, 0)
        XCTAssertEqual(try target.fetch(FetchDescriptor<WeightRecord>()).first?.kilograms, 70.5)
        XCTAssertEqual(try target.fetch(FetchDescriptor<WeightRecord>()).first?.confidence, 0.9)
        XCTAssertEqual(try target.fetch(FetchDescriptor<ProfileRevisionRecord>()).first?.heightCm, 165)
        XCTAssertEqual(try target.fetch(FetchDescriptor<GoalProfileRecord>()).first?.dailyProteinGrams, 90)
        XCTAssertEqual(try target.fetch(FetchDescriptor<ScheduleEvent>()).first?.title, "药物提醒")
        XCTAssertEqual(try target.fetchCount(FetchDescriptor<HealthSyncOutboxEntry>()), 0)
        XCTAssertEqual(try target.fetchCount(FetchDescriptor<HealthKitImportCursor>()), 0)
        XCTAssertEqual(try target.fetch(FetchDescriptor<DailyBriefRecord>()).first?.payloadData, Data("daily-brief".utf8))
    }

    private func makeContext() throws -> (ModelContainer, ModelContext) {
        let container = try ModelContainer(
            for: UserProfile.self, MealRecord.self, DishEntry.self, WorkoutRecord.self, DailyMetrics.self, WeeklyReport.self,
            ScheduleEvent.self, WeightRecord.self, ProfileRevisionRecord.self, GoalProfileRecord.self, DailyHealthSnapshotRecord.self,
            DailyBriefRecord.self, WeeklyBriefRecord.self, HealthSyncOutboxEntry.self, HealthKitImportCursor.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return (container, ModelContext(container))
    }
}
