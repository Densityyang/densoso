import DensosoDomain
import Foundation
import SwiftData
import XCTest
@testable import Densoso

@MainActor
final class GetTodayHealthStateToolTests: XCTestCase {
    func testToolReturnsStateAndDeduplicatedEvidenceReferences() throws {
        let expected = makeState()
        let tool = GetTodayHealthStateTool()
        let date = Date(timeIntervalSince1970: 1_800_000_000)

        let response = try tool.response(asOf: date, state: expected)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
        XCTAssertEqual(object["status"] as? String, "available")
        XCTAssertNotNil(object["asOf"] as? String)

        let state = try XCTUnwrap(object["healthState"] as? [String: Any])
        let recovery = try XCTUnwrap(state["recovery"] as? [String: Any])
        XCTAssertEqual(recovery["status"] as? String, "attention")
        let trainingLoad = try XCTUnwrap(state["trainingLoad"] as? [String: Any])
        XCTAssertEqual(trainingLoad["recentSevenDayLoad"] as? Double, 120)

        let references = try XCTUnwrap(object["evidenceReferences"] as? [[String: Any]])
        XCTAssertEqual(references.filter { $0["key"] as? String == "sleep.mainSleep.minutes" }.count, 1)
        XCTAssertTrue(references.contains {
            $0["key"] as? String == "trainingLoad.ratio" && $0["source"] as? String == "trainingLoad"
        })
    }

