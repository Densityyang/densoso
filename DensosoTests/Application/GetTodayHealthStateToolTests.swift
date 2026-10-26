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
            try await projectionActor.todayHealthState(asOf: date)
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
