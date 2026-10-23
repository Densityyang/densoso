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
            dataCoverageJSON: #"{"intake":true,"protein":false,"fat":false,"carbs":false}"#,
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
        XCTAssertTrue(total["value"] is NSNull)
    }
}
