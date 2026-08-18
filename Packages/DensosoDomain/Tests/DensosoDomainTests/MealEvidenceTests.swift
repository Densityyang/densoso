import XCTest
@testable import DensosoDomain

final class MealEvidenceTests: XCTestCase {
    func testUnmeasuredPortionRemainsARange() throws {
        let estimate = try PortionEstimate(lowGrams: 80, likelyGrams: 150, highGrams: 260, isMeasured: false)
        XCTAssertNotEqual(estimate.lowGrams, estimate.highGrams)
        XCTAssertFalse(estimate.isMeasured)
    }

    func testSelectorAsksOnlyOneHighestValueQuestion() throws {
        let selector = ClarificationSelector()
        XCTAssertEqual(selector.nextQuestion(candidates: [], portion: nil, cookingMethod: nil), .foodIdentity)

        let candidate = MealEvidence(kind: .foodCandidate, value: "鸡胸肉", confidence: 0.9)
        XCTAssertEqual(selector.nextQuestion(candidates: [candidate], portion: nil, cookingMethod: nil), .portion)

        let measured = try PortionEstimate(lowGrams: 150, likelyGrams: 150, highGrams: 150, isMeasured: true)
        XCTAssertEqual(selector.nextQuestion(candidates: [candidate], portion: measured, cookingMethod: nil), .cookingMethod)
    }

    func testEvidenceHasNoRawPhotoOrPromptField() {
        let evidence = MealEvidence(kind: .nutritionLabel, value: "能量 200 kcal", confidence: 0.95)
        XCTAssertEqual(evidence.value, "能量 200 kcal")
        XCTAssertEqual(evidence.kind, .nutritionLabel)
    }
}
