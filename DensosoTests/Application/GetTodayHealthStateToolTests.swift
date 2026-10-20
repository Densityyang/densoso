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

        XCTAssertEqual(object["status"] as? String, "noData")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DailyBriefRecord>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<WeeklyBriefRecord>()), 0)
    }

    private func makeState(
        trainingLoad: TrainingLoadSummary? = nil,
        noData: Bool = false
    ) -> HealthStateV2 {
        let baseline = HealthBaseline(
            readiness: noData ? .noData : .mature,
            validDays: noData ? 0 : 28,
            median: noData ? nil : 420,
            p10: noData ? nil : 360,
            p90: noData ? nil : 480,
            mad: noData ? nil : 30
        )
        let sleep = HealthDomainResult(
            domain: .sleep,
            status: noData ? .noData : .attention,
            currentValue: noData ? nil : 300,
            baseline: baseline,
            evidenceKeys: noData ? [] : ["sleep.mainSleep.minutes"]
        )
        let recovery = RecoveryAssessment(
            status: noData ? .insufficientEvidence : .attention,
            confidence: noData ? .low : .medium,
            evidence: noData ? [] : [
                EvidenceReference(key: "sleep.mainSleep.minutes", source: "sleep"),
                EvidenceReference(key: "trainingLoad.ratio", source: "trainingLoad"),
            ],
            recommendedAction: noData ? .collectData : .reduceIntensity
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
