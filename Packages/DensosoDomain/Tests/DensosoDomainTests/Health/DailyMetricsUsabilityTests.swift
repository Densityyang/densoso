import XCTest
@testable import DensosoDomain

final class DailyMetricsUsabilityTests: XCTestCase {
    func testEmptyAndAllUnavailableRangesDoNotBecomeZeroTotals() {
        let empty = DailyMetricsUsabilityPolicy.aggregateSignedRanges([], expectedDays: 7)
        XCTAssertNil(empty.total.value)
        XCTAssertEqual(empty.total.availability, .unavailable)
        XCTAssertEqual(empty.coverage.missingDays, 7)

        let pending = MetricValue<SignedEstimateRange>(value: nil, availability: .pendingRecompute)
        let allPending = DailyMetricsUsabilityPolicy.aggregateSignedRanges([pending], expectedDays: 1)
        XCTAssertNil(allPending.total.value)
        XCTAssertEqual(allPending.total.availability, .pendingRecompute)
        XCTAssertEqual(allPending.coverage.pendingRecomputeDays, 1)
    }

    func testEnergyAvailabilityNeverTreatsPendingLegacyOrUnversionedDataAsValid() {
        XCTAssertEqual(
            DailyMetricsUsabilityPolicy.energyAvailability(
                quality: .observed,
                requiresRecompute: true,
                hasCurrentProjectionEvidence: true
            ),
            .pendingRecompute
        )
        XCTAssertEqual(
            DailyMetricsUsabilityPolicy.energyAvailability(
                quality: .legacy,
                requiresRecompute: false,
                hasCurrentProjectionEvidence: true
            ),
            .unavailable
        )
        XCTAssertEqual(
            DailyMetricsUsabilityPolicy.energyAvailability(
                quality: .observed,
                requiresRecompute: false,
                hasCurrentProjectionEvidence: false
            ),
            .unavailable
        )
        XCTAssertEqual(
            DailyMetricsUsabilityPolicy.energyAvailability(
                quality: .estimated,
                requiresRecompute: false,
                hasCurrentProjectionEvidence: true
            ),
            .estimated
        )
    }

    func testDeficitRequiresBothIntakeAndExpenditureAndUsesSignedRanges() throws {
        let intake = MetricValue(
            value: try EstimateRange(low: 1_400, likely: 1_500, high: 1_600),
            availability: .estimated,
            sourceReferences: ["meal-source"]
        )
        let expenditure = MetricValue(
            value: try EstimateRange(low: 1_900, likely: 2_000, high: 2_100),
            availability: .observed,
            sourceReferences: ["energy-source"]
        )

        let deficit = DailyMetricsUsabilityPolicy.deficit(expenditure: expenditure, intake: intake)
        XCTAssertEqual(deficit.availability, .estimated)
        XCTAssertEqual(try XCTUnwrap(deficit.value), try SignedEstimateRange(low: 300, likely: 500, high: 700))
        XCTAssertEqual(deficit.sourceReferences, ["energy-source", "meal-source"])

        let noExpenditure = MetricValue<EstimateRange>(value: nil, availability: .unavailable)
        let unavailableDeficit = DailyMetricsUsabilityPolicy.deficit(expenditure: noExpenditure, intake: intake)
        XCTAssertNil(unavailableDeficit.value)
        XCTAssertEqual(unavailableDeficit.availability, .unavailable)
    }

    func testPartialWeekSumsOnlyValidDaysAndPreservesCoverage() throws {
        let dayOne = MetricValue(
            value: try SignedEstimateRange(low: 100, likely: 200, high: 300),
            availability: .observed,
            sourceReferences: ["day-one"]
        )
        let dayTwo = MetricValue(
            value: try SignedEstimateRange(low: -100, likely: 500, high: 900),
            availability: .estimated,
            sourceReferences: ["day-two"]
        )

        let result = DailyMetricsUsabilityPolicy.aggregateSignedRanges([dayOne, dayTwo], expectedDays: 7)

        XCTAssertEqual(try XCTUnwrap(result.total.value), try SignedEstimateRange(low: 0, likely: 700, high: 1_200))
        XCTAssertEqual(result.total.availability, .partial)
        XCTAssertEqual(result.coverage.availableDays, 2)
        XCTAssertEqual(result.coverage.missingDays, 5)
        XCTAssertEqual(try XCTUnwrap(result.coverage.fraction), 2.0 / 7.0, accuracy: 0.000_1)
    }

