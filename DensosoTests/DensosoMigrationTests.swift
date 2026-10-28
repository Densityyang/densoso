import CryptoKit
import DensosoDomain
import SwiftData
import XCTest
@testable import Densoso

@MainActor
final class DensosoMigrationTests: XCTestCase {
    func testPersistenceBootstrapErrorsUseSafeReadOnlyDescriptor() {
        let error = PersistenceBootstrapError.backupFailed
        let descriptor = error.sharedErrorDescriptor

        XCTAssertEqual(descriptor.code, .actionConflict)
        XCTAssertEqual(descriptor.reason, .persistenceReadOnly)
        XCTAssertEqual(error.localizedDescription, descriptor.userMessage)
        XCTAssertTrue(descriptor.diagnosticSafeDetail.contains("subsystem=projection"))
    }

    func testV1DiskFixtureMigratesToCurrentSchemaWithoutRecalculation() throws {
        let seed = try Gate02FixtureLoader.load("v1-seed", as: Gate02Seed.self)
        let expected = try Gate02FixtureLoader.load(
            "expected-migration",
            as: Gate02ExpectedMigration.self
        )
        let location = try TemporaryStoreLocation()
        defer { location.remove() }
        try createV1Store(seed: seed, at: location.storeURL)

        let container = try openCurrentStore(at: location.storeURL)
        let context = ModelContext(container)
        let meal = try XCTUnwrap(context.fetch(FetchDescriptor<MealRecord>()).first)
        let dish = try XCTUnwrap(context.fetch(FetchDescriptor<DishEntry>()).first)
        let workout = try XCTUnwrap(context.fetch(FetchDescriptor<WorkoutRecord>()).first)
        let profile = try XCTUnwrap(context.fetch(FetchDescriptor<UserProfile>()).first)

        XCTAssertEqual(meal.id, seed.mealID)
        XCTAssertEqual(meal.totalCaloriesKcal, seed.mealCalories)
        XCTAssertEqual(meal.algorithmVersion, seed.mealAlgorithmVersion)
        XCTAssertEqual(meal.energyLowKcal, Double(seed.mealCalories))
        XCTAssertEqual(meal.energyLikelyKcal, Double(seed.mealCalories))
        XCTAssertEqual(meal.energyHighKcal, Double(seed.mealCalories))
        XCTAssertEqual(
            MealRecordEnergyPresentation(
                totalCaloriesKcal: meal.totalCaloriesKcal,
                evidenceData: meal.evidenceData
            ).label,
            "\(seed.mealCalories) kcal"
        )
        XCTAssertEqual(meal.dishes.count, 1)
        XCTAssertEqual(dish.mealRecord?.id, meal.id)
        XCTAssertEqual(dish.dishName, "fixture dish")
        XCTAssertEqual(dish.estimatedCaloriesKcal, seed.mealCalories)
        XCTAssertEqual(dish.energyLikelyKcal, Double(seed.mealCalories))
        let evidence = try XCTUnwrap(meal.evidenceData)
        XCTAssertEqual(
            try JSONDecoder().decode([EvidenceSnapshot].self, from: evidence).first?.grade.rawValue,
            expected.legacyEvidenceGrade
        )
        XCTAssertEqual(workout.id, seed.workoutID)
        XCTAssertEqual(workout.type, "walking")
        XCTAssertEqual(workout.durationMinutes, 30)
        XCTAssertEqual(workout.estimatedCaloriesBurned, seed.workoutCalories)
        XCTAssertEqual(workout.workoutOrigin, expected.v1WorkoutOrigin)
        XCTAssertEqual(workout.dataQuality, expected.v1WorkoutDataQuality)
        XCTAssertEqual(workout.routeStatus, expected.v1WorkoutRouteStatus)
        XCTAssertEqual(profile.name, "fixture")
        XCTAssertNil(profile.dateOfBirth)
        XCTAssertTrue(profile.profileNeedsCompletion)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DailyMetrics>()), 1)
        let migratedMetric = try XCTUnwrap(context.fetch(FetchDescriptor<DailyMetrics>()).first)
        XCTAssertEqual(migratedMetric.intakeEnergyLikelyKcal, Double(migratedMetric.totalIntakeKcal))
        XCTAssertTrue(migratedMetric.requiresRecompute)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<WeeklyReport>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ScheduleEvent>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<HealthSyncOutboxEntry>()), 1)
        try attachJSONReport(
            named: "gate02-v1-migration-report.json",
            values: [
                "sourceVersion": seed.version,
                "outcome": "migrated",
                "mealID": meal.id.uuidString.lowercased(),
                "algorithmVersion": meal.algorithmVersion,
                "workoutOrigin": workout.workoutOrigin,
            ]
        )
    }

    func testV2DiskFixtureMigratesToCurrentSchemaAndPreservesCursorAndOutbox() throws {
        let seed = try Gate02FixtureLoader.load("v2-seed", as: Gate02Seed.self)
        let expected = try Gate02FixtureLoader.load(
            "expected-migration",
            as: Gate02ExpectedMigration.self
        )
        let location = try TemporaryStoreLocation()
        defer { location.remove() }
        try createV2Store(seed: seed, at: location.storeURL)

        var container: ModelContainer? = try openCurrentStore(at: location.storeURL)
        var context: ModelContext? = ModelContext(container!)
        let meal = try XCTUnwrap(context!.fetch(FetchDescriptor<MealRecord>()).first)
        let dish = try XCTUnwrap(context!.fetch(FetchDescriptor<DishEntry>()).first)
        let workout = try XCTUnwrap(context!.fetch(FetchDescriptor<WorkoutRecord>()).first)
        let cursor = try XCTUnwrap(context!.fetch(FetchDescriptor<HealthKitImportCursor>()).first)
        let outbox = try XCTUnwrap(context!.fetch(FetchDescriptor<HealthSyncOutboxEntry>()).first)

        XCTAssertEqual(meal.id, seed.mealID)
        XCTAssertEqual(meal.algorithmVersion, seed.mealAlgorithmVersion)
        XCTAssertEqual(meal.energyLikelyKcal, Double(seed.mealCalories))
        XCTAssertEqual(
            MealRecordEnergyPresentation(
                totalCaloriesKcal: meal.totalCaloriesKcal,
                evidenceData: meal.evidenceData
            ).label,
            "\(seed.mealCalories) kcal"
        )
        XCTAssertEqual(meal.dishes.count, 1)
        XCTAssertEqual(dish.mealRecord?.id, meal.id)
        XCTAssertEqual(dish.estimatedCaloriesKcal, seed.mealCalories)
        // V2's default zero values cannot distinguish missing macros from measured zero.
        XCTAssertEqual([meal.proteinLowG, meal.proteinLikelyG, meal.proteinHighG], [nil, nil, nil])
        XCTAssertEqual([meal.fatLowG, meal.fatLikelyG, meal.fatHighG], [nil, nil, nil])
        XCTAssertEqual([meal.carbsLowG, meal.carbsLikelyG, meal.carbsHighG], [nil, nil, nil])
        XCTAssertEqual([dish.proteinLowG, dish.proteinLikelyG, dish.proteinHighG], [nil, nil, nil])
        XCTAssertEqual([dish.fatLowG, dish.fatLikelyG, dish.fatHighG], [nil, nil, nil])
        XCTAssertEqual([dish.carbsLowG, dish.carbsLikelyG, dish.carbsHighG], [nil, nil, nil])
        XCTAssertEqual(workout.id, seed.workoutID)
        XCTAssertEqual(workout.estimatedCaloriesBurned, seed.workoutCalories)
        XCTAssertEqual(workout.workoutOrigin, "externalHealthKit")
        XCTAssertEqual(workout.energySource, "measured")
        XCTAssertEqual(cursor.anchorData, seed.cursorBytes.map { Data($0) })
        XCTAssertEqual(outbox.attemptCount, expected.outboxAttemptCount)
        XCTAssertEqual(outbox.state, expected.outboxState)
        XCTAssertFalse(outbox.idempotencyKey.isEmpty)
        let migratedMealID = meal.id
        let migratedAlgorithmVersion = meal.algorithmVersion

        context = nil
        container = nil
        container = try openCurrentStore(at: location.storeURL)
        context = ModelContext(container!)
        XCTAssertEqual(try context!.fetchCount(FetchDescriptor<MealRecord>()), 1)
        XCTAssertEqual(try context!.fetchCount(FetchDescriptor<HealthSyncOutboxEntry>()), 1)
        try attachJSONReport(
            named: "gate02-v2-migration-report.json",
            values: [
                "sourceVersion": seed.version,
                "outcome": "migrated-and-reopened",
                "mealID": migratedMealID.uuidString.lowercased(),
                "algorithmVersion": migratedAlgorithmVersion,
                "cursorBytes": String(seed.cursorBytes?.count ?? 0),
            ]
        )
    }

    func testV2MigrationPreservesPositiveLegacyMacroPointEstimates() throws {
        let seed = try Gate02FixtureLoader.load("v2-seed", as: Gate02Seed.self)
        let location = try TemporaryStoreLocation()
        defer { location.remove() }
        try createV2Store(
            seed: seed,
            at: location.storeURL,
            mealNutrients: (proteinG: 24.5, fatG: 11.25, carbsG: 33.75),
            dishNutrients: (proteinG: 8.5, fatG: 2.75, carbsG: 11.25)
        )

        let container = try openCurrentStore(at: location.storeURL)
        let context = ModelContext(container)
        let meal = try XCTUnwrap(context.fetch(FetchDescriptor<MealRecord>()).first)
        let dish = try XCTUnwrap(context.fetch(FetchDescriptor<DishEntry>()).first)

        XCTAssertEqual([meal.proteinLowG, meal.proteinLikelyG, meal.proteinHighG], [24.5, 24.5, 24.5])
        XCTAssertEqual([meal.fatLowG, meal.fatLikelyG, meal.fatHighG], [11.25, 11.25, 11.25])
        XCTAssertEqual([meal.carbsLowG, meal.carbsLikelyG, meal.carbsHighG], [33.75, 33.75, 33.75])
        XCTAssertEqual([dish.proteinLowG, dish.proteinLikelyG, dish.proteinHighG], [8.5, 8.5, 8.5])
        XCTAssertEqual([dish.fatLowG, dish.fatLikelyG, dish.fatHighG], [2.75, 2.75, 2.75])
        XCTAssertEqual([dish.carbsLowG, dish.carbsLikelyG, dish.carbsHighG], [11.25, 11.25, 11.25])
    }

    func testV2DefaultZeroEnergyMigratesAsUnavailableInHistory() throws {
        let seed = try Gate02FixtureLoader.load("v2-seed", as: Gate02Seed.self)
        let location = try TemporaryStoreLocation()
        defer { location.remove() }
        try createV2Store(
            seed: seed,
            at: location.storeURL,
            mealCalories: 0,
            dishCalories: 0
        )

        let container = try openCurrentStore(at: location.storeURL)
        let context = ModelContext(container)
        let meal = try XCTUnwrap(context.fetch(FetchDescriptor<MealRecord>()).first)
        let dish = try XCTUnwrap(context.fetch(FetchDescriptor<DishEntry>()).first)
        let mealEvidence = try XCTUnwrap(meal.evidenceData)
        let dishEvidence = try XCTUnwrap(dish.evidenceData)
        let decoder = JSONDecoder()
        let decodedMealEvidence = try decoder.decode([EvidenceSnapshot].self, from: mealEvidence)
        let decodedDishEvidence = try decoder.decode([EvidenceSnapshot].self, from: dishEvidence)

        // Schema V3's nonoptional compatibility fields retain the old sentinel,
        // while evidence and History presentation treat it as unavailable.
        XCTAssertEqual(meal.energyLikelyKcal, 0)
        XCTAssertTrue(decodedMealEvidence.contains { $0.grade == .legacyPointEstimate })
        XCTAssertTrue(decodedMealEvidence.contains {
            $0.sourceID == "legacy-v2-default-zero-energy" && $0.grade == .unresolved
        })
        let historyEnergy = MealRecordEnergyPresentation(
            totalCaloriesKcal: meal.totalCaloriesKcal,
            evidenceData: meal.evidenceData
        )
        XCTAssertEqual(historyEnergy.label, "热量不可用")
        XCTAssertFalse(historyEnergy.isAvailable)
        XCTAssertEqual(dish.energyLikelyKcal, 0)
        XCTAssertTrue(decodedDishEvidence.contains {
            $0.sourceID == "legacy-v2-default-zero-energy" && $0.grade == .unresolved
        })
    }

    func testHistoryMealEnergyPresentationDistinguishesZeroFromUnavailable() throws {
        let encoder = JSONEncoder()
        let legacyZero = try encoder.encode([
            EvidenceSnapshot(grade: .legacyPointEstimate, sourceID: "swiftdata-v2", summary: "old point"),
            EvidenceSnapshot(grade: .unresolved, sourceID: "legacy-v2-default-zero-energy", summary: "unknown"),
        ])
        let measuredZero = try encoder.encode([
            EvidenceSnapshot(grade: .measured, sourceID: "user-measured", summary: "measured zero"),
        ])

        let legacyPresentation = MealRecordEnergyPresentation(totalCaloriesKcal: 0, evidenceData: legacyZero)
        XCTAssertEqual(legacyPresentation.label, "热量不可用")
        XCTAssertFalse(legacyPresentation.isAvailable)

        let measuredPresentation = MealRecordEnergyPresentation(totalCaloriesKcal: 0, evidenceData: measuredZero)
        XCTAssertEqual(measuredPresentation.label, "0 kcal")
        XCTAssertTrue(measuredPresentation.isAvailable)

        let legacyPointPresentation = MealRecordEnergyPresentation(totalCaloriesKcal: 640, evidenceData: legacyZero)
        XCTAssertEqual(legacyPointPresentation.label, "640 kcal")
        XCTAssertTrue(legacyPointPresentation.isAvailable)

        let missingEvidencePresentation = MealRecordEnergyPresentation(totalCaloriesKcal: 0, evidenceData: nil)
        XCTAssertEqual(missingEvidencePresentation.label, "热量不可用")
        XCTAssertFalse(missingEvidencePresentation.isAvailable)
    }

    func testV3MigrationToCurrentSchemaCreatesTimeAwareProfileAndWeightRecords() throws {
        let location = try TemporaryStoreLocation()
        defer { location.remove() }
        var container: ModelContainer? = try makeContainer(
            version: DensosoSchemaV3.self,
            url: location.storeURL
        )
        var context: ModelContext? = ModelContext(container!)
        let measuredAt = Date(timeIntervalSince1970: 1_700_000_000)
        let profile = DensosoSchemaV3.UserProfile(
            name: "fixture",
            biologicalSex: "female",
            dateOfBirth: Date(timeIntervalSince1970: 631_152_000),
            heightCm: 165,
            weightKg: 62,
            activityLevel: "moderate"
        )
        profile.createdAt = Date(timeIntervalSince1970: 1_600_000_000)
        profile.updatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let history = [
            MigrationWeightEntry(date: measuredAt, kg: 64.5),
            MigrationWeightEntry(date: measuredAt, kg: 64.5),
        ]
        profile.weightHistoryJSON = String(data: try JSONEncoder().encode(history), encoding: .utf8)!
        context!.insert(profile)
        context!.insert(
            DensosoSchemaV3.DailyMetrics(
                date: measuredAt,
                totalExpenditureKcal: 1_800,
                totalIntakeKcal: 700,
                deficitKcal: 1_100
            )
        )
        try context!.save()
        context = nil
        container = nil

        container = try openCurrentStore(at: location.storeURL)
        context = ModelContext(container!)
        let migratedProfile = try XCTUnwrap(context!.fetch(FetchDescriptor<UserProfile>()).first)
        let revision = try XCTUnwrap(context!.fetch(FetchDescriptor<ProfileRevisionRecord>()).first)
        let weight = try XCTUnwrap(context!.fetch(FetchDescriptor<WeightRecord>()).first)
        XCTAssertEqual(try context!.fetchCount(FetchDescriptor<WeightRecord>()), 1)
        let metric = try XCTUnwrap(context!.fetch(FetchDescriptor<DailyMetrics>()).first)

        XCTAssertEqual(migratedProfile.dateOfBirth, Date(timeIntervalSince1970: 631_152_000))
        XCTAssertFalse(migratedProfile.profileNeedsCompletion)
        XCTAssertEqual(revision.dateOfBirth, migratedProfile.dateOfBirth)
        XCTAssertEqual(revision.effectiveFrom, migratedProfile.updatedAt)
        XCTAssertEqual(revision.source, "legacyMigration")
        XCTAssertEqual(weight.measuredAt, measuredAt)
        XCTAssertEqual(weight.kilograms, 64.5)
        XCTAssertEqual(weight.source, "densoso")
        XCTAssertEqual(weight.confidence, 0.75)
        XCTAssertEqual(metric.intakeEnergyLowKcal, 700)
        XCTAssertEqual(metric.intakeEnergyLikelyKcal, 700)
        XCTAssertEqual(metric.intakeEnergyHighKcal, 700)
        XCTAssertEqual(metric.energyQuality, "legacy")
        XCTAssertTrue(metric.requiresRecompute)
    }

    func testV4StoreMigrationMarksOldProjectionForRecompute() throws {
        let location = try TemporaryStoreLocation()
        defer { location.remove() }
        var container: ModelContainer? = try makeContainer(
            version: DensosoSchemaV4.self,
            url: location.storeURL
        )
        var context: ModelContext? = ModelContext(container!)
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        context!.insert(DensosoSchemaV4.DailyMetrics(
            date: day,
            totalExpenditureKcal: 2_000,
            totalIntakeKcal: 1_500,
            deficitKcal: 500,
            energyQuality: "estimated",
            projectionVersion: AlgorithmVersions.calorieAccounting,
            sourceFingerprint: "v4-fingerprint",
            requiresRecompute: false
        ))
        try context!.save()
        context = nil
        container = nil

        container = try openCurrentStore(at: location.storeURL)
        context = ModelContext(container!)
        let migrated = try XCTUnwrap(context!.fetch(FetchDescriptor<DailyMetrics>()).first)

        XCTAssertTrue(migrated.requiresRecompute)
        XCTAssertEqual(migrated.projectionVersion, AlgorithmVersions.calorieAccounting)
        XCTAssertEqual(migrated.sourceFingerprint, "v4-fingerprint")
    }

    func testV6ToV7PreservesLegacyConversationAndRestoresToolSchemaV1() async throws {
        let location = try TemporaryStoreLocation()
        defer { location.remove() }
        var container: ModelContainer? = try makeContainer(version: DensosoSchemaV6.self, url: location.storeURL)
        var context: ModelContext? = ModelContext(container!)
        let conversationID = UUID(uuidString: "00000000-0000-0000-0000-000000000707")!
        let legacyMessage = ModelMessage(role: .user, text: "迁移前的对话")
        context!.insert(ConversationRecord(id: conversationID))
        context!.insert(MessageRecord(
            conversationID: conversationID,
            roleRaw: ModelRole.user.rawValue,
            contentData: try JSONEncoder().encode(legacyMessage),
            ordinal: 0
        ))
        try context!.save()
        context = nil
        container = nil
        XCTAssertEqual(PersistentStoreVersionInspector.version(at: location.storeURL), "6.0.0")

        let migrated = try openV7Store(at: location.storeURL)
        let repository = SwiftDataAgentRepository(modelContainer: migrated)
        let schemaVersion = try await repository.toolSchemaVersion(conversationID: conversationID)
        XCTAssertEqual(schemaVersion, ToolSchemaVersion.legacy)
        let restoredMessages = try await repository.messageData(conversationID: conversationID)
        XCTAssertEqual(restoredMessages.count, 1)
        XCTAssertEqual(try JSONDecoder().decode(ModelMessage.self, from: restoredMessages[0]), legacyMessage)
        XCTAssertEqual(PersistentStoreVersionInspector.version(at: location.storeURL), "7.0.0")
    }

    func testV7ToV9PreservesHealthKitSampleIndexState() throws {
        let location = try TemporaryStoreLocation()
        defer { location.remove() }
        var container: ModelContainer? = try makeContainer(version: DensosoSchemaV7.self, url: location.storeURL)
        var context: ModelContext? = ModelContext(container!)
        let sampleID = UUID(uuidString: "00000000-0000-0000-0000-000000000808")!
        let day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        let dayKey = Self.dayKey(day)
        context!.insert(DensosoSchemaV6.HealthKitSampleIndexRecord(
            sampleID: sampleID,
            stream: HealthMetricID.bodyMass.rawValue,
            dayKey: dayKey,
            startDate: day,
            endDate: day,
            needsRequery: true,
            pendingDayKeys: [dayKey]
        ))
        try context!.save()
        context = nil
        container = nil
        XCTAssertEqual(PersistentStoreVersionInspector.version(at: location.storeURL), "7.0.0")

        let migrated = try openCurrentStore(at: location.storeURL)
        let migratedContext = ModelContext(migrated)
        let sampleIndex = try XCTUnwrap(
            migratedContext.fetch(FetchDescriptor<DensosoSchemaV8.HealthKitSampleIndexRecord>()).first
        )
        XCTAssertEqual(sampleIndex.sampleID, sampleID)
        XCTAssertEqual(sampleIndex.stream, HealthMetricID.bodyMass.rawValue)
        XCTAssertEqual(sampleIndex.dayKey, dayKey)
        XCTAssertEqual(sampleIndex.startDate, day)
        XCTAssertEqual(sampleIndex.endDate, day)
        XCTAssertEqual(
            try JSONDecoder().decode([String].self, from: Data(sampleIndex.pendingDayKeysJSON.utf8)),
            [dayKey]
        )
        XCTAssertTrue(sampleIndex.needsRequery)
        XCTAssertFalse(sampleIndex.isTombstoned)
        XCTAssertEqual(PersistentStoreVersionInspector.version(at: location.storeURL), "12.0.0")
    }

    func testV8MigrationMarksPriorRoundRequestCostUnavailableWithoutProviderIdentity() async throws {
        let location = try TemporaryStoreLocation()
        defer { location.remove() }
        var container: ModelContainer? = try makeContainer(version: DensosoSchemaV8.self, url: location.storeURL)
        var context: ModelContext? = ModelContext(container!)
        let conversationID = UUID(uuidString: "00000000-0000-0000-0000-000000000908")!
        let requestID = UUID(uuidString: "00000000-0000-0000-0000-000000000909")!
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        context!.insert(ConversationRecord(id: conversationID))
        context!.insert(AgentRequestRecord(
            requestID: requestID,
            conversationID: conversationID,
            startedAt: startedAt,
            absoluteDeadline: startedAt.addingTimeInterval(120),
            maximumProviderRounds: 3,
            maximumToolCalls: 2,
            providerRoundsUsed: 1,
            inputTokens: 40,
            outputTokens: 12,
            stateRaw: AgentRequestState.interrupted.rawValue
        ))
        let legacyUsage = DensosoSchemaV4.ProviderUsageRecord(
            usageKey: "legacy-provider-usage",
            provider: ProviderID.deepSeek.rawValue,
            model: "deepseek-flash",
            capability: ProviderCapability.text.rawValue
        )
        legacyUsage.inputTokens = 41
        legacyUsage.outputTokens = 12
        legacyUsage.estimatedCostMicros = 0
        legacyUsage.currency = "USD"
        legacyUsage.rateVersion = "unknown"
        context!.insert(legacyUsage)
        try context!.save()
        context = nil
        container = nil
        XCTAssertEqual(PersistentStoreVersionInspector.version(at: location.storeURL), "8.0.0")

        container = try openCurrentStore(at: location.storeURL)
        XCTAssertEqual(PersistentStoreVersionInspector.version(at: location.storeURL), "12.0.0")
        let migratedUsage = try XCTUnwrap(
            container!.mainContext.fetch(FetchDescriptor<ProviderUsageRecord>()).first
        )
        XCTAssertEqual(migratedUsage.usageKey, "legacy-provider-usage")
        XCTAssertEqual(migratedUsage.inputTokens, 41)
        XCTAssertEqual(migratedUsage.outputTokens, 12)
        XCTAssertEqual(migratedUsage.estimatedCostMicros, 0)
        XCTAssertEqual(migratedUsage.currency, "USD")
        XCTAssertEqual(migratedUsage.rateVersion, "unknown")
        XCTAssertNil(migratedUsage.requestID)
        XCTAssertEqual(migratedUsage.attempt, 0)
        XCTAssertEqual(migratedUsage.cachedInputTokens, 0)
        XCTAssertEqual(migratedUsage.reasoningTokens, 0)
        XCTAssertEqual(migratedUsage.imageCount, 0)
        XCTAssertNil(migratedUsage.latencyMilliseconds)
        let usageMonthStart = Date().addingTimeInterval(-60)
        let usageMonthEnd = Date().addingTimeInterval(60)
        let migratedUsageSummary = try await SwiftDataProviderGovernanceRepository(
            modelContainer: container!
        ).monthlyUsage(
            provider: .deepSeek,
            monthStart: usageMonthStart,
            monthEnd: usageMonthEnd
        )
        XCTAssertNil(migratedUsageSummary.estimatedCostMicros)
        XCTAssertNil(migratedUsageSummary.currency)
        let request = try await SwiftDataAgentRepository(modelContainer: container!)
            .beginAgentRequest(
                requestID: requestID,
                conversationID: conversationID,
                initialBudget: AgentBudget(maximumCostMicros: Int64.max, deadline: .distantFuture),
                startedAt: Date(),
                containsTransientImage: false
            )

        XCTAssertEqual(request.consumption.providerRoundsUsed, 1)
        XCTAssertEqual(request.consumption.inputTokens, 40)
        XCTAssertEqual(request.budget.maximumCostMicros, AgentBudget.defaultMaximumCostMicros)
        XCTAssertEqual(request.costBudget.state, .unavailable)
        XCTAssertEqual(request.costBudget.reservedCostMicros, 0)
    }

    func testV5MigrationMovesRawSamplesIntoIndexAndDailySummary() throws {
        let location = try TemporaryStoreLocation()
        defer { location.remove() }
        var container: ModelContainer? = try makeContainer(version: DensosoSchemaV5.self, url: location.storeURL)
        var context: ModelContext? = ModelContext(container!)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let day = Calendar.current.startOfDay(for: date)
        let sample = HealthSampleSnapshot(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000801")!,
            metric: .bodyMass,
            startDate: date,
            endDate: date,
            value: 68.5,
            sourceBundleIdentifier: "private.healthkit.source",
            deviceModel: "private.device.model",
            syncIdentifier: "private.sync.identifier"
        )
        let calendar = Calendar.current
        let wakeDay = calendar.date(byAdding: .day, value: 1, to: day)!
        let sleepSample = HealthSampleSnapshot(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000802")!,
            metric: .sleepAnalysis,
            startDate: calendar.date(bySettingHour: 22, minute: 0, second: 0, of: day)!,
            endDate: calendar.date(bySettingHour: 6, minute: 0, second: 0, of: wakeDay)!,
            categoryValue: "asleepCore",
            sourceBundleIdentifier: "com.example.health",
            deviceModel: "Watch6,1"
        )
        let legacySnapshot = LegacyDailyHealthSnapshot(
            dayStart: day,
            timezoneIdentifier: Calendar.current.timeZone.identifier,
            weightKilograms: 68.5,
            healthKitSamples: [sample, sleepSample],
            algorithmVersion: "v3"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let payload = try encoder.encode(legacySnapshot)
        context!.insert(DailyHealthSnapshotRecord(
            dayKey: Self.dayKey(day),
            timezoneID: legacySnapshot.timezoneIdentifier,
            payloadData: payload,
            snapshotHash: "legacy-sample-payload",
            algorithmVersion: legacySnapshot.algorithmVersion
        ))
        try context!.save()
        context = nil
        container = nil
        XCTAssertEqual(PersistentStoreVersionInspector.version(at: location.storeURL), "5.0.0")

        let migrated = try openV6Store(at: location.storeURL)
        let migratedContext = ModelContext(migrated)
        let migratedSnapshotRecord = try XCTUnwrap(
            migratedContext.fetch(FetchDescriptor<DailyHealthSnapshotRecord>()).first
        )
        let rawPayload = String(decoding: migratedSnapshotRecord.payloadData, as: UTF8.self)
        XCTAssertFalse(rawPayload.contains("healthKitSamples"))
        XCTAssertFalse(rawPayload.contains("private.healthkit.source"))
        XCTAssertFalse(rawPayload.contains("private.device.model"))
        XCTAssertFalse(rawPayload.contains("private.sync.identifier"))
        XCTAssertEqual(migratedSnapshotRecord.algorithmVersion, DailyHealthSnapshot.currentAlgorithmVersion)
        let expectedHash = SHA256.hash(data: migratedSnapshotRecord.payloadData)
            .map { String(format: "%02x", $0) }
            .joined()
        XCTAssertEqual(migratedSnapshotRecord.snapshotHash, expectedHash)
        let migratedDecoder = JSONDecoder()
        migratedDecoder.dateDecodingStrategy = .millisecondsSince1970
        let migratedSnapshot = try migratedDecoder.decode(
            DailyHealthSnapshot.self,
            from: migratedSnapshotRecord.payloadData
        )
        XCTAssertNil(migratedSnapshot.healthKitSamples)
        XCTAssertEqual(migratedSnapshot.healthKitSampleSummary?.aggregate(for: .bodyMass)?.latestValue, 68.5)
        let sampleIndex = try XCTUnwrap(migratedContext.fetch(
            FetchDescriptor<DensosoSchemaV6.HealthKitSampleIndexRecord>()
        ).first {
            $0.sampleID == sample.id
        })
        XCTAssertEqual(sampleIndex.sampleID, sample.id)
        XCTAssertEqual(sampleIndex.stream, HealthMetricID.bodyMass.rawValue)
        XCTAssertEqual(sampleIndex.dayKey, Self.dayKey(day))
        XCTAssertEqual(sampleIndex.startDate, sample.startDate)
        XCTAssertEqual(sampleIndex.endDate, sample.endDate)
        XCTAssertEqual(sampleIndex.pendingDayKeysJSON, "[]")
        XCTAssertFalse(sampleIndex.needsRequery)
        XCTAssertFalse(sampleIndex.isDeleted)
        XCTAssertEqual(
            try migratedContext.fetchCount(FetchDescriptor<DensosoSchemaV6.HealthKitSampleIndexRecord>()),
            2
        )
        let wakeDayKey = Self.dayKey(wakeDay)
        let wakePredicate = #Predicate<DailyHealthSnapshotRecord> { $0.dayKey == wakeDayKey }
        let wakeSnapshotRecord = try XCTUnwrap(
            migratedContext.fetch(FetchDescriptor<DailyHealthSnapshotRecord>(predicate: wakePredicate)).first
        )
        let wakeSnapshot = try migratedDecoder.decode(DailyHealthSnapshot.self, from: wakeSnapshotRecord.payloadData)
        XCTAssertEqual(wakeSnapshot.healthKitSampleSummary?.sleep?.totalAsleepMinutes, 480)
        XCTAssertEqual(PersistentStoreVersionInspector.version(at: location.storeURL), "6.0.0")
    }

    func testV5MigrationIndexesSleepSamplesAcrossMidnightAndAdjacentWindows() throws {
        let location = try TemporaryStoreLocation()
        defer { location.remove() }
        var container: ModelContainer? = try makeContainer(version: DensosoSchemaV5.self, url: location.storeURL)
        var context: ModelContext? = ModelContext(container!)
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        let wakeDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: day))
        let nextWakeDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: wakeDay))
        let firstStart = try XCTUnwrap(calendar.date(bySettingHour: 17, minute: 50, second: 0, of: day))
        let firstEnd = try XCTUnwrap(calendar.date(bySettingHour: 0, minute: 10, second: 0, of: wakeDay))
        let secondStart = try XCTUnwrap(calendar.date(bySettingHour: 17, minute: 50, second: 0, of: wakeDay))
        let secondEnd = try XCTUnwrap(calendar.date(bySettingHour: 0, minute: 10, second: 0, of: nextWakeDay))
        let workoutTime = try XCTUnwrap(calendar.date(bySettingHour: 12, minute: 0, second: 0, of: day))
        let samples: [HealthSampleSnapshot] = [
            HealthSampleSnapshot(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000811")!,
                metric: .sleepAnalysis,
                startDate: firstStart,
                endDate: firstEnd,
                categoryValue: "asleepCore",
                sourceBundleIdentifier: "com.example.health",
                deviceModel: "Watch6,1"
            ),
            HealthSampleSnapshot(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000812")!,
                metric: .sleepAnalysis,
                startDate: secondStart,
                endDate: secondEnd,
                categoryValue: "asleepCore",
                sourceBundleIdentifier: "com.example.health",
                deviceModel: "Watch6,1"
            ),
            HealthSampleSnapshot(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000813")!,
                metric: .workoutEffort,
                startDate: workoutTime,
                endDate: workoutTime.addingTimeInterval(10 * 60),
                value: 8
            ),
        ]
        let legacySnapshot = LegacyDailyHealthSnapshot(
            dayStart: day,
            timezoneIdentifier: calendar.timeZone.identifier,
            weightKilograms: nil,
            healthKitSamples: samples,
            algorithmVersion: "v5-sleep-window-fixture"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        context!.insert(DailyHealthSnapshotRecord(
            dayKey: Self.dayKey(day),
            timezoneID: legacySnapshot.timezoneIdentifier,
            payloadData: try encoder.encode(legacySnapshot),
            snapshotHash: "v5-sleep-window-fixture",
            algorithmVersion: legacySnapshot.algorithmVersion
        ))
        context!.insert(DensosoSchemaV4.WorkoutRecord(
            date: workoutTime,
            type: "running",
            durationMinutes: 30,
            estimatedCaloriesBurned: 200
        ))
        try context!.save()
        context = nil
        container = nil

        let migrated = try openV6Store(at: location.storeURL)
        let migratedContext = ModelContext(migrated)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970

        func snapshot(on date: Date) throws -> DailyHealthSnapshot {
            let dayKey = Self.dayKey(date)
            let predicate = #Predicate<DailyHealthSnapshotRecord> { $0.dayKey == dayKey }
            let record = try XCTUnwrap(migratedContext.fetch(
                FetchDescriptor<DailyHealthSnapshotRecord>(predicate: predicate)
            ).first)
            return try decoder.decode(DailyHealthSnapshot.self, from: record.payloadData)
        }

        let existingDaySnapshot = try snapshot(on: day)
        XCTAssertEqual(
            try XCTUnwrap(existingDaySnapshot.healthKitSampleSummary?.sleep?.totalAsleepMinutes),
            10,
            accuracy: 0.001
        )
        XCTAssertEqual(existingDaySnapshot.healthKitSampleSummary?.workoutEffort.first?.score, 8)
        XCTAssertEqual(
            try XCTUnwrap(snapshot(on: wakeDay).healthKitSampleSummary?.sleep?.totalAsleepMinutes),
            380,
            accuracy: 0.001
        )
        XCTAssertEqual(
            try XCTUnwrap(snapshot(on: nextWakeDay).healthKitSampleSummary?.sleep?.totalAsleepMinutes),
            370,
            accuracy: 0.001
        )
        XCTAssertEqual(
            try migratedContext.fetchCount(FetchDescriptor<DensosoSchemaV6.HealthKitSampleIndexRecord>()),
            3
        )
        XCTAssertEqual(try migratedContext.fetchCount(FetchDescriptor<DailyHealthSnapshotRecord>()), 3)
    }

    func testFaultingMigrationRestoresOriginalAndEntersReadOnlyRecovery() async throws {
        let seed = try Gate02FixtureLoader.load("v2-seed", as: Gate02Seed.self)
        let location = try TemporaryStoreLocation()
        defer { location.remove() }
        try createV2Store(seed: seed, at: location.storeURL)

        let bootstrap = PersistenceBootstrap.make(
            storeURL: location.storeURL,
            migrationPlan: Gate02FaultingMigrationPlan.self
        )

        XCTAssertFalse(bootstrap.state.allowsWrites)
        XCTAssertNotNil(bootstrap.backupManifest)
        let manifest = try XCTUnwrap(bootstrap.backupManifest)
        let backupDirectory = manifest.backupStoreURL.deletingLastPathComponent()
        let sourceDirectory = manifest.sourceStoreURL.deletingLastPathComponent()
        XCTAssertEqual(PersistentStoreVersionInspector.version(at: location.storeURL), "2.0.0")
        // The verified backup is the stable byte-level oracle. A just-closed
        // SwiftData fixture can checkpoint its WAL after createV2Store returns,
        // so comparing against raw bytes captured before backup creation races
        // SQLite's store-family lifecycle rather than testing restore integrity.
        for entry in manifest.files {
            XCTAssertEqual(
                try Data(contentsOf: backupDirectory.appendingPathComponent(entry.name)),
                try Data(contentsOf: sourceDirectory.appendingPathComponent(entry.name))
            )
        }
        var restoredContainer: ModelContainer? = try makeContainer(
            version: DensosoSchemaV2.self,
            url: location.storeURL
        )
        var restoredContext: ModelContext? = ModelContext(restoredContainer!)
        let restoredMeal = try XCTUnwrap(
            restoredContext!.fetch(FetchDescriptor<DensosoSchemaV2.MealRecord>()).first
        )
        XCTAssertEqual(restoredMeal.id, seed.mealID)
        XCTAssertEqual(restoredMeal.totalCaloriesKcal, seed.mealCalories)
        let restoredWorkout = try XCTUnwrap(
            restoredContext!.fetch(FetchDescriptor<DensosoSchemaV2.WorkoutRecord>()).first
        )
        XCTAssertEqual(restoredWorkout.id, seed.workoutID)
        XCTAssertEqual(restoredWorkout.estimatedCaloriesBurned, seed.workoutCalories)
        let restoredCursor = try XCTUnwrap(
            restoredContext!.fetch(FetchDescriptor<DensosoSchemaV2.HealthKitImportCursor>()).first
        )
        XCTAssertEqual(restoredCursor.stream, "workouts")
        XCTAssertEqual(restoredCursor.anchorData, seed.cursorBytes.map { Data($0) })
        let restoredOutboxEntry = try XCTUnwrap(
            restoredContext!.fetch(FetchDescriptor<DensosoSchemaV2.HealthSyncOutboxEntry>()).first
        )
        XCTAssertEqual(restoredOutboxEntry.recordID, seed.mealID)
        restoredContext = nil
        restoredContainer = nil

        try assertRecoveryWritesRejected(by: bootstrap)
        try await assertConfirmationWritesRejected(by: bootstrap)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: sourceDirectory.appendingPathComponent("DensosoRecovery.store").path
            )
        )
        try attachJSONReport(
            named: "gate02-recovery-report.json",
            values: [
                "outcome": "read-only-recovery",
                "diagnosticID": bootstrap.state.diagnosticID ?? "missing",
                "backupFileCount": String(manifest.files.count),
                "originalRestored": "true",
            ]
        )
    }

    func testCorruptBackupIsRejectedBeforeOriginalStoreIsReplaced() throws {
        let location = try TemporaryStoreLocation()
        defer { location.remove() }

        // This test targets the backup manager's file boundary. Other tests cover
        // real SwiftData migrations; synthetic store-family files avoid racing a
        // live SQLite/WAL checkpoint during a byte-for-byte preservation check.
        let originalFiles = [
            location.storeURL.lastPathComponent: Data("original-store".utf8),
            "\(location.storeURL.lastPathComponent)-wal": Data("original-wal".utf8),
            "\(location.storeURL.lastPathComponent)-shm": Data("original-shm".utf8),
        ]
        for (name, data) in originalFiles {
            try data.write(to: location.directoryURL.appendingPathComponent(name), options: .atomic)
        }
        let originalStoreFamily = try storeFamilySnapshot(at: location.storeURL)
        let manifest = try XCTUnwrap(
            MigrationBackupManager.createBackupIfPresent(storeURL: location.storeURL)
        )
        try Data("corrupt".utf8).write(to: manifest.backupStoreURL, options: .atomic)

        XCTAssertThrowsError(try MigrationBackupManager.restore(manifest: manifest)) { error in
            XCTAssertEqual(error as? MigrationBackupError, .byteCountMismatch(location.storeURL.lastPathComponent))
        }
        XCTAssertEqual(try storeFamilySnapshot(at: location.storeURL), originalStoreFamily)
    }

    func testBackupFailurePreventsMigrationFromStarting() async throws {
        let seed = try Gate02FixtureLoader.load("v2-seed", as: Gate02Seed.self)
        let location = try TemporaryStoreLocation()
        defer { location.remove() }
        try createV2Store(seed: seed, at: location.storeURL)
        let sourceBefore = try storeFamilySnapshot(at: location.storeURL)

        let bootstrap = PersistenceBootstrap.make(
            storeURL: location.storeURL,
            migrationPlan: Gate02FaultingMigrationPlan.self,
            backupProvider: { _ in throw MigrationBackupError.missingPrimaryStore }
        )

        XCTAssertFalse(bootstrap.state.allowsWrites)
        XCTAssertNil(bootstrap.backupManifest)
        if case .diagnosticOnly = bootstrap.state {
            // Expected: no verified backup means no migration attempt is permitted.
        } else {
            XCTFail("Backup failure must enter diagnostic-only mode")
        }
        XCTAssertEqual(try storeFamilySnapshot(at: location.storeURL), sourceBefore)
        try assertRecoveryWritesRejected(by: bootstrap)
        try await assertConfirmationWritesRejected(by: bootstrap)
        var untouchedContainer: ModelContainer? = try makeContainer(
            version: DensosoSchemaV2.self,
            url: location.storeURL
        )
        var untouchedContext: ModelContext? = ModelContext(untouchedContainer!)
        XCTAssertEqual(
            try untouchedContext!
                .fetch(FetchDescriptor<DensosoSchemaV2.MealRecord>())
                .first?.totalCaloriesKcal,
            seed.mealCalories
        )
        untouchedContext = nil
        untouchedContainer = nil
    }

    func testMetadataInspectorIdentifiesV1AndV2WithoutChangingStoreFamily() throws {
        let v1Seed = try Gate02FixtureLoader.load("v1-seed", as: Gate02Seed.self)
        let v1Location = try TemporaryStoreLocation()
        defer { v1Location.remove() }
        try createV1Store(seed: v1Seed, at: v1Location.storeURL)
        let v1Before = try storeFamilySnapshot(at: v1Location.storeURL)
        XCTAssertEqual(PersistentStoreVersionInspector.version(at: v1Location.storeURL), "1.0.0")
        XCTAssertEqual(try storeFamilySnapshot(at: v1Location.storeURL), v1Before)

        let v2Seed = try Gate02FixtureLoader.load("v2-seed", as: Gate02Seed.self)
        let v2Location = try TemporaryStoreLocation()
        defer { v2Location.remove() }
        try createV2Store(seed: v2Seed, at: v2Location.storeURL)
        let v2Before = try storeFamilySnapshot(at: v2Location.storeURL)
        XCTAssertEqual(PersistentStoreVersionInspector.version(at: v2Location.storeURL), "2.0.0")
        XCTAssertEqual(try storeFamilySnapshot(at: v2Location.storeURL), v2Before)
    }

    func testMetadataInspectorFailsClosedWhenModelHashesAreMissing() {
        XCTAssertThrowsError(
            try PersistentStoreVersionInspector.modelVersionHashes(from: [:])
        ) { error in
            XCTAssertEqual(
                error as? PersistentStoreVersionInspectorError,
                .missingModelVersionHashes
            )
        }
    }

    private func createV1Store(seed: Gate02Seed, at url: URL) throws {
        var container: ModelContainer? = try makeContainer(version: DensosoSchemaV1.self, url: url)
        var context: ModelContext? = ModelContext(container!)
        let date = Date(timeIntervalSince1970: seed.recordedAt)
        let meal = DensosoSchemaV1.MealRecord(
            date: date,
            totalCaloriesKcal: seed.mealCalories,
            algorithmVersion: seed.mealAlgorithmVersion
        )
        meal.id = seed.mealID
        meal.dishes = [DensosoSchemaV1.DishEntry(dishName: "fixture dish", estimatedCaloriesKcal: seed.mealCalories)]
        let workout = DensosoSchemaV1.WorkoutRecord(
            date: date,
            type: "walking",
            durationMinutes: 30,
            estimatedCaloriesBurned: seed.workoutCalories
        )
        workout.id = seed.workoutID
        context!.insert(DensosoSchemaV1.UserProfile(name: "fixture"))
        context!.insert(meal)
        context!.insert(workout)
        context!.insert(DensosoSchemaV1.DailyMetrics(date: date))
        context!.insert(DensosoSchemaV1.WeeklyReport(weekStartDate: date, weekEndDate: date))
        context!.insert(DensosoSchemaV1.ScheduleEvent(date: date, title: "fixture"))
        context!.insert(DensosoSchemaV1.HealthSyncOutboxEntry(operation: "upsertMeal", recordID: seed.mealID))
        try context!.save()
        context = nil
        container = nil
    }

    private func createV2Store(
        seed: Gate02Seed,
        at url: URL,
        mealNutrients: (proteinG: Double, fatG: Double, carbsG: Double) = (0, 0, 0),
        dishNutrients: (proteinG: Double, fatG: Double, carbsG: Double) = (0, 0, 0),
        mealCalories: Int? = nil,
        dishCalories: Int? = nil
    ) throws {
        var container: ModelContainer? = try makeContainer(version: DensosoSchemaV2.self, url: url)
        var context: ModelContext? = ModelContext(container!)
        let date = Date(timeIntervalSince1970: seed.recordedAt)
        let meal = DensosoSchemaV2.MealRecord(
            date: date,
            totalCaloriesKcal: mealCalories ?? seed.mealCalories,
            proteinG: mealNutrients.proteinG,
            fatG: mealNutrients.fatG,
            carbsG: mealNutrients.carbsG,
            algorithmVersion: seed.mealAlgorithmVersion
        )
        meal.id = seed.mealID
        meal.dishes = [
            DensosoSchemaV2.DishEntry(
                dishName: "fixture dish",
                estimatedCaloriesKcal: dishCalories ?? seed.mealCalories,
                estimatedProteinG: dishNutrients.proteinG,
                estimatedFatG: dishNutrients.fatG,
                estimatedCarbsG: dishNutrients.carbsG
            ),
        ]
        let workout = DensosoSchemaV2.WorkoutRecord(
            date: date,
            type: "running",
            durationMinutes: 30,
            estimatedCaloriesBurned: seed.workoutCalories,
            healthKitUUID: UUID(),
            workoutOrigin: "externalHealthKit",
            energySource: "measured"
        )
        workout.id = seed.workoutID
        context!.insert(DensosoSchemaV2.UserProfile(name: "fixture"))
        context!.insert(meal)
        context!.insert(workout)
        context!.insert(DensosoSchemaV2.HealthSyncOutboxEntry(operation: "upsertMeal", recordID: seed.mealID))
        context!.insert(
            DensosoSchemaV2.HealthKitImportCursor(
                stream: "workouts",
                anchorData: seed.cursorBytes.map { Data($0) }
            )
        )
        try context!.save()
        context = nil
        container = nil
    }

    private func makeContainer<Version: VersionedSchema>(
        version: Version.Type,
        url: URL
    ) throws -> ModelContainer {
        let schema = Schema(versionedSchema: version)
        let configuration = ModelConfiguration("Densoso", schema: schema, url: url)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    private func openV4Store(at url: URL) throws -> ModelContainer {
        let schema = Schema(versionedSchema: DensosoSchemaV4.self)
        let configuration = ModelConfiguration("Densoso", schema: schema, url: url)
        return try ModelContainer(
            for: schema,
            migrationPlan: DensosoMigrationTestPlanV4.self,
            configurations: [configuration]
        )
    }

    private func openV6Store(at url: URL) throws -> ModelContainer {
        let schema = Schema(versionedSchema: DensosoSchemaV6.self)
        let configuration = ModelConfiguration("Densoso", schema: schema, url: url)
        return try ModelContainer(
            for: schema,
            migrationPlan: DensosoMigrationTestPlanV6.self,
            configurations: [configuration]
        )
    }

    private func openV7Store(at url: URL) throws -> ModelContainer {
        let schema = Schema(versionedSchema: DensosoSchemaV7.self)
        let configuration = ModelConfiguration("Densoso", schema: schema, url: url)
        return try ModelContainer(
            for: schema,
            migrationPlan: DensosoMigrationTestPlanV7.self,
            configurations: [configuration]
        )
    }

    private func openCurrentStore(at url: URL) throws -> ModelContainer {
        let schema = Schema(versionedSchema: DensosoSchemaV12.self)
        let configuration = ModelConfiguration("Densoso", schema: schema, url: url)
        return try ModelContainer(
            for: schema,
            migrationPlan: DensosoMigrationPlan.self,
            configurations: [configuration]
        )
    }

    func testV11DiskStoreMigratesToV12WithDishPriorTableAndPreservedPolicy() throws {
        let location = try TemporaryStoreLocation()
        defer { location.remove() }
        let date = Date(timeIntervalSince1970: 1_750_000_000)
        let sourceSchema = Schema(versionedSchema: DensosoSchemaV11.self)
        let sourceConfiguration = ModelConfiguration("Densoso", schema: sourceSchema, url: location.storeURL)
        var sourceContainer: ModelContainer? = try ModelContainer(
            for: sourceSchema,
            configurations: [sourceConfiguration]
        )
        var sourceContext: ModelContext? = ModelContext(sourceContainer!)
        sourceContext?.insert(CloudHealthContextPolicyRecord(
            policyKey: "cloud-health-context-policy|deepSeek",
            schemaVersion: 1,
            policyID: UUID(),
            providerRaw: ProviderID.deepSeek.rawValue,
            revision: 2,
            stateRaw: CloudHealthPolicyState.active.rawValue,
            allowedClassesRaw: ProviderDataClass.healthText.rawValue,
            createdAt: date,
            updatedAt: date,
            confirmedAt: date,
            policyHash: "v11-policy-hash",
            changeSourceRaw: CloudHealthPolicyChangeSource.settings.rawValue
        ))
        try sourceContext?.save()
        sourceContext = nil
        sourceContainer = nil
        XCTAssertEqual(PersistentStoreVersionInspector.version(at: location.storeURL), "11.0.0")

        let migrated = try openCurrentStore(at: location.storeURL)
        let context = ModelContext(migrated)
        let policy = try XCTUnwrap(context.fetch(FetchDescriptor<CloudHealthContextPolicyRecord>()).first)
        XCTAssertEqual(policy.policyHash, "v11-policy-hash")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PersonalMealDishPriorRecord>()), 0)
        XCTAssertEqual(PersistentStoreVersionInspector.version(at: location.storeURL), "12.0.0")
    }

    func testV9StoreMigratesToV10WithPreMigrationBackupAndRetrySafeOpen() throws {
        let location = try TemporaryStoreLocation()
        defer { location.remove() }
        let sourceSchema = Schema(versionedSchema: DensosoSchemaV9.self)
        let sourceConfiguration = ModelConfiguration("Densoso", schema: sourceSchema, url: location.storeURL)
        var sourceContainer: ModelContainer? = try ModelContainer(
            for: sourceSchema,
            configurations: [sourceConfiguration]
        )
        var sourceContext: ModelContext? = ModelContext(sourceContainer!)
        sourceContext?.insert(MealRecord(
            date: Date(timeIntervalSince1970: 1_750_000_000),
            totalCaloriesKcal: 420
        ))
        try sourceContext?.save()
        sourceContext = nil
        sourceContainer = nil

        let migrated = PersistenceBootstrap.make(storeURL: location.storeURL)
        XCTAssertEqual(migrated.state, .writable)
        XCTAssertNotNil(migrated.backupManifest)
        let context = ModelContext(migrated.container)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<MealRecord>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PersonalMealPortionPriorRecord>()), 0)

        let reopened = PersistenceBootstrap.make(storeURL: location.storeURL)
        XCTAssertEqual(reopened.state, .writable)
        let reopenedContext = ModelContext(reopened.container)
        XCTAssertEqual(try reopenedContext.fetchCount(FetchDescriptor<MealRecord>()), 1)
        XCTAssertEqual(try reopenedContext.fetchCount(FetchDescriptor<PersonalMealPortionPriorRecord>()), 0)
    }

    private static func dayKey(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    private func assertRecoveryWritesRejected(by bootstrap: PersistenceBootstrap) throws {
        XCTAssertThrowsError(
            try PersistenceWriteGate(state: bootstrap.state).requireWritable()
        ) { error in
            XCTAssertEqual(
                error as? PersistenceWriteError,
                .recoveryReadOnly(diagnosticID: bootstrap.state.diagnosticID ?? "unknown")
            )
        }
    }

    private func assertConfirmationWritesRejected(
        by bootstrap: PersistenceBootstrap
    ) async throws {
        let repository = SwiftDataConfirmationRepository(modelContainer: bootstrap.container)
        let coordinator = ConfirmationCoordinator(
            repository: repository,
            writeGate: PersistenceWriteGate(state: bootstrap.state)
        )
        do {
            _ = try await coordinator.stage(
                payload: .weight(
                    WeightDraft(
                        measuredAt: Date(timeIntervalSince1970: 1_700_000_000),
                        kilograms: 62.5
                    )
                ),
                clientRequestID: UUID()
            )
            XCTFail("Recovery mode must reject confirmation staging")
        } catch {
            XCTAssertEqual(
                error as? ConfirmationError,
                .persistenceReadOnly(diagnosticID: bootstrap.state.diagnosticID ?? "unknown")
            )
        }
    }

    private func storeFamilySnapshot(at storeURL: URL) throws -> [String: Data] {
        let urls = [
            storeURL,
            URL(fileURLWithPath: storeURL.path + "-wal"),
            URL(fileURLWithPath: storeURL.path + "-shm"),
        ].filter { FileManager.default.fileExists(atPath: $0.path) }
        return try Dictionary(uniqueKeysWithValues: urls.map { url in
            (url.lastPathComponent, try Data(contentsOf: url, options: .mappedIfSafe))
        })
    }

    private func attachJSONReport(named name: String, values: [String: String]) throws {
        let data = try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

enum DensosoMigrationTestPlanV4: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        Array(DensosoMigrationPlan.schemas.prefix(6))
    }

    static var stages: [MigrationStage] {
        Array(DensosoMigrationPlan.stages.prefix(5))
    }
}

