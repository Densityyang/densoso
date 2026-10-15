import XCTest
@testable import DensosoDomain

final class CanonicalActionPayloadTests: XCTestCase {
    func testMealCanonicalDataIsStableAcrossEvidenceInputOrder() throws {
        let firstEvidence = EvidenceSnapshot(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            grade: .databaseMatch,
            sourceID: "food-db:1",
            sourceVersion: "6",
            summary: "rice",
            confidence: 0.8
        )
        let secondEvidence = EvidenceSnapshot(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            grade: .userReported,
            summary: "one bowl",
            confidence: 0.7
        )
        let first = try mealPayload(evidence: [secondEvidence, firstEvidence])
        let second = try mealPayload(evidence: [firstEvidence, secondEvidence])

        XCTAssertEqual(try first.canonicalData(), try second.canonicalData())
    }

    func testCanonicalDataChangesWhenSemanticPayloadChanges() throws {
        let first = ActionPayload.weight(
            WeightDraft(measuredAt: Date(timeIntervalSince1970: 1_700_000_000), kilograms: 62.25)
        )
        let second = ActionPayload.weight(
            WeightDraft(measuredAt: Date(timeIntervalSince1970: 1_700_000_000), kilograms: 62.30)
        )

        XCTAssertNotEqual(try first.canonicalData(), try second.canonicalData())
    }

    func testGeneratedDraftIdentifiersDoNotChangeSemanticCanonicalData() throws {
        let firstEvidence = EvidenceSnapshot(
            grade: .userReported,
            sourceID: "voice",
            summary: "one bowl",
            confidence: 0.75
        )
        let secondEvidence = EvidenceSnapshot(
            grade: .userReported,
            sourceID: "voice",
            summary: "one bowl",
            confidence: 0.75
        )

        XCTAssertEqual(
            try mealPayload(evidence: [firstEvidence]).canonicalData(),
            try mealPayload(evidence: [secondEvidence]).canonicalData()
        )
    }

    func testEvidenceConfidenceParticipatesInStableTieOrdering() throws {
        let lower = EvidenceSnapshot(
            grade: .estimated,
            sourceID: "same",
            sourceVersion: "1",
            summary: "same",
            confidence: 0.25
        )
        let higher = EvidenceSnapshot(
            grade: .estimated,
            sourceID: "same",
            sourceVersion: "1",
            summary: "same",
            confidence: 0.75
        )

        XCTAssertEqual(
            try mealPayload(evidence: [higher, lower]).canonicalData(),
            try mealPayload(evidence: [lower, higher]).canonicalData()
        )
    }

    func testWorkoutAndStrengthSetIdentifiersDoNotChangeCanonicalData() throws {
        let first = WorkoutPlanDraft(
            id: UUID(),
            name: "5x5",
            activity: .strength,
            strengthSets: [
                .init(id: UUID(), exerciseID: "squat", exerciseName: "Squat", setCount: 5, repetitions: 5)
            ]
        )
        let second = WorkoutPlanDraft(
            id: UUID(),
            name: "5x5",
            activity: .strength,
            strengthSets: [
                .init(id: UUID(), exerciseID: "squat", exerciseName: "Squat", setCount: 5, repetitions: 5)
            ]
        )

        XCTAssertEqual(
            try ActionPayload.workoutPlan(first).canonicalData(),
            try ActionPayload.workoutPlan(second).canonicalData()
        )
    }

    func testUnsafeNumbersReturnErrorsInsteadOfTrapping() throws {
        XCTAssertThrowsError(
            try ActionPayload.weight(
                WeightDraft(measuredAt: Date(), kilograms: .infinity)
            ).canonicalData()
        )

        let hugeRange = try EstimateRange(
            low: Double.greatestFiniteMagnitude,
            likely: Double.greatestFiniteMagnitude,
            high: Double.greatestFiniteMagnitude
        )
        let hugeDish = MealDishDraft(
            name: "huge",
            nutrients: NutrientEstimate(energyKcal: hugeRange),
            algorithmVersion: "v3"
        )
        XCTAssertThrowsError(
            try ActionPayload.meal(
                MealDraft(occurredAt: Date(), mealType: "lunch", dishes: [hugeDish])
            ).canonicalData()
        )

        let invalidLoad = WorkoutPlanDraft(
            name: "invalid",
            activity: .strength,
            strengthSets: [
                .init(exerciseName: "squat", setCount: 1, repetitions: 1, loadKilograms: .nan)
            ]
        )
        XCTAssertThrowsError(try ActionPayload.workoutPlan(invalidLoad).canonicalData())
    }

    func testMissingMacrosRemainMissingInsteadOfBecomingZero() throws {
        let energy = try EstimateRange(low: 300, likely: 350, high: 420)
        let dish = MealDishDraft(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            name: "unknown meal",
            nutrients: NutrientEstimate(energyKcal: energy),
            algorithmVersion: "v3"
        )
        let draft = MealDraft(
            occurredAt: Date(timeIntervalSince1970: 1_700_000_000),
            mealType: "lunch",
            dishes: [dish]
        )

        XCTAssertNil(draft.totalNutrients?.proteinGrams)
        XCTAssertNil(draft.totalNutrients?.fatGrams)
        XCTAssertNil(draft.totalNutrients?.carbohydrateGrams)
    }

    private func mealPayload(evidence: [EvidenceSnapshot]) throws -> ActionPayload {
        let energy = try EstimateRange(low: 180, likely: 200, high: 230)
        let amount = try EstimateRange(low: 140, likely: 150, high: 170)
        let ingredient = MealIngredientDraft(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
            foodID: "food-db:1",
            name: "rice",
            amountGrams: amount,
            nutrients: NutrientEstimate(energyKcal: energy),
            evidence: evidence
        )
        let dish = MealDishDraft(
            id: UUID(uuidString: "30000000-0000-0000-0000-000000000001")!,
            name: "rice",
            portionGrams: amount,
            nutrients: NutrientEstimate(energyKcal: energy),
            ingredients: [ingredient],
            evidence: evidence,
            algorithmVersion: "v3"
        )
        return .meal(
            MealDraft(
                occurredAt: Date(timeIntervalSince1970: 1_700_000_000.1234),
                mealType: " Lunch ",
                dishes: [dish]
            )
        )
    }
}
