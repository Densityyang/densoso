import DensosoDomain
import SwiftData
import XCTest
@testable import Densoso

@MainActor
final class ExportServiceTests: XCTestCase {
    func testBackupDoesNotTransferCloudHealthConsentAndRestoreDefaultsToDenied() async throws {
        let (sourceContainer, source) = try makeContext()
        let sourceGovernance = SwiftDataProviderGovernanceRepository(modelContainer: sourceContainer)
        let policyVersionSentinel = "PRIVATE-CLOUD-POLICY-SENTINEL"
        for provider in [ProviderID.deepSeek, .qwen] {
            _ = try await CloudHealthContextPolicy.confirmExpandedPolicy(
                provider: provider,
                allowedClasses: Set(CloudHealthContextPolicy.dataClasses),
                repository: sourceGovernance,
                confirmedAt: Date(),
                changeSource: .settings
            )
            for dataClass in CloudHealthContextPolicy.dataClasses {
                try await sourceGovernance.setConsent(
                    provider: provider,
                    dataClass: dataClass,
                    granted: true,
                    policyVersion: policyVersionSentinel
                )
            }
        }

        let service = ExportService()
        let backupURL = try await service.exportJSON(context: source)
        defer { try? FileManager.default.removeItem(at: backupURL) }
        let backupText = String(decoding: try Data(contentsOf: backupURL), as: UTF8.self)
        XCTAssertFalse(backupText.contains("ConsentRecord"))
        XCTAssertFalse(backupText.contains("consentKey"))
        XCTAssertFalse(backupText.contains(policyVersionSentinel))

        let (targetContainer, target) = try makeContext()
        _ = try await service.restoreJSON(url: backupURL, context: target)
        let restoredGovernance = SwiftDataProviderGovernanceRepository(modelContainer: targetContainer)
        for provider in [ProviderID.deepSeek, .qwen] {
            for dataClass in CloudHealthContextPolicy.dataClasses {
                let isGranted = try await restoredGovernance.isConsentGranted(
                    provider: provider,
                    dataClass: dataClass
                )
                XCTAssertFalse(
                    isGranted,
                    "A backup restore without a cloud policy must leave \(provider.rawValue)/\(dataClass.rawValue) denied"
                )
            }
        }
    }

    func testRestoreInvalidatesCloudHealthAuthorizationAlreadyPresentInTargetStore() async throws {
        let (sourceContainer, source) = try makeContext()
        _ = sourceContainer
        let service = ExportService()
        let backupURL = try await service.exportJSON(context: source)
        defer { try? FileManager.default.removeItem(at: backupURL) }

        let (targetContainer, target) = try makeContext()
        let targetGovernance = SwiftDataProviderGovernanceRepository(modelContainer: targetContainer)
        for provider in [ProviderID.deepSeek, .qwen] {
            _ = try await CloudHealthContextPolicy.confirmExpandedPolicy(
                provider: provider,
                allowedClasses: Set(CloudHealthContextPolicy.dataClasses),
                repository: targetGovernance,
                confirmedAt: Date(),
                changeSource: .settings
            )
            _ = try await CloudHealthContextPolicy.updateConversationHistoryConsent(
                provider: provider,
                allowed: true,
                repository: targetGovernance,
                confirmedAt: Date(),
                changeSource: .settings
            )
        }

        _ = try await service.restoreJSON(url: backupURL, context: target)

        for provider in [ProviderID.deepSeek, .qwen] {
            let restoredPolicy = try await CloudHealthContextPolicy.load(
                from: targetGovernance,
                provider: provider
            )
            XCTAssertTrue(restoredPolicy.allowedClasses.isEmpty)
            XCTAssertFalse(restoredPolicy.allowsConversationHistory)
            XCTAssertTrue(restoredPolicy.snapshot.allowedClasses.isEmpty)
            XCTAssertEqual(restoredPolicy.snapshot.state, .needsReconfirmation)
            XCTAssertEqual(restoredPolicy.snapshot.changeSource, .backupRestore)

            for dataClass in CloudHealthContextPolicy.dataClasses + [.conversationHistory] {
                let isGranted = try await targetGovernance.isConsentGranted(
                    provider: provider,
                    dataClass: dataClass
                )
                XCTAssertFalse(
                    isGranted,
                    "Restoring a backup must revoke \(provider.rawValue)/\(dataClass.rawValue) until reconfirmed"
                )
            }
        }
    }

