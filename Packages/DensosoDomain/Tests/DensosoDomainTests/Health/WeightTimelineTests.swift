import XCTest
@testable import DensosoDomain

final class WeightTimelineTests: XCTestCase {
    func testUsesLatestTrustedObservationNotLaterThanRequestedDate() throws {
        let old = observation(date: date(2025, 1, 1), kilograms: 64)
        let newestPast = observation(date: date(2025, 5, 1), kilograms: 62)
        let future = observation(date: date(2025, 7, 1), kilograms: 59)
        let timeline = WeightTimeline(observations: [future, old, newestPast])

        let result = try XCTUnwrap(timeline.effectiveWeight(at: date(2025, 6, 1)))

        XCTAssertEqual(result.kilograms, 62)
        XCTAssertEqual(result.measuredAt, newestPast.measuredAt)
        XCTAssertEqual(result.source, .manual)
    }

    func testFallsBackToProfileWeightOnlyAfterItsEffectiveDate() throws {
        let timeline = WeightTimeline(observations: [])

        XCTAssertNil(
            timeline.effectiveWeight(
                at: date(2025, 1, 1),
                profileWeightKg: 60,
                profileEffectiveFrom: date(2025, 2, 1)
            )
        )
        let result = try XCTUnwrap(
            timeline.effectiveWeight(
                at: date(2025, 3, 1),
                profileWeightKg: 60,
                profileEffectiveFrom: date(2025, 2, 1)
            )
        )

        XCTAssertEqual(result.kilograms, 60)
        XCTAssertEqual(result.source, .profileInitial)
        XCTAssertNil(result.confidence)
    }

    func testLowConfidenceObservationDoesNotHideProfileFallback() throws {
        let lowConfidence = observation(date: date(2025, 5, 1), kilograms: 62, confidence: 0.2)
        let timeline = WeightTimeline(observations: [lowConfidence])

        let result = try XCTUnwrap(
            timeline.effectiveWeight(
                at: date(2025, 6, 1),
                profileWeightKg: 64,
                profileEffectiveFrom: date(2025, 1, 1)
            )
        )

        XCTAssertEqual(result.kilograms, 64)
        XCTAssertEqual(result.source, .profileInitial)
    }

    func testInvalidObservationIsIgnored() throws {
        let invalid = observation(date: date(2025, 5, 1), kilograms: .nan)
        let valid = observation(date: date(2025, 4, 1), kilograms: 63)
        let timeline = WeightTimeline(observations: [invalid, valid])

        let result = try XCTUnwrap(timeline.effectiveWeight(at: date(2025, 6, 1)))

        XCTAssertEqual(result.kilograms, 63)
    }

    private func observation(date: Date, kilograms: Double, confidence: Double = 0.9) -> WeightObservation {
        WeightObservation(
            measuredAt: date,
            kilograms: kilograms,
            source: .manual,
            confidence: confidence
        )
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }
}
