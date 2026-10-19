import DensosoDomain
import Foundation
import SwiftData
import XCTest
@testable import Densoso

@MainActor
final class GetGoalToolTests: XCTestCase {
    func testToolUsesStrictEmptyReadOnlySchema() throws {
        let definition = GetGoalTool().definition
        XCTAssertEqual(definition.name, "get_goal")
        XCTAssertEqual(definition.effect, .readOnly)
        guard case .object(_, let required, let additionalProperties, _) = definition.parameters else {
            return XCTFail("get_goal must use an object schema")
        }
        XCTAssertTrue(required.isEmpty)
        XCTAssertFalse(additionalProperties)
        XCTAssertNoThrow(try ToolSchemaValidator.validate(.object([:]), against: definition.parameters))
        XCTAssertThrowsError(try ToolSchemaValidator.validate(
            .object(["targetWeightKilograms": .number(70)]),
            against: definition.parameters
        ))
    }

    func testMissingOrEmptyGoalsReturnUnavailableWithoutDefaults() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let missingTool = GetGoalTool()
        let missing = try jsonObject(missingTool.response(asOf: date, profile: nil))
        XCTAssertEqual(missing["status"] as? String, "unavailable")
        XCTAssertNil(missing["goal"])

        let emptyTool = GetGoalTool()
        let empty = try jsonObject(emptyTool.response(asOf: date, profile: GoalProfile(effectiveFrom: date)))
        XCTAssertEqual(empty["status"] as? String, "unavailable")
        XCTAssertNil(empty["goal"])
        XCTAssertFalse(String(data: try JSONSerialization.data(withJSONObject: empty), encoding: .utf8)!
            .contains("dailyDeficitKcal"))
    }

    func testModelActorReturnsOnlyCurrentEffectiveGoalAndReadDoesNotWrite() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let asOf = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 16, hour: 12)))
        let schema = Schema(versionedSchema: DensosoSchemaV4.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        let record = GoalProfileRecord(
            targetWeightKilograms: 68,
            dailyDeficitKcal: 400,
            dailyProteinGrams: 90,
            effectiveFrom: asOf.addingTimeInterval(86_400)
        )
        context.insert(record)
        try context.save()
        let projectionActor = HealthProjectionActor(modelContainer: container, calendar: calendar)
        let tool = GetGoalTool(calendar: calendar, goalProvider: { date in
            try await projectionActor.goalProfile(asOf: date)
        })
        let beforeCount = try context.fetchCount(FetchDescriptor<GoalProfileRecord>())

        let future = try jsonObject(try await tool.response(asOf: asOf))
        XCTAssertEqual(future["status"] as? String, "unavailable")
        XCTAssertNil(future["goal"])

        record.effectiveFrom = asOf.addingTimeInterval(-86_400)
        try context.save()
        let current = try jsonObject(try await tool.response(asOf: asOf))
        XCTAssertEqual(current["status"] as? String, "available")
        XCTAssertEqual(current["asOf"] as? String, "2026-10-16")
        let goal = try XCTUnwrap(current["goal"] as? [String: Any])
        XCTAssertEqual(goal["effectiveFrom"] as? String, "2026-10-15")
        XCTAssertEqual(goal["targetWeightKilograms"] as? Double, 68)
        XCTAssertEqual(goal["dailyDeficitKcal"] as? Int, 400)
        XCTAssertEqual(goal["dailyProteinGrams"] as? Double, 90)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<GoalProfileRecord>()), beforeCount)
    }

    private func jsonObject(_ string: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any])
    }
}
