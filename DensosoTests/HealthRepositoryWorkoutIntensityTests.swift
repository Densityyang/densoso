import SwiftData
import XCTest
@testable import Densoso
import DensosoDomain

@MainActor
final class HealthRepositoryWorkoutIntensityTests: XCTestCase {
    func testImportedWorkoutWithoutEffortDoesNotInheritManualModerateDefault() async throws {
        let schema = Schema(versionedSchema: DensosoSchemaV14.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = try WorkoutSnapshot(
            healthKitUUID: UUID(uuidString: "00000000-0000-0000-0000-000000000821")!,
            startedAt: startedAt,
            duration: 3_600,
            activityType: "running",
            energyInput: .init(measuredKilocalories: nil),
            origin: .externalHealthKit,
            dataQuality: .partial
        )
        let repository = HealthRepository(modelContext: ModelContext(container))

        try await repository.applyImportedWorkouts(
            [snapshot],
            deletedHealthKitUUIDs: [],
            nextAnchorData: Data([0x82])
        )

        let verificationContext = ModelContext(container)
        let imported = try XCTUnwrap(
            verificationContext.fetch(FetchDescriptor<WorkoutRecord>())
                .first { $0.healthKitUUID == snapshot.healthKitUUID }
        )
        XCTAssertEqual(imported.intensity, "unknown")

        let manualWorkout = WorkoutRecord(date: startedAt, type: "running")
        XCTAssertEqual(manualWorkout.intensity, "moderate")
    }
}
