import DensosoDomain
import SwiftData
import XCTest
@testable import Densoso

@MainActor
final class DensosoMigrationTests: XCTestCase {
    func testV1DiskFixtureMigratesToV3WithoutRecalculation() throws {
        let seed = try Gate02FixtureLoader.load("v1-seed", as: Gate02Seed.self)
        let expected = try Gate02FixtureLoader.load(
            "expected-migration",
            as: Gate02ExpectedMigration.self
        )
        let location = try TemporaryStoreLocation()
        defer { location.remove() }
        try createV1Store(seed: seed, at: location.storeURL)

        let container = try openV3Store(at: location.storeURL)
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
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DailyMetrics>()), 1)
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

    func testV2DiskFixtureMigratesToV3AndPreservesCursorAndOutbox() throws {
        let seed = try Gate02FixtureLoader.load("v2-seed", as: Gate02Seed.self)
        let expected = try Gate02FixtureLoader.load(
            "expected-migration",
            as: Gate02ExpectedMigration.self
        )
        let location = try TemporaryStoreLocation()
        defer { location.remove() }
        try createV2Store(seed: seed, at: location.storeURL)

        var container: ModelContainer? = try openV3Store(at: location.storeURL)
        var context: ModelContext? = ModelContext(container!)
        let meal = try XCTUnwrap(context!.fetch(FetchDescriptor<MealRecord>()).first)
        let dish = try XCTUnwrap(context!.fetch(FetchDescriptor<DishEntry>()).first)
        let workout = try XCTUnwrap(context!.fetch(FetchDescriptor<WorkoutRecord>()).first)
        let cursor = try XCTUnwrap(context!.fetch(FetchDescriptor<HealthKitImportCursor>()).first)
        let outbox = try XCTUnwrap(context!.fetch(FetchDescriptor<HealthSyncOutboxEntry>()).first)

        XCTAssertEqual(meal.id, seed.mealID)
        XCTAssertEqual(meal.algorithmVersion, seed.mealAlgorithmVersion)
        XCTAssertEqual(meal.energyLikelyKcal, Double(seed.mealCalories))
        XCTAssertEqual(meal.dishes.count, 1)
        XCTAssertEqual(dish.mealRecord?.id, meal.id)
        XCTAssertEqual(dish.estimatedCaloriesKcal, seed.mealCalories)
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
        container = try openV3Store(at: location.storeURL)
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

    func testFaultingMigrationRestoresOriginalAndEntersReadOnlyRecovery() async throws {
        let seed = try Gate02FixtureLoader.load("v2-seed", as: Gate02Seed.self)
        let location = try TemporaryStoreLocation()
        defer { location.remove() }
        try createV2Store(seed: seed, at: location.storeURL)
        let sourceBefore = try storeFamilySnapshot(at: location.storeURL)

        let bootstrap = PersistenceBootstrap.make(
            storeURL: location.storeURL,
            migrationPlan: Gate02FaultingMigrationPlan.self
        )

        XCTAssertFalse(bootstrap.state.allowsWrites)
        XCTAssertNotNil(bootstrap.backupManifest)
        let manifest = try XCTUnwrap(bootstrap.backupManifest)
        let backupDirectory = manifest.backupStoreURL.deletingLastPathComponent()
        let sourceDirectory = manifest.sourceStoreURL.deletingLastPathComponent()
        XCTAssertEqual(try storeFamilySnapshot(at: location.storeURL), sourceBefore)
        XCTAssertEqual(PersistentStoreVersionInspector.version(at: location.storeURL), "2.0.0")
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
        XCTAssertEqual(
            try restoredContext!
                .fetch(FetchDescriptor<DensosoSchemaV2.MealRecord>())
                .first?.totalCaloriesKcal,
            seed.mealCalories
        )
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
        let seed = try Gate02FixtureLoader.load("v2-seed", as: Gate02Seed.self)
        let location = try TemporaryStoreLocation()
        defer { location.remove() }
        try createV2Store(seed: seed, at: location.storeURL)
        let originalStore = try Data(contentsOf: location.storeURL)
        let manifest = try XCTUnwrap(
            MigrationBackupManager.createBackupIfPresent(storeURL: location.storeURL)
        )
        try Data("corrupt".utf8).write(to: manifest.backupStoreURL, options: .atomic)

        XCTAssertThrowsError(try MigrationBackupManager.restore(manifest: manifest))
        XCTAssertEqual(try Data(contentsOf: location.storeURL), originalStore)
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

    private func createV2Store(seed: Gate02Seed, at url: URL) throws {
        var container: ModelContainer? = try makeContainer(version: DensosoSchemaV2.self, url: url)
        var context: ModelContext? = ModelContext(container!)
        let date = Date(timeIntervalSince1970: seed.recordedAt)
        let meal = DensosoSchemaV2.MealRecord(
            date: date,
            totalCaloriesKcal: seed.mealCalories,
            algorithmVersion: seed.mealAlgorithmVersion
        )
        meal.id = seed.mealID
        meal.dishes = [DensosoSchemaV2.DishEntry(dishName: "fixture dish", estimatedCaloriesKcal: seed.mealCalories)]
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

    private func openV3Store(at url: URL) throws -> ModelContainer {
        let schema = Schema(versionedSchema: DensosoSchemaV3.self)
        let configuration = ModelConfiguration("Densoso", schema: schema, url: url)
        return try ModelContainer(
            for: schema,
            migrationPlan: DensosoMigrationPlan.self,
            configurations: [configuration]
        )
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

private enum Gate02Fault: Error {
    case injected
}

private enum Gate02FaultingMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [DensosoSchemaV2.self, DensosoSchemaV3.self]
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
            )
        ]
    }
}
