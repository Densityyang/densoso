import XCTest
@testable import DensosoDomain

final class HealthIntelligenceTrainingLoadTests: XCTestCase {
    func testUnknownImportedEffortDoesNotCountAsModerate() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let asOf = calendar.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 12))!
        let workout = TrainingWorkoutInput(
            startedAt: asOf,
            durationMinutes: 60,
            effortScore: nil,
            intensity: "unknown"
        )

        let load = HealthIntelligenceEngine(calendar: calendar).trainingLoad(
            workouts: [workout],
            asOf: asOf
        )

        XCTAssertEqual(load.recentSevenDayLoad, 0)
        XCTAssertEqual(load.estimatedWorkoutCount, 0)
        XCTAssertEqual(load.unavailableEffortCount, 1)
        XCTAssertEqual(load.band, .unavailable)
    }
}
