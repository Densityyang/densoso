import XCTest
@testable import DensosoWorkoutDomain

final class WorkoutEnergyResolverTests: XCTestCase {
    private let resolver = WorkoutEnergyResolver()

    func testMeasuredEnergyWinsOverOtherSources() {
        let value = resolver.resolve(.init(measuredKilocalories: 340, userEnteredKilocalories: 410, metEstimatedKilocalories: 290))

        XCTAssertEqual(value, ResolvedWorkoutEnergy(kilocalories: 340, source: .measured))
    }

    func testUserEnergyWinsWhenMeasuredEnergyIsUnavailable() {
        let value = resolver.resolve(.init(userEnteredKilocalories: 220, metEstimatedKilocalories: 260))

        XCTAssertEqual(value, ResolvedWorkoutEnergy(kilocalories: 220, source: .userEntered))
    }

    func testInvalidEnergyIsNeverSelected() {
        let value = resolver.resolve(.init(measuredKilocalories: -.infinity, userEnteredKilocalories: -1, metEstimatedKilocalories: .nan))

        XCTAssertNil(value)
    }
}
