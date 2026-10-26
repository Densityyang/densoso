import DensosoDomain
import Foundation
import XCTest
@testable import Densoso

@MainActor
final class GetMetricsToolTests: XCTestCase {
    func testResponseKeepsPartialCoverageAndPagesDailyBreakdownAsValidJSON() throws {
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
        let rows = try (0..<6).map { offset -> DailyMetricsReadResult in
            let date = try XCTUnwrap(calendar.date(byAdding: .day, value: offset, to: start))
            return DailyMetricsReadModelMapper.make(metric(on: date, deficit: 100 + offset))
        }
        let end = try XCTUnwrap(calendar.date(byAdding: .day, value: 6, to: start))

        let output = GetMetricsTool.responseJSON(rows, from: start, through: end, calendar: calendar)
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])

        XCTAssertEqual(response["status"] as? String, "available")
        XCTAssertEqual(
            response["projectedWeightLossNote"] as? String,
            "仅按累计净能量缺口以 7,700 kcal/kg 粗略折算；不代表实际体重预测。"
        )
        XCTAssertEqual(response["requestedDays"] as? Int, 7)
        XCTAssertEqual(response["validEnergyDays"] as? Int, 6)
        XCTAssertEqual(response["missingEnergyDays"] as? Int, 1)
        XCTAssertEqual(response["truncated"] as? Bool, true)
        let dailyBreakdown = try XCTUnwrap(response["dailyBreakdown"] as? [[String: Any]])
        XCTAssertGreaterThan(dailyBreakdown.count, 0)
        XCTAssertLessThanOrEqual(dailyBreakdown.count, 4)
        XCTAssertLessThan(dailyBreakdown.count, rows.count)
        let nextStartDateString = try XCTUnwrap(response["nextStartDate"] as? String)
        let nextStartDate = try XCTUnwrap(ISO8601DateFormatter().date(from: nextStartDateString))
        XCTAssertEqual(nextStartDate, rows[dailyBreakdown.count].date)

        let firstDay = try XCTUnwrap(dailyBreakdown.first)
        XCTAssertEqual(firstDay["energyQuality"] as? String, EnergyQuality.observed.rawValue)
        XCTAssertEqual(firstDay["requiresRecompute"] as? Bool, false)
        XCTAssertEqual(firstDay["projectionVersion"] as? String, AlgorithmVersions.dailyMetricsProjection)
        let dailyCoverage = try XCTUnwrap(firstDay["coverage"] as? [String: Any])
        let deficitCoverage = try XCTUnwrap(dailyCoverage["deficit"] as? [String: Any])
        XCTAssertEqual(deficitCoverage["availableDays"] as? Int, 1)
        XCTAssertEqual(deficitCoverage["expectedDays"] as? Int, 1)

        let deficit = try XCTUnwrap(response["deficit"] as? [String: Any])
        let total = try XCTUnwrap(deficit["total"] as? [String: Any])
        let value = try XCTUnwrap(total["value"] as? [String: Any])
        XCTAssertEqual(total["availability"] as? String, "partial")
        XCTAssertEqual(try XCTUnwrap(value["likely"] as? Double), 615)
        XCTAssertLessThanOrEqual(output.utf8.count, AgentToolOutputLimiter.maximumUTF8Bytes)
    }

    func testDailyBreakdownPreservesPendingRecomputeEvidence() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
        let pending = DailyMetrics(
            date: day,
            totalIntakeKcal: 1_750,
            mealCount: 1,
            intakeEnergyLowKcal: 1_700,
            intakeEnergyLikelyKcal: 1_750,
            intakeEnergyHighKcal: 1_800,
            energyQuality: EnergyQuality.unavailable.rawValue,
            dataCoverageJSON: #"{"intake":true,"protein":false,"fat":false,"carbs":false}"#,
            projectionVersion: AlgorithmVersions.dailyMetricsProjection,
            sourceFingerprint: "pending-get-metrics",
            requiresRecompute: true
        )

        let output = GetMetricsTool.responseJSON(
            [DailyMetricsReadModelMapper.make(pending)],
            from: day,
            through: day,
            calendar: calendar
        )
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        let firstDay = try XCTUnwrap((response["dailyBreakdown"] as? [[String: Any]])?.first)
        let coverage = try XCTUnwrap(firstDay["coverage"] as? [String: Any])
        let intakeResponse = try XCTUnwrap(response["intake"] as? [String: Any])
        let intakeTotal = try XCTUnwrap(intakeResponse["total"] as? [String: Any])
        let intakeCoverage = try XCTUnwrap(intakeResponse["coverage"] as? [String: Any])
        let expenditureCoverage = try XCTUnwrap(coverage["expenditure"] as? [String: Any])
        let dailyIntakeCoverage = try XCTUnwrap(coverage["intake"] as? [String: Any])

        XCTAssertEqual(firstDay["energyQuality"] as? String, EnergyQuality.unavailable.rawValue)
        XCTAssertEqual(firstDay["requiresRecompute"] as? Bool, true)
        XCTAssertEqual(firstDay["projectionVersion"] as? String, AlgorithmVersions.dailyMetricsProjection)
        XCTAssertEqual(expenditureCoverage["pendingRecomputeDays"] as? Int, 1)
        XCTAssertEqual(expenditureCoverage["availableDays"] as? Int, 0)
        XCTAssertEqual(dailyIntakeCoverage["pendingRecomputeDays"] as? Int, 1)
        XCTAssertEqual(dailyIntakeCoverage["availableDays"] as? Int, 0)
        XCTAssertEqual(intakeCoverage["pendingRecomputeDays"] as? Int, 1)
        XCTAssertEqual(intakeCoverage["availableDays"] as? Int, 0)
        XCTAssertTrue(intakeTotal["value"] is NSNull)
        XCTAssertEqual(intakeTotal["availability"] as? String, "pendingRecompute")
    }

    func testNoValidDaysReturnsInsufficientDataWithoutZeroTotals() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
        let end = try XCTUnwrap(calendar.date(byAdding: .day, value: 2, to: start))

        let output = GetMetricsTool.responseJSON([], from: start, through: end, calendar: calendar)
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        let deficit = try XCTUnwrap(response["deficit"] as? [String: Any])
        let total = try XCTUnwrap(deficit["total"] as? [String: Any])

        XCTAssertEqual(response["status"] as? String, "insufficient_data")
        XCTAssertEqual(response["validEnergyDays"] as? Int, 0)
        XCTAssertTrue(total["value"] is NSNull)
        XCTAssertEqual(total["availability"] as? String, "unavailable")
    }

    private func metric(on date: Date, deficit: Int) -> DailyMetrics {
        DailyMetrics(
            date: date,
            totalExpenditureKcal: 2_000,
            totalIntakeKcal: 2_000 - deficit,
            deficitKcal: deficit,
            proteinG: 80,
            fatG: 50,
            carbsG: 180,
            mealCount: 1,
            workoutCount: 0,
            energyQuality: "observed",
            dataCoverageJSON: #"{"intake":true,"protein":true,"fat":true,"carbs":true}"#,
            projectionVersion: AlgorithmVersions.dailyMetricsProjection,
            sourceFingerprint: "get-metrics-test-\(date.timeIntervalSince1970)"
        )
    }
}
