import Foundation
import XCTest
@testable import DensosoDomain

final class CaloriePresentationPolicyContractTests: XCTestCase {
    private let policy = CaloriePresentationPolicy()

    func testLikelyKcalUsesNearest25KcalStep() throws {
        let cases: [(input: Double, expected: Int)] = [
            (0, 0),
            (0.1, 25),
            (12.49, 25),
            (87.49, 75),
            (87.5, 100),
            (112.49, 100),
            (112.5, 125),
            (1_000_000_000, 1_000_000_000),
        ]

        for testCase in cases {
            let estimate = try EstimateRange.point(testCase.input)
            XCTAssertEqual(
                policy.presentation(for: estimate).likelyKcal,
                testCase.expected,
                "Unexpected 25 kcal rounding for \(testCase.input) kcal"
            )
        }
    }

    func testRoundingDoesNotChangeConfidenceOrClarificationThresholds() throws {
        XCTAssertEqual(
            policy.presentation(for: try EstimateRange(low: 82.5, likely: 100, high: 117.5)),
            .likely(kcal: 100, confidence: .high)
        )
        XCTAssertEqual(
            policy.presentation(for: try EstimateRange(low: 67.5, likely: 100, high: 132.5)),
            .likely(kcal: 100, confidence: .medium)
        )
        XCTAssertEqual(
            policy.presentation(for: try EstimateRange(low: 67.49, likely: 100, high: 132.51)),
            .needsClarification(likelyKcal: 100)
        )
    }

    func testPositiveEstimateNeverRoundsDownToZeroIncludingClarification() throws {
        XCTAssertEqual(
            policy.presentation(for: try EstimateRange.point(0.01)),
            .likely(kcal: 25, confidence: .high)
        )
        XCTAssertEqual(
            policy.presentation(for: try EstimateRange(low: 0, likely: 0.01, high: 1)),
            .needsClarification(likelyKcal: 25)
        )
        XCTAssertEqual(
            policy.presentation(for: try EstimateRange.point(0)),
            .likely(kcal: 0, confidence: .high)
        )
    }
}
