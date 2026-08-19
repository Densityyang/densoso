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
        XCTAssertEqual(cursor.anchorData, seed.cursorBytes.map(Data.init))
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

    func testFaultingMigrationRestoresOriginalAndEntersReadOnlyRecovery() throws {
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
        for entry in manifest.files {
            XCTAssertEqual(
                try Data(contentsOf: backupDirectory.appendingPathComponent(entry.name)),
                try Data(contentsOf: sourceDirectory.appendingPathComponent(entry.name))
            )
        }
        let restoredContainer = try makeContainer(version: DensosoSchemaV2.self, url: location.storeURL)
        let restoredContext = ModelContext(restoredContainer)
        XCTAssertEqual(
            try restoredContext.fetch(FetchDescriptor<DensosoSchemaV2.MealRecord>()).first?.totalCaloriesKcal,
            seed.mealCalories
        )

        let recoveryContext = ModelContext(bootstrap.container)
        recoveryContext.insert(UserProfile(name: "must-not-save"))
        XCTAssertThrowsError(try recoveryContext.save())
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

    func testBackupFailurePreventsMigrationFromStarting() throws {
        let seed = try Gate02FixtureLoader.load("v2-seed", as: Gate02Seed.self)
        let location = try TemporaryStoreLocation()
        defer { location.remove() }
        try createV2Store(seed: seed, at: location.storeURL)

        let bootstrap = PersistenceBootstrap.make(
            storeURL: location.storeURL,
            migrationPlan: Gate02FaultingMigrationPlan.self,
            backupProvider: { _ in throw MigrationBackupError.missingPrimaryStore }
        )

        XCTAssertFalse(bootstrap.state.allowsWrites)
        XCTAssertNil(bootstrap.backupManifest)
        let untouchedContainer = try makeContainer(version: DensosoSchemaV2.self, url: location.storeURL)
        XCTAssertEqual(
            try ModelContext(untouchedContainer)
                .fetch(FetchDescriptor<DensosoSchemaV2.MealRecord>())
                .first?.totalCaloriesKcal,
            seed.mealCalories
        )
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
                anchorData: seed.cursorBytes.map(Data.init)
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
