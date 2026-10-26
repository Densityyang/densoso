import DensosoDomain
import Foundation
import XCTest
@testable import Densoso

@MainActor
final class GetHealthHistoryToolTests: XCTestCase {
    func testRegistryExposesStrictReadOnlyBoundedHistoryTool() throws {
        let definition = try XCTUnwrap(
            ToolRegistry().toolDefinitions.first(where: { $0.name == "get_health_history" })
        )

        XCTAssertEqual(definition.effect, .readOnly)
        guard case .object(let properties, let required, let additionalProperties, _) = definition.parameters else {
            return XCTFail("get_health_history must use a closed object schema")
        }
        XCTAssertEqual(Set(properties.keys), Set(["startDate", "endDate"]))
        XCTAssertEqual(Set(required), Set(["startDate", "endDate"]))
        XCTAssertFalse(additionalProperties)
        XCTAssertThrowsError(try ToolSchemaValidator.validate(
            .object([
                "startDate": .string("2026-09-01T00:00:00Z"),
                "endDate": .string("2026-09-07T00:00:00Z"),
                "includeRawSamples": .boolean(true),
            ]),
            against: definition.parameters
        ))
    }

    func testResponseContainsOnlyDailyAggregatesAndExplicitEvidenceStatus() throws {
        let calendar = Calendar.current
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 1)))
        let point = HealthStateHistoryPoint(date: start, state: makeState())
        let tool = GetHealthHistoryTool(calendar: calendar)

        let response = try tool.response(from: start, through: start, points: [point])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
        XCTAssertEqual(object["status"] as? String, "partial")
        let days = try XCTUnwrap(object["days"] as? [[String: Any]])
        let firstDay = try XCTUnwrap(days.first)
        XCTAssertEqual(firstDay["date"] as? String, "2026-09-01")
        XCTAssertNil(firstDay["tomorrowGuidance"])
        let observations = try XCTUnwrap(firstDay["observations"] as? [String: Double])
        XCTAssertEqual(observations["sleep.mainSleep.minutes"], 300)
        XCTAssertEqual(observations["trainingLoad.ratio"], 1.2)
        let statuses = try XCTUnwrap(firstDay["domainStatuses"] as? [String: String])
        XCTAssertEqual(statuses["sleep"], HealthDomainStatus.attention.rawValue)
        XCTAssertFalse(response.contains("healthKitSamples"))
    }

    func testResponseFiltersAndFormatsTimestampedPointsByLocalDayIncludingEndDate() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let start = try localDate(2026, 3, 7, 18, 0, calendar: calendar)
        let end = try localDate(2026, 3, 8, 12, 0, calendar: calendar)
        let beforeStart = try localDate(2026, 3, 6, 23, 59, calendar: calendar)
        let firstDayLatePoint = try localDate(2026, 3, 7, 23, 45, calendar: calendar)
        let endDayLatePoint = try localDate(2026, 3, 8, 23, 59, calendar: calendar)
        let afterEnd = try localDate(2026, 3, 9, 0, 0, calendar: calendar)
        let tool = GetHealthHistoryTool(calendar: calendar)

        let response = try tool.response(
            from: start,
            through: end,
            points: [
                HealthStateHistoryPoint(date: afterEnd, state: makeState()),
                HealthStateHistoryPoint(date: endDayLatePoint, state: makeState()),
                HealthStateHistoryPoint(date: beforeStart, state: makeState()),
                HealthStateHistoryPoint(date: firstDayLatePoint, state: makeState()),
            ]
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
        let days = try XCTUnwrap(object["days"] as? [[String: Any]])

        XCTAssertEqual(object["startDate"] as? String, "2026-03-07")
        XCTAssertEqual(object["endDate"] as? String, "2026-03-08")
        XCTAssertEqual(days.compactMap { $0["date"] as? String }, ["2026-03-07", "2026-03-08"])
    }

    func testResponseCoalescesDuplicateLocalDaysAndDomainStatuses() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let start = try localDate(2026, 3, 7, 0, 0, calendar: calendar)
        let earlier = try localDate(2026, 3, 7, 8, 15, calendar: calendar)
        let latest = try localDate(2026, 3, 7, 22, 45, calendar: calendar)
        let tool = GetHealthHistoryTool(calendar: calendar)

        let response = try tool.response(
            from: start,
            through: start,
            points: [
                HealthStateHistoryPoint(
                    date: latest,
                    state: makeState(sleepMinutes: 390, duplicateSleepDomain: true)
                ),
                HealthStateHistoryPoint(date: earlier, state: makeState(sleepMinutes: 240)),
            ]
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
        let days = try XCTUnwrap(object["days"] as? [[String: Any]])
        let day = try XCTUnwrap(days.first)
        let observations = try XCTUnwrap(day["observations"] as? [String: Double])
        let statuses = try XCTUnwrap(day["domainStatuses"] as? [String: String])

        XCTAssertEqual(days.count, 1)
        XCTAssertEqual(day["date"] as? String, "2026-03-07")
        XCTAssertEqual(observations["sleep.mainSleep.minutes"], 390)
        XCTAssertEqual(statuses, ["sleep": HealthDomainStatus.attention.rawValue])
    }

    func testResponseTieBreaksEqualTimestampPointsIndependentOfInputOrder() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let pointDate = try localDate(2026, 3, 7, 12, 30, calendar: calendar)
        let first = HealthStateHistoryPoint(date: pointDate, state: makeState(sleepMinutes: 240))
        let second = HealthStateHistoryPoint(date: pointDate, state: makeState(sleepMinutes: 390))
        let tool = GetHealthHistoryTool(calendar: calendar)

        let forward = try tool.response(from: pointDate, through: pointDate, points: [first, second])
        let reversed = try tool.response(from: pointDate, through: pointDate, points: [second, first])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(forward.utf8)) as? [String: Any])
        let days = try XCTUnwrap(object["days"] as? [[String: Any]])

        XCTAssertEqual(forward, reversed)
        XCTAssertEqual(days.count, 1)
        XCTAssertEqual(days.first?["date"] as? String, "2026-03-07")
    }

    func testNoHistoryReportsMissingDataInsteadOfZero() throws {
        let start = Date(timeIntervalSince1970: 1_780_000_000)
        let tool = GetHealthHistoryTool()

        let response = try tool.response(from: start, through: start, points: [])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])

        XCTAssertEqual(object["status"] as? String, "noData")
        XCTAssertTrue((object["message"] as? String)?.contains("缺失不代表零") == true)
        XCTAssertEqual((object["days"] as? [Any])?.count, 0)
    }

    func testHistoryResponsePreservesUnknownAndPartialCoverageWithoutAbsenceOrZero() throws {
        let start = Date(timeIntervalSince1970: 1_780_000_000)
        let baseline = HealthBaseline(readiness: .noData, validDays: 0, median: nil, p10: nil, p90: nil, mad: nil)
        let state = HealthStateV2(
            domains: [
                HealthDomainResult(domain: .sleep, status: .unknown, currentValue: nil, baseline: baseline, evidenceKeys: []),
                HealthDomainResult(domain: .activity, status: .partial, currentValue: 5_600, baseline: baseline, evidenceKeys: ["activity.steps"]),
            ],
            recovery: RecoveryAssessment(
                status: .insufficientEvidence,
                confidence: .low,
                evidence: [],
                recommendedAction: .collectData
            ),
            trainingLoad: TrainingLoadSummary(
                recentSevenDayLoad: 0,
                priorTwentyEightDayAverage: nil,
                ratio: nil,
                readiness: .noData,
                band: .unavailable,
                estimatedWorkoutCount: 0,
                unavailableEffortCount: 0,
                dataCoverage: .unknown
            ),
            tomorrowGuidance: nil
        )

        let response = try GetHealthHistoryTool().response(
            from: start,
            through: start,
            points: [HealthStateHistoryPoint(date: start, state: state)]
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
        let day = try XCTUnwrap((object["days"] as? [[String: Any]])?.first)
        let statuses = try XCTUnwrap(day["domainStatuses"] as? [String: String])
        let observations = try XCTUnwrap(day["observations"] as? [String: Double])

        XCTAssertEqual(object["status"] as? String, "partial")
        XCTAssertEqual(statuses["sleep"], HealthDomainStatus.unknown.rawValue)
        XCTAssertEqual(statuses["activity"], HealthDomainStatus.partial.rawValue)
        XCTAssertEqual(observations["activity.steps"], 5_600)
        XCTAssertFalse(observations.values.contains(0))
        XCTAssertNil(observations["trainingLoad.ratio"])
        XCTAssertEqual(day["trainingLoadCoverage"] as? String, HealthDataCoverage.unknown.rawValue)
        XCTAssertNil(day["trainingLoadBand"])
        XCTAssertNotEqual(object["status"] as? String, "noData")
    }

    func testReadModelHistoryKeepsUnknownHealthKitCoverageTypedWithoutZeroObservations() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let day = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: Date())))
        let schema = Schema(versionedSchema: DensosoSchemaV4.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let projection = HealthProjectionActor(modelContainer: container, calendar: calendar)
        let points = try await projection.healthHistory(from: day, through: day)
        let response = try GetHealthHistoryTool(calendar: calendar).response(
            from: day,
            through: day,
            points: points
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
        let resultDay = try XCTUnwrap((object["days"] as? [[String: Any]])?.first)
        let statuses = try XCTUnwrap(resultDay["domainStatuses"] as? [String: String])
        let observations = try XCTUnwrap(resultDay["observations"] as? [String: Double])

        XCTAssertEqual(object["status"] as? String, "partial")
        XCTAssertEqual(statuses["sleep"], HealthDomainStatus.unknown.rawValue)
        XCTAssertEqual(statuses["activity"], HealthDomainStatus.unknown.rawValue)
        XCTAssertEqual(statuses["body"], HealthDomainStatus.unknown.rawValue)
        XCTAssertEqual(resultDay["trainingLoadCoverage"] as? String, HealthDataCoverage.unknown.rawValue)
        XCTAssertTrue(observations.isEmpty)
        XCTAssertNil(resultDay["trainingLoadBand"])
        XCTAssertFalse(response.contains("trainingLoad.ratio"))
    }

    func testResponseRejectsMoreThanFourteenDaysAndFutureDates() throws {
        let calendar = Calendar.current
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 1)))
        let oversizedEnd = try XCTUnwrap(calendar.date(byAdding: .day, value: 14, to: start))
        let future = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date())))
        let tool = GetHealthHistoryTool(calendar: calendar)

        XCTAssertThrowsError(try tool.response(from: start, through: oversizedEnd, points: []))
        XCTAssertThrowsError(try tool.response(from: future, through: future, points: []))
    }

    private func makeState(
        sleepMinutes: Double = 300,
        duplicateSleepDomain: Bool = false
    ) -> HealthStateV2 {
        let baseline = HealthBaseline(
            readiness: .mature,
            validDays: 28,
            median: 420,
            p10: 360,
            p90: 480,
            mad: 30
        )
        let sleep = HealthDomainResult(
            domain: .sleep,
            status: .attention,
            currentValue: sleepMinutes,
            baseline: baseline,
            evidenceKeys: ["sleep.mainSleep.minutes"]
        )
        let recovery = RecoveryAssessment(
            status: .insufficientEvidence,
            confidence: .low,
            evidence: [EvidenceReference(key: "sleep.mainSleep.minutes", source: "sleep")],
            recommendedAction: .collectData
        )
        let load = TrainingLoadSummary(
            recentSevenDayLoad: 120,
            priorTwentyEightDayAverage: 100,
            ratio: 1.2,
            readiness: .mature,
            band: .increased,
            estimatedWorkoutCount: 3,
            unavailableEffortCount: 1
        )
        return HealthStateV2(
            domains: duplicateSleepDomain ? [sleep, sleep] : [sleep],
            recovery: recovery,
            trainingLoad: load,
            tomorrowGuidance: nil
        )
    }

    private func localDate(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        _ minute: Int,
        calendar: Calendar
    ) throws -> Date {
        try XCTUnwrap(calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        )))
    }
}