    func testMissingStateIsExplicitlyUnavailableAndHasNoEvidence() throws {
        let tool = GetTodayHealthStateTool()

        let response = try tool.response(asOf: Date(timeIntervalSince1970: 1_800_000_000), state: nil)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])

        XCTAssertEqual(object["status"] as? String, "unavailable")
        XCTAssertNil(object["healthState"])
        XCTAssertEqual((object["evidenceReferences"] as? [[String: Any]])?.count, 0)
        XCTAssertNotNil(object["message"] as? String)
    }

    func testProviderReadFailurePropagatesInsteadOfReturningUnavailable() async {
        let tool = GetTodayHealthStateTool(stateProvider: { _ in
            throw HealthStateReadTestError.failed
        })

        do {
            _ = try await tool.response(asOf: Date(timeIntervalSince1970: 1_800_000_000))
            XCTFail("Provider read failures must propagate instead of becoming an unavailable response")
        } catch let error as HealthStateReadTestError {
            XCTAssertEqual(error, .failed)
        } catch {
            XCTFail("Unexpected provider error: \(error)")
        }
    }

    func testUnavailableTrainingLoadEncodesMissingRecentLoadAsNull() throws {
        let unavailableLoad = TrainingLoadSummary(
            recentSevenDayLoad: 0,
            priorTwentyEightDayAverage: nil,
            ratio: nil,
            readiness: .noData,
            band: .unavailable,
            estimatedWorkoutCount: 0,
            unavailableEffortCount: 0
        )
        let state = makeState(trainingLoad: unavailableLoad, noData: true)
        let response = try GetTodayHealthStateTool().response(
            asOf: Date(timeIntervalSince1970: 1_800_000_000),
            state: state
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
        let healthState = try XCTUnwrap(object["healthState"] as? [String: Any])
        let trainingLoad = try XCTUnwrap(healthState["trainingLoad"] as? [String: Any])

        XCTAssertEqual(object["status"] as? String, "noData")
        XCTAssertTrue(
            trainingLoad["recentSevenDayLoad"] == nil
                || trainingLoad["recentSevenDayLoad"] is NSNull
        )
        XCTAssertEqual(trainingLoad["band"] as? String, TrainingLoadBand.unavailable.rawValue)
    }

    func testUnknownTrainingLoadOmitsZeroAndDerivedValuesAndReportsCoverage() throws {
        let unknownLoad = TrainingLoadSummary(
            recentSevenDayLoad: 0,
            priorTwentyEightDayAverage: 0,
            ratio: 0,
            readiness: .noData,
            band: .unavailable,
            estimatedWorkoutCount: 0,
            unavailableEffortCount: 0,
            dataCoverage: .unknown
        )
        let response = try GetTodayHealthStateTool().response(
            asOf: Date(timeIntervalSince1970: 1_800_000_000),
            state: makeState(trainingLoad: unknownLoad, unknownCoverage: true)
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
        let healthState = try XCTUnwrap(object["healthState"] as? [String: Any])
        let domains = try XCTUnwrap(healthState["domains"] as? [[String: Any]])
        let trainingLoad = try XCTUnwrap(healthState["trainingLoad"] as? [String: Any])

        XCTAssertEqual(object["status"] as? String, "insufficientEvidence")
        XCTAssertEqual(domains.first?["status"] as? String, HealthDomainStatus.unknown.rawValue)
        XCTAssertEqual(trainingLoad["dataCoverage"] as? String, HealthDataCoverage.unknown.rawValue)
        XCTAssertNil(trainingLoad["recentSevenDayLoad"])
        XCTAssertNil(trainingLoad["priorTwentyEightDayAverage"])
        XCTAssertNil(trainingLoad["ratio"])
        XCTAssertNil(trainingLoad["estimatedWorkoutCount"])
        XCTAssertNil(trainingLoad["unavailableEffortCount"])
    }

    func testPartialEffortCoverageOmitsPlaceholderLoadFromToolJSON() throws {
        let partialLoad = TrainingLoadSummary(
            recentSevenDayLoad: 0,
            priorTwentyEightDayAverage: 525,
            ratio: nil,
            readiness: .mature,
            band: .unavailable,
            estimatedWorkoutCount: 7,
            unavailableEffortCount: 1,
            dataCoverage: .partial
        )
        let response = try GetTodayHealthStateTool().response(
            asOf: Date(timeIntervalSince1970: 1_800_000_000),
            state: makeState(trainingLoad: partialLoad)
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
        let healthState = try XCTUnwrap(object["healthState"] as? [String: Any])
        let trainingLoad = try XCTUnwrap(healthState["trainingLoad"] as? [String: Any])

        XCTAssertEqual(object["status"] as? String, "insufficientEvidence")
        XCTAssertTrue((object["message"] as? String)?.contains("覆盖不完整") == true)
        XCTAssertEqual(trainingLoad["dataCoverage"] as? String, HealthDataCoverage.partial.rawValue)
        XCTAssertNil(trainingLoad["recentSevenDayLoad"])
        XCTAssertNil(trainingLoad["priorTwentyEightDayAverage"])
        XCTAssertNil(trainingLoad["ratio"])
        XCTAssertNil(trainingLoad["estimatedWorkoutCount"])
        XCTAssertNil(trainingLoad["unavailableEffortCount"])
    }

    func testBodyOnlyTrendIncludesAggregateAndCitationButNotMissingMetricCitation() throws {
        let baseline = HealthBaseline(
            readiness: .mature,
            validDays: 28,
            median: 61,
            p10: 58,
            p90: 64,
            mad: 2
        )
        let current = HealthVitalTrend(
            metric: .restingHeartRate,
            latestMedian: 66,
            currentSampleCount: 3,
            baseline: baseline,
            status: .changed,
            evidenceKey: "vitals.restingHeartRate.median"
        )
        let missing = HealthVitalTrend(
            metric: .wristTemperature,
            latestMedian: nil,
            baseline: baseline,
            status: .noData,
            evidenceKey: "vitals.wristTemperature.median"
        )
        let context = HealthNarrativeContext(
            healthState: nil,
            evidence: [],
            recommendationCandidates: [],
            aggregateSummary: nil,
            vitalTrends: [current, missing]
        )

        let response = try GetTodayHealthStateTool().response(
            asOf: Date(timeIntervalSince1970: 1_800_000_000),
            context: context
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
        let trends = try XCTUnwrap(object["vitalTrends"] as? [[String: Any]])
        let references = try XCTUnwrap(object["evidenceReferences"] as? [[String: Any]])

        XCTAssertEqual(object["status"] as? String, "available")
        XCTAssertEqual(trends.count, 2)
        XCTAssertEqual(trends[0]["latestMedian"] as? Double, 66)
        XCTAssertEqual(trends[0]["unit"] as? String, "bpm")
        XCTAssertEqual(trends[0]["sourceProvenance"] as? String, HealthVitalAggregateProvenance.healthKitAggregate.rawValue)
        XCTAssertEqual(trends[0]["currentWindowDays"] as? Int, 1)
        XCTAssertEqual(trends[0]["currentSampleCount"] as? Int, 3)
        XCTAssertEqual((trends[0]["baseline"] as? [String: Any])?["median"] as? Double, 61)
        XCTAssertEqual(trends[0]["baselineWindowDays"] as? Int, 41)
        XCTAssertEqual(trends[0]["robustZScore"] as? Double, 0.6745 * 5 / 2)
        XCTAssertEqual(trends[0]["status"] as? String, HealthDomainStatus.changed.rawValue)
        XCTAssertEqual(trends[0]["dataCoverage"] as? String, HealthDataCoverage.complete.rawValue)
        XCTAssertEqual(trends[0]["evidenceKey"] as? String, "vitals.restingHeartRate.median")
        XCTAssertNil(trends[1]["evidenceKey"])
        XCTAssertEqual(references.count, 1)
        XCTAssertEqual(references.first?["key"] as? String, "vitals.restingHeartRate.median")
    }

    func testActivityTrendsExposePerMetricUnitsCoverageAndOnlyValidEvidence() throws {
        let baseline = HealthBaseline(
            readiness: .mature,
            validDays: 14,
            median: 7_500,
            p10: 6_000,
            p90: 9_000,
            mad: 500
        )
        let context = HealthNarrativeContext(
            healthState: nil,
            evidence: [],
            recommendationCandidates: [],
            aggregateSummary: nil,
            activityTrends: [
                ActivityMetricTrend(
                    metric: .steps,
                    currentValue: 8_123,
                    baselineWindowDays: 28,
                    baseline: baseline,
                    status: .withinTypicalRange,
                    dataCoverage: .complete
                ),
                ActivityMetricTrend(
                    metric: .activeEnergy,
                    currentValue: 430,
                    baselineWindowDays: 14,
                    baseline: baseline,
                    status: .partial,
                    dataCoverage: .partial
                ),
                ActivityMetricTrend(
                    metric: .exerciseMinutes,
                    currentValue: nil,
                    baselineWindowDays: 28,
                    baseline: baseline,
                    status: .unknown,
                    dataCoverage: .unknown
                ),
            ]
        )

        let response = try GetTodayHealthStateTool().response(
            asOf: Date(timeIntervalSince1970: 1_800_000_000),
            context: context
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
        let trends = try XCTUnwrap(object["activityTrends"] as? [[String: Any]])
        let references = try XCTUnwrap(object["evidenceReferences"] as? [[String: Any]])

        XCTAssertEqual(object["status"] as? String, "insufficientEvidence")
        XCTAssertEqual(trends.count, 3)
        XCTAssertEqual(trends[0]["metric"] as? String, HealthActivityMetric.steps.rawValue)
        XCTAssertEqual(trends[0]["unit"] as? String, "steps")
        XCTAssertEqual(trends[0]["currentValue"] as? Double, 8_123)
        XCTAssertEqual(trends[0]["evidenceKey"] as? String, "activity.steps")
        XCTAssertEqual(trends[1]["unit"] as? String, "kcal")
        XCTAssertEqual(trends[1]["dataCoverage"] as? String, HealthDataCoverage.partial.rawValue)
        XCTAssertEqual(trends[2]["dataCoverage"] as? String, HealthDataCoverage.unknown.rawValue)
        XCTAssertNil(trends[2]["currentValue"])
        XCTAssertNil(trends[2]["evidenceKey"])
        XCTAssertEqual(Set(references.compactMap { $0["key"] as? String }), ["activity.steps", "activity.activeEnergy.kcal"])
        XCTAssertTrue(references.allSatisfy { $0["source"] as? String == HealthDomain.activity.rawValue })
    }

    func testSleepOnlyStateIsNotMarkedInsufficientByUnavailableActivityCoverage() throws {
        let baseline = HealthBaseline(
            readiness: .mature,
            validDays: 28,
            median: 420,
            p10: 390,
            p90: 450,
            mad: 15
        )
        let sleep = HealthDomainResult(
            domain: .sleep,
            status: .withinTypicalRange,
            currentValue: 435,
            baseline: baseline,
            evidenceKeys: ["sleep.mainSleep.minutes"]
        )
        let context = HealthNarrativeContext(
            healthState: nil,
            evidence: [EvidenceReference(key: "sleep.mainSleep.minutes", source: "sleep")],
            recommendationCandidates: [],
            aggregateSummary: nil,
            cloudHealthState: CloudHealthStateContext(domains: [sleep])
        )

        let response = try GetTodayHealthStateTool().response(
            asOf: Date(timeIntervalSince1970: 1_800_000_000),
            context: context
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])

        XCTAssertEqual(object["status"] as? String, "available")
        let state = try XCTUnwrap(object["healthState"] as? [String: Any])
        XCTAssertNil(state["trainingLoad"])
        XCTAssertNil(state["recovery"])
        XCTAssertEqual((state["domains"] as? [[String: Any]])?.first?["domain"] as? String, "sleep")
    }

    func testCompleteNoDataTrainingLoadDTODoesNotExposeZeroPlaceholders() throws {
        let payload = #"{"recentSevenDayLoad":0,"priorTwentyEightDayAverage":0,"ratio":0,"readiness":"noData","band":"unavailable","dataCoverage":"complete","estimatedWorkoutCount":0,"unavailableEffortCount":0}"#.data(using: .utf8)!

        let context = try JSONDecoder().decode(HealthTrainingLoadContext.self, from: payload)

        XCTAssertNil(context.recentSevenDayLoad)
        XCTAssertNil(context.priorTwentyEightDayAverage)
        XCTAssertNil(context.ratio)
        XCTAssertNil(context.estimatedWorkoutCount)
        XCTAssertNil(context.unavailableEffortCount)
        XCTAssertEqual(context.band, .unavailable)
        XCTAssertEqual(context.dataCoverage, .complete)
    }

    func testRegistryExposesStrictReadOnlyTool() throws {
        let definition = try XCTUnwrap(
            ToolRegistry().toolDefinitions.first(where: { $0.name == "get_today_health_state" })
        )

        XCTAssertEqual(definition.effect, .readOnly)
        guard case .object(_, let required, let additionalProperties, _) = definition.parameters else {
            return XCTFail("get_today_health_state must use an object schema")
        }
        XCTAssertTrue(required.isEmpty)
        XCTAssertFalse(additionalProperties)
        XCTAssertNoThrow(try ToolSchemaValidator.validate(.object([:]), against: definition.parameters))
        XCTAssertThrowsError(try ToolSchemaValidator.validate(
            .object(["includeRawSamples": .boolean(true)]),
            against: definition.parameters
        ))
    }

    func testModelActorBackedReadDoesNotWriteBriefCaches() async throws {
        let schema = Schema(versionedSchema: DensosoSchemaV4.self)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let projectionActor = HealthProjectionActor(modelContainer: container)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let tool = GetTodayHealthStateTool(stateProvider: { date in
            try await projectionActor.healthNarrativeContext(asOf: date)
        })

        let response = try await tool.response(asOf: date)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
        let context = ModelContext(container)

        XCTAssertEqual(object["status"] as? String, "insufficientEvidence")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DailyBriefRecord>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<WeeklyBriefRecord>()), 0)
    }

    private func makeState(
        trainingLoad: TrainingLoadSummary? = nil,
        noData: Bool = false,
        unknownCoverage: Bool = false
    ) -> HealthStateV2 {
        let hasMissingEvidence = noData || unknownCoverage
        let baseline = HealthBaseline(
            readiness: hasMissingEvidence ? .noData : .mature,
            validDays: hasMissingEvidence ? 0 : 28,
            median: hasMissingEvidence ? nil : 420,
            p10: hasMissingEvidence ? nil : 360,
            p90: hasMissingEvidence ? nil : 480,
            mad: hasMissingEvidence ? nil : 30
        )
        let sleep = HealthDomainResult(
            domain: .sleep,
            status: unknownCoverage ? .unknown : (noData ? .noData : .attention),
            currentValue: hasMissingEvidence ? nil : 300,
            baseline: baseline,
            evidenceKeys: hasMissingEvidence ? [] : ["sleep.mainSleep.minutes"]
        )
        let recovery = RecoveryAssessment(
            status: hasMissingEvidence ? .insufficientEvidence : .attention,
            confidence: hasMissingEvidence ? .low : .medium,
            evidence: hasMissingEvidence ? [] : [
                EvidenceReference(key: "sleep.mainSleep.minutes", source: "sleep"),
                EvidenceReference(key: "trainingLoad.ratio", source: "trainingLoad"),
            ],
            recommendedAction: hasMissingEvidence ? .collectData : .reduceIntensity
        )
        let load = trainingLoad ?? TrainingLoadSummary(
            recentSevenDayLoad: 120,
            priorTwentyEightDayAverage: 100,
            ratio: 1.2,
            readiness: .mature,
            band: .increased,
            estimatedWorkoutCount: 3,
            unavailableEffortCount: 1
        )
        return HealthStateV2(
            domains: [sleep],
            recovery: recovery,
            trainingLoad: load,
            tomorrowGuidance: nil
        )
    }
}

private enum HealthStateReadTestError: Error, Equatable {
    case failed
}