enum DensosoMigrationTestPlanV5: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        Array(DensosoMigrationPlan.schemas.prefix(7))
    }

    static var stages: [MigrationStage] {
        Array(DensosoMigrationPlan.stages.prefix(6))
    }
}

enum DensosoMigrationTestPlanV6: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        Array(DensosoMigrationPlan.schemas.prefix(8))
    }

    static var stages: [MigrationStage] {
        Array(DensosoMigrationPlan.stages.prefix(7))
    }
}

enum DensosoMigrationTestPlanV7: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        Array(DensosoMigrationPlan.schemas.prefix(9))
    }

    static var stages: [MigrationStage] {
        Array(DensosoMigrationPlan.stages.prefix(8))
    }
}

private struct TemporaryStoreLocation {
    let directoryURL: URL
    let storeURL: URL

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("densoso-gate02-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        storeURL = directoryURL.appendingPathComponent("default.store")
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

private struct MigrationWeightEntry: Codable {
    let date: Date
    let kg: Double
}

private struct LegacyDailyHealthSnapshot: Encodable {
    let dayStart: Date
    let timezoneIdentifier: String
    let energyIntakeKcal: EstimateRange? = nil
    let activeEnergyKcal: Double? = nil
    let restingEnergyKcal: Double? = nil
    let stepCount: Double? = nil
    let exerciseMinutes: Double? = nil
    let weightKilograms: Double?
    let healthKitSamples: [HealthSampleSnapshot]?
    let healthReadStates: [String: HealthReadState]? = nil
    let algorithmVersion: String
}

private enum Gate02Fault: Error {
    case injected
}

private enum Gate02FaultingMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [
            DensosoSchemaV2.self, DensosoSchemaV3.self, DensosoSchemaV4.self,
            DensosoSchemaV5.self, DensosoSchemaV6.self, DensosoSchemaV7.self,
        ]
    }

