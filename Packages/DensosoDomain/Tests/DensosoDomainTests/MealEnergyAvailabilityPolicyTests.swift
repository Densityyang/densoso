import XCTest
@testable import DensosoDomain

final class MealEnergyAvailabilityPolicyTests: XCTestCase {
    func testExplicitZeroRequiresCurrentResolvedEvidence() {
        let measured = EvidenceSnapshot(
            grade: .measured,
            sourceID: "measured-zero",
            summary: "Measured zero energy."
        )
        let legacy = EvidenceSnapshot(
            grade: .legacyPointEstimate,
            sourceID: "legacy-meal",
            summary: "Legacy point estimate."
        )
        let unresolved = EvidenceSnapshot(
            grade: .unresolved,
            sourceID: "missing-energy",
            summary: "Energy is unavailable."
        )

        XCTAssertTrue(MealEnergyAvailabilityPolicy.supportsExplicitZero([measured]))
        XCTAssertFalse(MealEnergyAvailabilityPolicy.supportsExplicitZero([]))
        XCTAssertFalse(MealEnergyAvailabilityPolicy.supportsExplicitZero([legacy]))
        XCTAssertFalse(MealEnergyAvailabilityPolicy.supportsExplicitZero([unresolved]))
        XCTAssertFalse(MealEnergyAvailabilityPolicy.supportsExplicitZero([measured, unresolved]))
        XCTAssertTrue(MealEnergyAvailabilityPolicy.hasCurrentResolvedEvidence([measured]))
        XCTAssertFalse(MealEnergyAvailabilityPolicy.hasCurrentResolvedEvidence([legacy]))
    }
}
