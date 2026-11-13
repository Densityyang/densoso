import SwiftData
import XCTest
@testable import Densoso
import DensosoDomain

@MainActor
final class HealthRepositoryWorkoutTransactionTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        let schema = Schema(versionedSchema: DensosoSchemaV14.self)
        container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        context = ModelContext(container)
        context.insert(UserProfile())
        try context.save()
    }

    func testImportedWorkoutAndAnchorAndReadStateCommitAtomically() async throws {
        let calendar = Calendar.current
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let day = calendar.startOfDay(for: startedAt)
        let healthKitUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000104")!
        let snapshot = try WorkoutSnapshot(
            healthKitUUID: healthKitUUID,
            startedAt: startedAt,
            duration: 2_400,
            activityType: "swimming",
            energyInput: .init(measuredKilocalories: 285),
            origin: .watchHealthKit,
            dataQuality: .complete
        )
        let nextAnchor = Data([0x31, 0x41, 0x59])
        let repository = HealthRepository(modelContext: ModelContext(container))

        try await repository.applyImportedWorkouts(
            [snapshot],
            deletedHealthKitUUIDs: [],
            nextAnchorData: nextAnchor,
            readStateUpdates: [day.addingTimeInterval(43_200): .available]
        )

        let verificationContext = ModelContext(container)
        let workout = try XCTUnwrap(
            verificationContext.fetch(FetchDescriptor<WorkoutRecord>())
                .first { $0.healthKitUUID == healthKitUUID }
        )
        XCTAssertEqual(workout.date, startedAt)
        XCTAssertEqual(workout.type, "swimming")
        XCTAssertEqual(workout.durationMinutes, 40)
        XCTAssertEqual(workout.estimatedCaloriesBurned, 285)

        let cursor = try XCTUnwrap(
            verificationContext.fetch(FetchDescriptor<HealthKitImportCursor>())
                .first { $0.stream == "workouts" }
        )
        XCTAssertEqual(cursor.anchorData, nextAnchor)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let snapshots = try verificationContext.fetch(FetchDescriptor<DailyHealthSnapshotRecord>())
            .map { try decoder.decode(DailyHealthSnapshot.self, from: $0.payloadData) }
        let daySnapshot = try XCTUnwrap(snapshots.first { calendar.isDate($0.dayStart, inSameDayAs: day) })
        XCTAssertEqual(daySnapshot.healthReadStates?[HealthMetricID.workout.rawValue], .available)
    }

    func testWorkoutReadStateAndCursorRollBackTogetherWhenSaveFails() async throws {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
        let existingUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
        let deletedUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000102")!
        let insertedUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000103")!
        let existingDate = day.addingTimeInterval(3_600)
        let deletedDate = day.addingTimeInterval(2 * 86_400 + 3_600)
        let insertedDate = day.addingTimeInterval(4 * 86_400 + 3_600)

        context.insert(WorkoutRecord(
            date: existingDate,
            type: "baseline-running",
            durationMinutes: 20,
            estimatedCaloriesBurned: 180,
            healthKitUUID: existingUUID,
            workoutOrigin: WorkoutOrigin.externalHealthKit.rawValue
        ))
        context.insert(WorkoutRecord(
            date: deletedDate,
            type: "baseline-cycling",
            durationMinutes: 35,
            estimatedCaloriesBurned: 260,
            healthKitUUID: deletedUUID,
            workoutOrigin: WorkoutOrigin.externalHealthKit.rawValue
        ))
        try context.save()

        let seedRepository = HealthRepository(modelContext: context)
        try await seedRepository.setHealthReadState(
            .dataUnavailableOrReadScopeUnknown,
            metric: .workout,
            days: [day]
        )
        try await seedRepository.applyImportedWorkouts(
            [],
            deletedHealthKitUUIDs: [],
            nextAnchorData: Data([0x11])
        )

        let updatedSnapshot = try WorkoutSnapshot(
            healthKitUUID: existingUUID,
            startedAt: day.addingTimeInterval(7_200),
            duration: 2_700,
            activityType: "updated-running",
            energyInput: .init(measuredKilocalories: 330),
            origin: .watchHealthKit,
            dataQuality: .complete
        )
        let insertedSnapshot = try WorkoutSnapshot(
            healthKitUUID: insertedUUID,
            startedAt: insertedDate,
            duration: 1_500,
            activityType: "new-rowing",
            energyInput: .init(measuredKilocalories: 210),
            origin: .watchHealthKit,
            dataQuality: .complete
        )
        let repository = HealthRepository(
            modelContext: ModelContext(container),
            willSave: { throw InjectedSaveFailure.failed }
        )

        do {
            try await repository.applyImportedWorkouts(
                [updatedSnapshot, insertedSnapshot],
                deletedHealthKitUUIDs: [deletedUUID],
                nextAnchorData: Data([0x22]),
                readStateUpdates: [day.addingTimeInterval(43_200): .available]
            )
            XCTFail("Expected the injected source transaction failure")
        } catch {
            XCTAssertEqual(error as? InjectedSaveFailure, .failed)
        }

        let verificationContext = ModelContext(container)
        let workouts = try verificationContext.fetch(FetchDescriptor<WorkoutRecord>())
        let existing = try XCTUnwrap(workouts.first { $0.healthKitUUID == existingUUID })
        XCTAssertEqual(existing.date, existingDate)
        XCTAssertEqual(existing.type, "baseline-running")
        XCTAssertEqual(existing.estimatedCaloriesBurned, 180)
        XCTAssertNotNil(workouts.first { $0.healthKitUUID == deletedUUID })
        XCTAssertNil(workouts.first { $0.healthKitUUID == insertedUUID })

        let cursor = try XCTUnwrap(
            verificationContext.fetch(FetchDescriptor<HealthKitImportCursor>())
                .first { $0.stream == "workouts" }
        )
        XCTAssertEqual(cursor.anchorData, Data([0x11]))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let snapshots = try verificationContext.fetch(FetchDescriptor<DailyHealthSnapshotRecord>())
            .map { try decoder.decode(DailyHealthSnapshot.self, from: $0.payloadData) }
        let daySnapshot = try XCTUnwrap(snapshots.first { calendar.isDate($0.dayStart, inSameDayAs: day) })
        XCTAssertEqual(
            daySnapshot.healthReadStates?[HealthMetricID.workout.rawValue],
            .dataUnavailableOrReadScopeUnknown
        )
    }
}

private enum InjectedSaveFailure: Error, Equatable {
    case failed
}