    func testBackupExportPagesMealHistoryAcross64RowBoundary() async throws {
        let (container, source) = try makeContext()
        _ = container
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var expectedIDs: [UUID] = []
        for index in 0..<65 {
            let id = UUID()
            source.insert(MealRecord(
                id: id,
                date: start.addingTimeInterval(TimeInterval(index)),
                totalCaloriesKcal: index,
                sourceActionKey: "backup-page-\(index)"
            ))
            expectedIDs.append(id)
        }
        try source.save()

        let url = try await ExportService().exportJSON(context: source)
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try JSONDecoder().decode(
            ExportService.BackupDocument.self,
            from: Data(contentsOf: url)
        )

        XCTAssertEqual(document.payload.mealRecords.count, 65)
        XCTAssertEqual(document.payload.mealRecords.map(\.id), expectedIDs)
    }

    func testRestorePagesInterruptedRequestHistoryAcross64RowBoundary() async throws {
        let schema = Schema(versionedSchema: DensosoSchemaV12.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let source = ModelContext(container)
        let service = ExportService()
        let backupURL = try await service.exportJSON(context: source)
        defer { try? FileManager.default.removeItem(at: backupURL) }

        let target = ModelContext(container)
        let conversationID = UUID(uuidString: "00000000-0000-0000-0000-000000000961")!
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        for index in 0..<65 {
            let requestID = UUID()
            target.insert(AgentRequestRecord(
                requestID: requestID,
                conversationID: conversationID,
                startedAt: startedAt.addingTimeInterval(TimeInterval(index)),
                absoluteDeadline: startedAt.addingTimeInterval(TimeInterval(index + 45)),
                maximumProviderRounds: 5,
                maximumToolCalls: 8,
                stateRaw: AgentRequestState.interrupted.rawValue
            ))
            target.insert(MessageRecord(
                conversationID: conversationID,
                roleRaw: ModelRole.user.rawValue,
                contentData: Data("unfinished-\(index)".utf8),
                ordinal: index,
                requestID: requestID
            ))
        }
        let completedRequestID = UUID()
        target.insert(AgentRequestRecord(
            requestID: completedRequestID,
            conversationID: conversationID,
            startedAt: startedAt,
            absoluteDeadline: startedAt.addingTimeInterval(45),
            maximumProviderRounds: 5,
            maximumToolCalls: 8,
            stateRaw: AgentRequestState.completed.rawValue
        ))
        target.insert(MessageRecord(
            conversationID: conversationID,
            roleRaw: ModelRole.assistant.rawValue,
            contentData: Data("completed-history".utf8),
            ordinal: 65,
            requestID: completedRequestID
        ))
        target.insert(MessageRecord(
            conversationID: conversationID,
            roleRaw: ModelRole.assistant.rawValue,
            contentData: Data("legacy-history".utf8),
            ordinal: 66
        ))
        try target.save()

        _ = try await service.restoreJSON(url: backupURL, context: target)

        XCTAssertEqual(try target.fetchCount(FetchDescriptor<AgentRequestRecord>()), 0)
        let restoredMessages = try target.fetch(FetchDescriptor<MessageRecord>())
        XCTAssertEqual(Set(restoredMessages.map { String(decoding: $0.contentData, as: UTF8.self) }), Set([
            "completed-history", "legacy-history",
        ]))
    }

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
        XCTAssertEqual(exportedDocument.formatVersion, 7)

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
        XCTAssertEqual(metrics[0].totalIntakeKcal, 0)
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

    func testRestoreRejectsInvalidUserPreferenceBackupFields() async throws {
        let (sourceContainer, source) = try makeContext()
        _ = sourceContainer
        source.insert(UserPreferenceRecord(
            sourceActionKey: "confirmed-preference-validation",
            categoryRaw: UserPreferenceCategory.food.rawValue,
            statement: "不吃香菜",
            sourceRaw: UserPreferenceSource.userReported.rawValue
        ))
        try source.save()

        let service = ExportService()
        let backupURL = try await service.exportJSON(context: source)
        defer { try? FileManager.default.removeItem(at: backupURL) }
        let originalObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: backupURL)) as? [String: Any]
        )
        let (targetContainer, target) = try makeContext()
        _ = targetContainer
        target.insert(MealRecord(totalCaloriesKcal: 777))
        try target.save()

        let invalidValues: [(String, Any)] = [
            ("sourceRaw", "healthKit"),
            ("categoryRaw", "healthKit"),
            ("statement", String(repeating: "x", count: 501)),
        ]
        for (field, value) in invalidValues {
            var payloadObject = try XCTUnwrap(originalObject["payload"] as? [String: Any])
            var preferences = try XCTUnwrap(payloadObject["userPreferences"] as? [[String: Any]])
            preferences[0][field] = value
            payloadObject["userPreferences"] = preferences

            let payloadData = try JSONSerialization.data(withJSONObject: payloadObject, options: [.sortedKeys])
            let payload = try JSONDecoder().decode(ExportService.BackupPayload.self, from: payloadData)
            let document = ExportService.BackupDocument(
                formatVersion: 5,
                checksum: try service.checksum(for: payload),
                payload: payload
            )
            let invalidURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("invalid-preference-backup-\(UUID().uuidString).json")
            try JSONEncoder().encode(document).write(to: invalidURL)

            do {
                _ = try await service.restoreJSON(url: invalidURL, context: target)
                XCTFail("Expected invalid preference field \(field) to be rejected")
            } catch {
                XCTAssertEqual(error as? ExportService.BackupError, .invalidUserPreference)
            }
            try? FileManager.default.removeItem(at: invalidURL)
        }

        XCTAssertEqual(try target.fetch(FetchDescriptor<MealRecord>()).first?.totalCaloriesKcal, 777)
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
            energyQuality: "observed",
            projectionVersion: "energy-accounting-v2",
            sourceFingerprint: "fixture-fingerprint"
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
        source.insert(DailyCheckInRecord(
            sourceActionKey: "confirmed-checkin-export",
            occurredAt: date,
            energyRaw: "low",
            stressRaw: "elevated",
            subjectiveSleepRaw: "poor",
            note: "user-reported check-in",
            sourceRaw: "userReported"
        ))
        source.insert(UserPreferenceRecord(
            sourceActionKey: "confirmed-preference-export",
            categoryRaw: UserPreferenceCategory.food.rawValue,
            statement: "不吃香菜",
            sourceRaw: UserPreferenceSource.userReported.rawValue,
            createdAt: date
        ))
        let priorKey = try XCTUnwrap(MealPortionPriorStorageKey.make(
            foodID: "rice-id",
            foodName: "米饭",
            unit: "碗"
        ))
        source.insert(PersonalMealPortionPriorRecord(
            priorKey: priorKey,
            foodID: "rice-id",
            foodName: "米饭",
            unit: "碗",
            p10Grams: 150,
            p50Grams: 180,
            p90Grams: 210,
            sourceActionKey: "confirmed-meal-action",
            createdAt: date,
            updatedAt: date
        ))
        let dishIngredient = try XCTUnwrap(PersonalMealDishIngredientPrior(
            foodID: "rice-id",
            name: "米饭",
            lowGrams: 150,
            likelyGrams: 180,
            highGrams: 210,
            preparation: .cooked,
            massBasis: .cooked,
            sourceID: "cn-food-table",
            sourceRecordID: "rice-cooked-001",
            sourceVersion: "food-table-2026-01",
            licenseStatus: "verified"
        ))
        let dishKey = try XCTUnwrap(MealDishPriorStorageKey.make(
            dishName: "盖饭",
            cookingMethod: "stirFry",
            ingredients: [dishIngredient]
        ))
        let dishIngredientEncoder = JSONEncoder()
        dishIngredientEncoder.outputFormatting = [.sortedKeys]
        source.insert(PersonalMealDishPriorRecord(
            priorKey: dishKey.priorKey,
            dishKey: dishKey.dishKey,
            dishName: "盖饭",
            cookingMethodKey: dishKey.cookingMethodKey,
            cookingMethod: "stirFry",
            ingredientsJSON: String(data: try dishIngredientEncoder.encode([dishIngredient]), encoding: .utf8)!,
            observationCount: 0,
            isUserManaged: true,
            sourceActionKey: nil,
            createdAt: date,
            updatedAt: date
        ))
        let unconfirmedPreference = ActionPayload.userPreference(UserPreference(
            category: .communication,
            statement: "未确认的偏好",
            createdAt: date
        ))
        let pendingEncoder = JSONEncoder()
        pendingEncoder.dateEncodingStrategy = .millisecondsSince1970
        source.insert(PendingActionRecord(
            idempotencyKey: "unconfirmed-preference-export",
            actionTypeRaw: ActionType.userPreference.rawValue,
            canonicalPayloadData: try unconfirmedPreference.canonicalData(),
            payloadData: try pendingEncoder.encode(unconfirmedPreference),
            clientRequestID: UUID(),
            createdAt: date,
            expiresAt: date.addingTimeInterval(3_600)
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
        XCTAssertEqual(exported.formatVersion, 7)
        XCTAssertEqual(exported.payload.weightRecords?.count, 1)
        XCTAssertEqual(exported.payload.profileRevisions?.count, 1)
        XCTAssertEqual(exported.payload.dailyMetricsProjection?.first?.sourceFingerprint, "fixture-fingerprint")
        XCTAssertEqual(exported.payload.dailyHealthSnapshots?.count, 1)
        XCTAssertEqual(exported.payload.goalProfiles?.count, 1)
        XCTAssertEqual(exported.payload.dailyCheckIns?.count, 1)
        XCTAssertEqual(exported.payload.userPreferences?.count, 1)
        XCTAssertEqual(exported.payload.mealPortionPriors?.count, 1)
        XCTAssertEqual(exported.payload.mealDishPriors?.count, 1)
        XCTAssertFalse(String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("未确认的偏好"))
        XCTAssertEqual(exported.payload.dailyBriefs?.count, 1)
        XCTAssertEqual(exported.payload.weeklyBriefs?.count, 1)
        XCTAssertEqual(exported.payload.scheduleEvents?.count, 1)

        let (targetContainer, target) = try makeContext()
        _ = targetContainer
        target.insert(HealthSyncOutboxEntry(operation: "upsertMeal", recordID: UUID()))
        target.insert(HealthKitImportCursor(stream: "workouts", anchorData: Data([9])))
        let interruptedRequestID = UUID(uuidString: "00000000-0000-0000-0000-000000000951")!
        let requestConversationID = UUID(uuidString: "00000000-0000-0000-0000-000000000952")!
        target.insert(ConversationRecord(id: requestConversationID))
        target.insert(AgentRequestRecord(
            requestID: interruptedRequestID,
            conversationID: requestConversationID,
            startedAt: date,
            absoluteDeadline: date.addingTimeInterval(45),
            maximumProviderRounds: 5,
            maximumToolCalls: 8,
            providerRoundsUsed: 1,
            stateRaw: AgentRequestState.interrupted.rawValue
        ))
        target.insert(MessageRecord(
            conversationID: requestConversationID,
            roleRaw: ModelRole.user.rawValue,
            contentData: Data("not-part-of-backup".utf8),
            ordinal: 0,
            requestID: interruptedRequestID
        ))
        try target.save()
        let summary = try await service.restoreJSON(url: url, context: target)

        XCTAssertEqual(summary.weights, 1)
        XCTAssertEqual(summary.healthDays, 1)
        XCTAssertEqual(summary.dailyCheckIns, 1)
        XCTAssertEqual(summary.mealPortionPriors, 1)
        XCTAssertEqual(summary.mealDishPriors, 1)
        let restoredPrior = try XCTUnwrap(target.fetch(FetchDescriptor<PersonalMealPortionPriorRecord>()).first)
        XCTAssertEqual(restoredPrior.foodName, "米饭")
        XCTAssertEqual(restoredPrior.p50Grams, 180, accuracy: 0.001)
        let restoredDishPrior = try XCTUnwrap(target.fetch(FetchDescriptor<PersonalMealDishPriorRecord>()).first)
        XCTAssertEqual(restoredDishPrior.dishName, "盖饭")
        XCTAssertTrue(restoredDishPrior.isUserManaged)
        let restoredDishIngredients = try JSONDecoder().decode(
            [PersonalMealDishIngredientPrior].self,
            from: Data(restoredDishPrior.ingredientsJSON.utf8)
        )
        XCTAssertEqual(restoredDishIngredients.first?.massBasis, .cooked)
        XCTAssertEqual(restoredDishIngredients.first?.sourceRecordID, "rice-cooked-001")
        XCTAssertEqual(summary.userPreferences, 1)
        XCTAssertEqual(summary.scheduledPlans, 0)
        XCTAssertEqual(try target.fetch(FetchDescriptor<WeightRecord>()).first?.kilograms, 70.5)
        XCTAssertEqual(try target.fetch(FetchDescriptor<WeightRecord>()).first?.confidence, 0.9)
        XCTAssertEqual(try target.fetch(FetchDescriptor<ProfileRevisionRecord>()).first?.heightCm, 165)
        XCTAssertEqual(try target.fetch(FetchDescriptor<GoalProfileRecord>()).first?.dailyProteinGrams, 90)
        let restoredCheckIn = try XCTUnwrap(target.fetch(FetchDescriptor<DailyCheckInRecord>()).first)
        XCTAssertEqual(restoredCheckIn.energyRaw, "low")
        XCTAssertEqual(restoredCheckIn.stressRaw, "elevated")
        XCTAssertEqual(restoredCheckIn.subjectiveSleepRaw, "poor")
        XCTAssertEqual(restoredCheckIn.sourceRaw, "userReported")
        let restoredPreference = try XCTUnwrap(target.fetch(FetchDescriptor<UserPreferenceRecord>()).first)
        XCTAssertEqual(restoredPreference.categoryRaw, "food")
        XCTAssertEqual(restoredPreference.statement, "不吃香菜")
        XCTAssertEqual(restoredPreference.sourceRaw, "userReported")
        XCTAssertEqual(try target.fetch(FetchDescriptor<ScheduleEvent>()).first?.title, "药物提醒")
        XCTAssertEqual(try target.fetchCount(FetchDescriptor<HealthSyncOutboxEntry>()), 0)
        XCTAssertEqual(try target.fetchCount(FetchDescriptor<HealthKitImportCursor>()), 0)
        XCTAssertEqual(try target.fetchCount(FetchDescriptor<AgentRequestRecord>()), 0)
        XCTAssertEqual(
            try target.fetch(FetchDescriptor<MessageRecord>()).filter { $0.requestID == interruptedRequestID }.count,
            0
        )
        XCTAssertEqual(try target.fetch(FetchDescriptor<DailyBriefRecord>()).first?.payloadData, Data("daily-brief".utf8))
    }

    func testConfirmedTrainingPlanBackupRoundTripsScheduleNotesAndCountsPlan() async throws {
        let (sourceContainer, source) = try makeContext()
        _ = sourceContainer
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let tomorrow = start.addingTimeInterval(24 * 60 * 60)
        let draft = TrainingPlanDraft(
            name: "两日训练",
            createdAt: start,
            sessions: [
                TrainingSessionDraft(
                    date: start,
                    activity: .running,
                    goal: .timeMinutes(30),
                    location: .outdoor,
                    recommendedIntensity: .easy,
                    reason: "轻松跑"
                ),
                TrainingSessionDraft(date: tomorrow, activity: nil, reason: "休息日"),
            ]
        )
        let entry = ConfirmedTrainingPlanEntry(
            actionID: UUID(),
            idempotencyKey: "backup-training-plan",
            draft: draft
        )
        let notes = try entry.encodedNotes()
        source.insert(ScheduleEvent(date: start, title: draft.name, notes: notes, startTime: start))
        try source.save()

        let service = ExportService()
        let url = try await service.exportJSON(context: source)
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try JSONDecoder().decode(
            ExportService.BackupDocument.self,
            from: Data(contentsOf: url)
        )
        XCTAssertEqual(document.payload.scheduleEvents?.first?.notes, notes)

        let (targetContainer, target) = try makeContext()
        _ = targetContainer
        let summary = try await service.restoreJSON(url: url, context: target)
        let restoredEvent = try XCTUnwrap(target.fetch(FetchDescriptor<ScheduleEvent>()).first)
        XCTAssertEqual(summary.scheduledPlans, 1)
        XCTAssertEqual(restoredEvent.notes, notes)
        XCTAssertEqual(ConfirmedTrainingPlanEntry.decode(notes: restoredEvent.notes)?.draft, draft)
    }

    func testRestoreRejectsMalformedOrInvalidConfirmedTrainingPlanBeforeReplacingData() async throws {
        let service = ExportService()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let (sourceContainer, source) = try makeContext()
        _ = sourceContainer
        source.insert(ScheduleEvent(date: date, title: "source schedule", notes: "ordinary", startTime: date))
        try source.save()
        let backupURL = try await service.exportJSON(context: source)
        defer { try? FileManager.default.removeItem(at: backupURL) }
        let originalObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: backupURL)) as? [String: Any]
        )

        let (targetContainer, target) = try makeContext()
        _ = targetContainer
        target.insert(MealRecord(date: date, totalCaloriesKcal: 777))
        target.insert(ScheduleEvent(date: date, title: "preserve me", notes: "target", startTime: date))
        try target.save()
        let invalidDraft = TrainingPlanDraft(name: "", createdAt: date, sessions: [])
        let invalidEntry = ConfirmedTrainingPlanEntry(
            actionID: UUID(),
            idempotencyKey: "invalid-training-plan",
            draft: invalidDraft
        )

        for invalidNotes in [
            ConfirmedTrainingPlanEntry.notesPrefix + "not-base64",
            try invalidEntry.encodedNotes(),
        ] {
            var payloadObject = try XCTUnwrap(originalObject["payload"] as? [String: Any])
            var scheduleEvents = try XCTUnwrap(payloadObject["scheduleEvents"] as? [[String: Any]])
            scheduleEvents[0]["notes"] = invalidNotes
            payloadObject["scheduleEvents"] = scheduleEvents
            let payloadData = try JSONSerialization.data(withJSONObject: payloadObject, options: [.sortedKeys])
            let payload = try JSONDecoder().decode(ExportService.BackupPayload.self, from: payloadData)
            let document = ExportService.BackupDocument(
                formatVersion: 5,
                checksum: try service.checksum(for: payload),
                payload: payload
            )
            let invalidURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("invalid-training-plan-backup-\(UUID().uuidString).json")
            try JSONEncoder().encode(document).write(to: invalidURL)

            do {
                _ = try await service.restoreJSON(url: invalidURL, context: target)
                XCTFail("Expected invalid training plan entry to be rejected")
            } catch {
                XCTAssertEqual(error as? ExportService.BackupError, .invalidTrainingPlan)
            }
            try? FileManager.default.removeItem(at: invalidURL)
            XCTAssertEqual(try target.fetch(FetchDescriptor<MealRecord>()).first?.totalCaloriesKcal, 777)
            XCTAssertEqual(try target.fetch(FetchDescriptor<ScheduleEvent>()).first?.title, "preserve me")
        }
    }

    private func makeContext() throws -> (ModelContainer, ModelContext) {
        let container = try ModelContainer(
            for: UserProfile.self, MealRecord.self, DishEntry.self, WorkoutRecord.self, DailyMetrics.self, WeeklyReport.self,
            ScheduleEvent.self, WeightRecord.self, ProfileRevisionRecord.self, GoalProfileRecord.self, DailyHealthSnapshotRecord.self,
            DailyBriefRecord.self, WeeklyBriefRecord.self, HealthSyncOutboxEntry.self, HealthKitImportCursor.self,
            AgentRequestRecord.self, DailyCheckInRecord.self, UserPreferenceRecord.self,
            PersonalMealPortionPriorRecord.self,
            PersonalMealDishPriorRecord.self,
            ConsentRecord.self,
            CloudHealthContextPolicyRecord.self,
            PendingActionRecord.self, CommittedActionReceiptRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return (container, ModelContext(container))
    }
}
