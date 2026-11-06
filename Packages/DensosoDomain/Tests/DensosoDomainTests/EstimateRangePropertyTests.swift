import XCTest
@testable import DensosoDomain

final class EstimateRangePropertyTests: XCTestCase {
    func testRejectsNegativeUnorderedAndNonFiniteRanges() {
        XCTAssertThrowsError(try EstimateRange(low: -1, likely: 0, high: 1))
        XCTAssertThrowsError(try EstimateRange(low: 2, likely: 1, high: 3))
        XCTAssertThrowsError(try EstimateRange(low: 1, likely: 2, high: .infinity))
        XCTAssertThrowsError(try EstimateRange(low: 1, likely: .nan, high: 3))
    }

    func testScalingPreservesOrderForDeterministicSamples() throws {
        for seed in 0..<500 {
            let low = Double(seed % 37) / 3
            let likely = low + Double(seed % 17) / 5
            let high = likely + Double(seed % 23) / 7
            let factor = Double(seed % 29) / 4
            let range = try EstimateRange(low: low, likely: likely, high: high)

            let scaled = try range.scaled(by: factor)

            XCTAssertGreaterThanOrEqual(scaled.low, 0)
            XCTAssertLessThanOrEqual(scaled.low, scaled.likely)
            XCTAssertLessThanOrEqual(scaled.likely, scaled.high)
            XCTAssertEqual(scaled.likely, likely * factor, accuracy: 0.000_001)
        }
    }

    func testSumIsAssociativeWithinFloatingPointTolerance() throws {
        for seed in 1...250 {
            let first = try sample(seed)
            let second = try sample(seed + 7)
            let third = try sample(seed + 19)

            let left = try first.adding(second).adding(third)
            let right = try first.adding(try second.adding(third))

            XCTAssertEqual(left.low, right.low, accuracy: 0.000_001)
            XCTAssertEqual(left.likely, right.likely, accuracy: 0.000_001)
            XCTAssertEqual(left.high, right.high, accuracy: 0.000_001)
        }
    }

    func testDecodingCannotBypassValidation() throws {
        let invalid = Data(#"{"low":20,"likely":10,"high":30}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(EstimateRange.self, from: invalid))
    }

    private func sample(_ seed: Int) throws -> EstimateRange {
        let low = Double(seed % 31)
        return try EstimateRange(
            low: low,
            likely: low + Double(seed % 11),
            high: low + Double(seed % 11) + Double(seed % 13)
        )
    }
}
