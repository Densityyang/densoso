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

        let result = EnergyAccounting.calculate(
            observedBasalEnergyKcal: 1_420,
            observedActiveEnergyKcal: nil,
            profile: profile,
            effectiveWeightKg: 60
        )
        let total = try XCTUnwrap(result.expenditure)
        let basal = try XCTUnwrap(result.basalComponent)
        let active = try XCTUnwrap(result.activeComponent)

        XCTAssertEqual(basal.source, .observed)
        XCTAssertEqual(basal.likely, 1_420)
        XCTAssertEqual(active.source, .estimated)
        XCTAssertEqual(total.source, .estimated)
        XCTAssertEqual(total.confidence, .low)
        XCTAssertEqual(total.low, basal.low + active.low, accuracy: 0.001)
        XCTAssertEqual(total.likely, basal.likely + active.likely, accuracy: 0.001)
        XCTAssertEqual(total.high, basal.high + active.high, accuracy: 0.001)
    }

    func testObservedActiveEnergyIsAddedToEstimatedBasalOnlyOnce() throws {
        let result = EnergyAccounting.calculate(
            observedBasalEnergyKcal: nil,
            observedActiveEnergyKcal: 510,
            profile: effectiveProfile(),
            effectiveWeightKg: 60
        )

        let total = try XCTUnwrap(result.expenditure)
        let basal = try XCTUnwrap(result.basalComponent)
        let active = try XCTUnwrap(result.activeComponent)
        XCTAssertEqual(basal.source, .estimated)
        XCTAssertEqual(active.source, .observed)
        XCTAssertEqual(active.likely, 510)
        XCTAssertEqual(total.likely, basal.likely + 510, accuracy: 0.001)
        XCTAssertEqual(total.source, .estimated)
    }

    func testObservedBasalWithoutEstimateableActiveRemainsPartial() throws {
        let profile = EffectiveProfile(
            profileKey: "primary",
            sourceRevisionID: UUID(),
            sourceEffectiveFrom: date(2025, 1, 1),
            effectiveAt: date(2025, 6, 15),
            dateOfBirth: date(1990, 6, 15),
            biologicalSex: .female,
            heightCm: 165,
            weightKg: 60,
            activityLevel: .unspecified
        )
        let result = EnergyAccounting.calculate(
            observedBasalEnergyKcal: 1_420,
            observedActiveEnergyKcal: nil,
            profile: profile,
            effectiveWeightKg: 60
        )

        XCTAssertNil(result.expenditure)
        XCTAssertEqual(result.basalComponent?.source, .observed)
        XCTAssertNil(result.activeComponent)
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
