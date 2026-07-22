import XCTest
@testable import DensosoWorkoutDomain

final class WorkoutSnapshotTests: XCTestCase {
    func testSnapshotKeepsProvenanceAndUsesMeasuredEnergy() throws {
        let workoutID = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
        let logicalID = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
        let snapshot = try WorkoutSnapshot(
            healthKitUUID: workoutID,
            logicalSessionID: logicalID,
            startedAt: .distantPast,
            duration: 1_800,
            activityType: "running",
            energyInput: .init(measuredKilocalories: 310, userEnteredKilocalories: 250, metEstimatedKilocalories: 270),
            origin: .watchHealthKit,
            sourceBundleIdentifier: "com.densoso.densoso",
            sourceVersion: "1.0",
            sourceRevision: "17",
            deviceName: "Apple Watch",
            deviceModel: "Watch7,1",
            dataQuality: .complete
        )

        XCTAssertEqual(snapshot.healthKitUUID, workoutID)
        XCTAssertEqual(snapshot.logicalSessionID, logicalID)
        XCTAssertEqual(snapshot.resolvedEnergy, .init(kilocalories: 310, source: .measured))
        XCTAssertEqual(snapshot.routeStatus, .pending)
    }

    func testSnapshotRejectsInvalidDuration() {
        XCTAssertThrowsError(
            try WorkoutSnapshot(
                healthKitUUID: UUID(),
                startedAt: Date(),
                duration: -.infinity,
                activityType: "other",
                energyInput: .init(),
                origin: .externalHealthKit,
                dataQuality: .unavailable
            )
        )
    }
}
