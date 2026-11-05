import DensosoDomain
import Foundation
import XCTest
@testable import Densoso

@MainActor
final class GetWeeklyDeficitToolTests: XCTestCase {
    func testResponseDisclosesRoughEnergyConversionAndMissingDays() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let weekStart = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
        let weekEnd = try XCTUnwrap(calendar.date(byAdding: .day, value: 6, to: weekStart))
        let recorded = DailyMetricsReadModelMapper.make(DailyMetrics(
            date: weekStart,
            totalExpenditureKcal: 2_000,
            totalIntakeKcal: 1_750,
            deficitKcal: 250,
            mealCount: 1,
            energyQuality: EnergyQuality.observed.rawValue,
            dataCoverageJSON: completeNutritionCoverage("weekly-deficit-meals"),
            projectionVersion: AlgorithmVersions.dailyMetricsProjection,
            sourceFingerprint: "weekly-deficit-test"
        ))

        let output = GetWeeklyDeficitTool.responseJSON(
            [recorded],
            weekStart: weekStart,
            weekEnd: weekEnd,
            expectedDays: 7,
            calendar: calendar
        )
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        let total = try XCTUnwrap(response["totalDeficitKcal"] as? [String: Any])
        let coverage = try XCTUnwrap(response["coverage"] as? [String: Any])

        XCTAssertEqual(response["status"] as? String, "available")
        XCTAssertEqual(response["projectionVersion"] as? String, AlgorithmVersions.dailyMetricsProjection)
        XCTAssertEqual(response["projectionVersions"] as? [String], [AlgorithmVersions.dailyMetricsProjection])
        XCTAssertEqual(response["projectedWeightLossNote"] as? String,
                       "仅按累计净能量缺口以 7,700 kcal/kg 粗略折算；不代表实际体重预测。")
        XCTAssertEqual(response["requestedDays"] as? Int, 7)
        XCTAssertEqual(response["daysWithData"] as? Int, 1)
        XCTAssertEqual(response["missingDays"] as? Int, 6)
        XCTAssertEqual(coverage["availableDays"] as? Int, 1)
        let value = try XCTUnwrap(total["value"] as? Double)
        XCTAssertEqual(value, 250)
        XCTAssertLessThanOrEqual(output.utf8.count, AgentToolOutputLimiter.maximumUTF8Bytes)
    }

    func testMixedProjectionVersionsRemainExplicitInWeeklySummary() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let weekStart = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
        let secondDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: weekStart))
        let weekEnd = try XCTUnwrap(calendar.date(byAdding: .day, value: 6, to: weekStart))
        let current = DailyMetricsReadModelMapper.make(DailyMetrics(
            date: weekStart,
            totalExpenditureKcal: 2_000,
            totalIntakeKcal: 1_750,
            deficitKcal: 250,
            mealCount: 1,
            energyQuality: EnergyQuality.observed.rawValue,
            dataCoverageJSON: completeNutritionCoverage("weekly-deficit-current-version"),
            projectionVersion: AlgorithmVersions.dailyMetricsProjection,
            sourceFingerprint: "weekly-deficit-current-version"
        ))
        let legacy = DailyMetricsReadModelMapper.make(DailyMetrics(
            date: secondDay,
            totalExpenditureKcal: 2_000,
            totalIntakeKcal: 1_750,
            deficitKcal: 250,
            mealCount: 1,
            energyQuality: EnergyQuality.observed.rawValue,
            dataCoverageJSON: #"{"intake":true,"protein":false,"fat":false,"carbs":false}"#,
            projectionVersion: "daily-metrics-legacy-v1",
            sourceFingerprint: "weekly-deficit-legacy-version"
        ))

        let output = GetWeeklyDeficitTool.responseJSON(
            [current, legacy],
            weekStart: weekStart,
            weekEnd: weekEnd,
            expectedDays: 7,
            calendar: calendar
        )
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])

        XCTAssertEqual(response["projectionVersion"] as? String, "mixed")
        XCTAssertEqual(
            response["projectionVersions"] as? [String],
            ["daily-metrics-legacy-v1", AlgorithmVersions.dailyMetricsProjection].sorted()
        )
    }

    func testEmptyResponseDoesNotConvertUnavailableDeficitToZero() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let weekStart = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
        let weekEnd = try XCTUnwrap(calendar.date(byAdding: .day, value: 6, to: weekStart))

        let output = GetWeeklyDeficitTool.responseJSON(
            [],
            weekStart: weekStart,
            weekEnd: weekEnd,
            expectedDays: 7,
            calendar: calendar
        )
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        let total = try XCTUnwrap(response["totalDeficitKcal"] as? [String: Any])

        XCTAssertEqual(response["status"] as? String, "insufficient_data")
        XCTAssertEqual(response["projectionVersion"] as? String, "unavailable")
        XCTAssertEqual(response["projectionVersions"] as? [String], [])
        XCTAssertTrue(total["value"] is NSNull)
    }

    func testPartialDayIntakeDoesNotContributeToWeeklyDeficit() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let weekStart = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
        let weekEnd = try XCTUnwrap(calendar.date(byAdding: .day, value: 6, to: weekStart))
        let partial = DailyMetricsReadModelMapper.make(DailyMetrics(
            date: weekStart,
            totalExpenditureKcal: 2_000,
            totalIntakeKcal: 1_000,
            deficitKcal: 1_000,
            mealCount: 1,
            energyQuality: EnergyQuality.observed.rawValue,
            dataCoverageJSON: #"{"intake":true,"nutritionRecordStatus":"inProgress","nutritionMealFingerprint":"partial-meal-set"}"#,
            projectionVersion: AlgorithmVersions.dailyMetricsProjection,
            sourceFingerprint: "partial-weekly-deficit"
        ))
        let output = GetWeeklyDeficitTool.responseJSON(
            [partial],
            weekStart: weekStart,
            weekEnd: weekEnd,
            expectedDays: 7,
            calendar: calendar
        )
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        let total = try XCTUnwrap(response["totalDeficitKcal"] as? [String: Any])

        XCTAssertEqual(response["status"] as? String, "insufficient_data")
        XCTAssertEqual(response["daysWithData"] as? Int, 0)
        XCTAssertTrue(total["value"] is NSNull)
    }

    private func completeNutritionCoverage(_ fingerprint: String) -> String {
        #"{"intake":true,"allRecordedMealsHaveEvidence":true,"protein":false,"proteinComplete":false,"fat":false,"fatComplete":false,"carbs":false,"carbsComplete":false,"nutritionRecordStatus":"complete","nutritionMealFingerprint":"\#(fingerprint)","nutritionCompletionMealFingerprint":"\#(fingerprint)"}"#
    }
}