    static var stages: [MigrationStage] {
        [
            .custom(
                fromVersion: DensosoSchemaV2.self,
                toVersion: DensosoSchemaV3.self,
                willMigrate: { context in
                    let meals = try context.fetch(FetchDescriptor<DensosoSchemaV2.MealRecord>())
                    meals.first?.totalCaloriesKcal += 1
                    try context.save()
                    throw Gate02Fault.injected
                },
                didMigrate: nil
            ),
            .lightweight(fromVersion: DensosoSchemaV3.self, toVersion: DensosoSchemaV4.self),
            .custom(
                fromVersion: DensosoSchemaV4.self,
                toVersion: DensosoSchemaV5.self,
                willMigrate: { context in
                    let currentProjectionVersion = AlgorithmVersions.dailyMetricsProjection
                    let metrics = try context.fetch(FetchDescriptor<DensosoSchemaV4.DailyMetrics>())
                    for metric in metrics
                    where metric.projectionVersion != currentProjectionVersion
                        || metric.sourceFingerprint.isEmpty {
                        metric.requiresRecompute = true
                    }
                    try context.save()
                },
                didMigrate: nil
            ),
            .custom(
                fromVersion: DensosoSchemaV5.self,
                toVersion: DensosoSchemaV6.self,
                willMigrate: nil,
                didMigrate: nil
            ),
            .lightweight(fromVersion: DensosoSchemaV6.self, toVersion: DensosoSchemaV7.self),
        ]
    }
}
