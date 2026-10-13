import SwiftData
import XCTest
@testable import Densoso

@MainActor
final class ExportServiceTests: XCTestCase {
    func testRestoreReprojectsDerivedMetricsInsteadOfTrustingSerializedMetrics() async throws {
        let (sourceContainer, source) = try makeContext()
        _ = sourceContainer
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        source.insert(UserProfile())
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
        XCTAssertEqual(exportedDocument.formatVersion, 3)

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
        XCTAssertEqual(metrics[0].activeCaloriesKcal, 130)
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
        source.insert(UserProfile())
        source.insert(MealRecord(totalCaloriesKcal: 350, proteinG: 12, fatG: 8, carbsG: 54))
        try source.save()

        let service = ExportService()
        let currentURL = try await service.exportJSON(context: source)
        defer { try? FileManager.default.removeItem(at: currentURL) }
        let currentObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: currentURL)) as? [String: Any]
        )
        var legacyPayloadObject = try XCTUnwrap(currentObject["payload"] as? [String: Any])
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

    private func makeContext() throws -> (ModelContainer, ModelContext) {
        let container = try ModelContainer(
            for: UserProfile.self, MealRecord.self, DishEntry.self, WorkoutRecord.self, DailyMetrics.self, HealthSyncOutboxEntry.self, HealthKitImportCursor.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return (container, ModelContext(container))
    }
}
