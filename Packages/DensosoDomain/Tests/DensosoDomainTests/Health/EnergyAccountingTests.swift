import XCTest
@testable import DensosoDomain

final class EnergyAccountingTests: XCTestCase {
    func testObservedExpenditureUsesBasalPlusActiveExactlyOnce() throws {
        let result = try XCTUnwrap(
            EnergyAccounting.expenditure(
                observedBasalEnergyKcal: 1_420,
                observedActiveEnergyKcal: 510,
                profile: nil,
                effectiveWeightKg: nil
            )
        )

        XCTAssertEqual(result.low, 1_930)
        XCTAssertEqual(result.likely, 1_930)
        XCTAssertEqual(result.high, 1_930)
        XCTAssertEqual(result.source, .observed)
        XCTAssertEqual(result.confidence, .high)
    }

    func testMissingHealthKitComponentUsesExplicitProfileEstimate() throws {
        let profile = effectiveProfile()

        let result = try XCTUnwrap(
            EnergyAccounting.expenditure(
                observedBasalEnergyKcal: 1_420,
                observedActiveEnergyKcal: nil,
                profile: profile,
                effectiveWeightKg: 60
            )
        )

        XCTAssertEqual(result.source, .estimated)
        XCTAssertEqual(result.confidence, .low)
        XCTAssertLessThan(result.low, result.likely)
        XCTAssertGreaterThan(result.high, result.likely)
        XCTAssertEqual(result.low, result.likely * (1 - EnergyAccounting.fallbackRelativeUncertainty), accuracy: 0.001)
        XCTAssertEqual(result.high, result.likely * (1 + EnergyAccounting.fallbackRelativeUncertainty), accuracy: 0.001)
    }

    func testMissingProfileOrEffectiveWeightDoesNotInventExpenditure() {
        XCTAssertNil(
            EnergyAccounting.expenditure(
                observedBasalEnergyKcal: nil,
                observedActiveEnergyKcal: nil,
                profile: nil,
                effectiveWeightKg: 60
            )
        )
        XCTAssertNil(
            EnergyAccounting.expenditure(
                observedBasalEnergyKcal: nil,
                observedActiveEnergyKcal: nil,
                profile: effectiveProfile(),
                effectiveWeightKg: nil
            )
        )
    }

    func testUnsupportedSexDoesNotProduceFormulaBasedBMR() {
        XCTAssertNil(
            EnergyAccounting.basalMetabolicRate(
                sex: .unspecified,
                weightKg: 60,
                heightCm: 165,
                age: 35
            )
        )
    }

    private func effectiveProfile() -> EffectiveProfile {
        let dateOfBirth = date(1990, 6, 15)
        let effectiveAt = date(2025, 6, 15)
        return EffectiveProfile(
            profileKey: "primary",
            sourceRevisionID: UUID(),
            sourceEffectiveFrom: date(2025, 1, 1),
            effectiveAt: effectiveAt,
            dateOfBirth: dateOfBirth,
            biologicalSex: .female,
            heightCm: 165,
            weightKg: 60,
            activityLevel: .moderate
        )
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }
}