    func testFullCoverageStillReportsPartialWhenOneDayIsPartial() throws {
        let values = [
            MetricValue(
                value: try SignedEstimateRange(low: 100, likely: 200, high: 300),
                availability: .estimated
            ),
            MetricValue(
                value: try SignedEstimateRange(low: -50, likely: 50, high: 150),
                availability: .partial
            ),
        ]

        let result = DailyMetricsUsabilityPolicy.aggregateSignedRanges(values, expectedDays: 2)

        XCTAssertEqual(result.coverage.availableDays, 2)
        XCTAssertEqual(result.total.availability, .partial)
        XCTAssertEqual(try XCTUnwrap(result.total.value), try SignedEstimateRange(low: 50, likely: 250, high: 450))
    }

    func testNutrientAvailabilityIsIndependentAndAverageUsesValidSampleCount() {
        let proteinValues = [
            MetricValue(value: 80.0, availability: .estimated, sourceReferences: ["meal-a"]),
            MetricValue(value: 120.0, availability: .estimated, sourceReferences: ["meal-b"]),
            MetricValue<Double>(value: nil, availability: .unavailable),
        ]

        let result = DailyMetricsUsabilityPolicy.aggregateNumbers(proteinValues, expectedDays: 7, average: true)

        XCTAssertEqual(result.total.value, 100)
        XCTAssertEqual(result.total.availability, .partial)
        XCTAssertEqual(result.coverage.availableDays, 2)
        XCTAssertEqual(result.coverage.unavailableDays, 1)
        XCTAssertEqual(result.coverage.missingDays, 4)

        let unknownFat = DailyMetricsUsabilityPolicy.value(
            Optional<Double>.none,
            availability: .estimated,
            hasEvidence: false
        )
        XCTAssertNil(unknownFat.value)
        XCTAssertEqual(unknownFat.availability, .unavailable)
    }

    func testAggregatesDoNotCountMissingOrNonFiniteValuesAsAvailableDays() throws {
        let missingObservedNumber = MetricValue<Double>(value: nil, availability: .observed)
        let infiniteObservedNumber = MetricValue(value: Double.infinity, availability: .observed)
        let usableNumber = MetricValue(value: 100.0, availability: .estimated)

        let numericAverage = DailyMetricsUsabilityPolicy.aggregateNumbers(
            [missingObservedNumber, infiniteObservedNumber, usableNumber],
            expectedDays: 3,
            average: true
        )
        XCTAssertEqual(numericAverage.total.value, 100)
        XCTAssertEqual(numericAverage.total.availability, .partial)
        XCTAssertEqual(numericAverage.coverage.availableDays, 1)
        XCTAssertEqual(numericAverage.coverage.unavailableDays, 2)
        XCTAssertEqual(numericAverage.coverage.missingDays, 0)

        let missingEstimatedRange = MetricValue<EstimateRange>(value: nil, availability: .estimated)
        let validRange = MetricValue(
            value: try EstimateRange(low: 90, likely: 100, high: 110),
            availability: .observed
        )
        let rangeTotal = DailyMetricsUsabilityPolicy.aggregateRanges(
            [missingEstimatedRange, validRange],
            expectedDays: 2
        )
        XCTAssertEqual(rangeTotal.coverage.availableDays, 1)
        XCTAssertEqual(rangeTotal.coverage.unavailableDays, 1)
        XCTAssertEqual(try XCTUnwrap(rangeTotal.total.value), try EstimateRange(low: 90, likely: 100, high: 110))

        let missingObservedDeficit = MetricValue<SignedEstimateRange>(value: nil, availability: .observed)
        let signedTotal = DailyMetricsUsabilityPolicy.aggregateSignedRanges(
            [missingObservedDeficit],
            expectedDays: 1
        )
        XCTAssertNil(signedTotal.total.value)
        XCTAssertEqual(signedTotal.total.availability, .unavailable)
        XCTAssertEqual(signedTotal.coverage.availableDays, 0)
        XCTAssertEqual(signedTotal.coverage.unavailableDays, 1)
    }
}
