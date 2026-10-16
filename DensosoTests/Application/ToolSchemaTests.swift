import DensosoDomain
import Foundation
import XCTest
@testable import Densoso

@MainActor
final class ToolSchemaTests: XCTestCase {
    func testEveryToolUsesClosedObjectSchemaAndLocalEffect() throws {
        let registry = ToolRegistry()
        XCTAssertEqual(registry.toolDefinitions.count, 18)
        for tool in registry.toolDefinitions {
            guard case .object(_, _, let additionalProperties, _) = tool.parameters else {
                return XCTFail("\(tool.name) must use an object schema")
            }
            XCTAssertFalse(additionalProperties)
            XCTAssertEqual(registry.effect(for: tool.name), tool.effect)
        }
        XCTAssertEqual(registry.effect(for: "log_meal"), .stagesAction)
        XCTAssertEqual(registry.effect(for: "log_weight"), .stagesAction)
        XCTAssertEqual(registry.effect(for: "create_workout_plan"), .stagesAction)
        XCTAssertEqual(registry.effect(for: "create_training_plan"), .stagesAction)
        XCTAssertEqual(registry.effect(for: "stage_daily_checkin"), .stagesAction)
        XCTAssertEqual(registry.effect(for: "stage_user_preference"), .stagesAction)
        XCTAssertEqual(registry.effect(for: "get_pending_actions"), .readOnly)
        XCTAssertEqual(registry.effect(for: "get_recent_meals"), .readOnly)
        XCTAssertEqual(registry.effect(for: "get_recent_workouts"), .readOnly)
        XCTAssertEqual(registry.effect(for: "get_goal"), .readOnly)
        XCTAssertEqual(registry.effect(for: "get_user_preferences"), .readOnly)
        XCTAssertNil(registry.effect(for: "log_workout"))
    }

    func testPendingActionsToolOnlyReturnsUnexpiredUncommittedSummaries() throws {
        let tool = GetPendingActionsTool()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let pending = makePendingAction(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000901")!,
            key: "private-idempotency-key",
            createdAt: now.addingTimeInterval(-60),
            expiresAt: now.addingTimeInterval(3_600),
            state: .pending
        )
        let committing = makePendingAction(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000902")!,
            key: "another-private-key",
            createdAt: now.addingTimeInterval(-120),
            expiresAt: now.addingTimeInterval(3_600),
            state: .committing
        )
        let expired = makePendingAction(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000903")!,
            key: "expired-private-key",
            createdAt: now.addingTimeInterval(-3_600),
            expiresAt: now.addingTimeInterval(-1),
            state: .pending
        )
        let committed = makePendingAction(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000904")!,
            key: "committed-private-key",
            createdAt: now.addingTimeInterval(-30),
            expiresAt: now.addingTimeInterval(3_600),
            state: .committed
        )

        let response = try tool.response(actions: [pending, expired, committed, committing], asOf: now)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
        let actions = try XCTUnwrap(object["actions"] as? [[String: Any]])

        XCTAssertEqual(object["status"] as? String, "available")
        XCTAssertEqual(object["count"] as? Int, 2)
        XCTAssertEqual(object["hasMore"] as? Bool, false)
        XCTAssertEqual(actions.count, 2)
        XCTAssertEqual(actions.compactMap { $0["actionID"] as? String }, [
            committing.id.uuidString.lowercased(),
            pending.id.uuidString.lowercased(),
        ])
        XCTAssertFalse(response.contains("idempotencyKey"))
        XCTAssertFalse(response.contains("private-idempotency-key"))
        XCTAssertFalse(response.contains("clientRequestID"))
    }

    func testPendingActionsToolBoundsResultsAndReportsRemainingActions() throws {
        let tool = GetPendingActionsTool()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let actions = (0..<25).map { index in
            makePendingAction(
                id: UUID(),
                key: "private-key-\(index)",
                createdAt: now.addingTimeInterval(Double(index)),
                expiresAt: now.addingTimeInterval(3_600),
                state: .pending
            )
        }

        let response = try tool.response(actions: actions, asOf: now)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])

        XCTAssertLessThan(response.count, 8_192)
        XCTAssertEqual(object["count"] as? Int, 20)
        XCTAssertEqual(object["hasMore"] as? Bool, true)
    }

    func testPendingActionsToolAcceptsOnlyAnEmptyReadOnlyRequest() throws {
        let definition = GetPendingActionsTool().definition
        XCTAssertEqual(definition.effect, .readOnly)
        guard case .object(_, let required, let additionalProperties, _) = definition.parameters else {
            return XCTFail("get_pending_actions must use an object schema")
        }
        XCTAssertTrue(required.isEmpty)
        XCTAssertFalse(additionalProperties)
        XCTAssertNoThrow(try ToolSchemaValidator.validate(.object([:]), against: definition.parameters))
        XCTAssertThrowsError(try ToolSchemaValidator.validate(
            .object(["confirm": .boolean(true)]),
            against: definition.parameters
        ))
    }

    func testLogMealRequiresRealNestedArrays() throws {
        let schema = LogMealTool().definition.parameters
        let valid: JSONValue = .object([
            "mealType": .string("lunch"),
            "occurredAt": .null,
            "dishes": .array([
                .object([
                    "dishName": .string("米饭"),
                    "cookingMethod": .string("boil"),
                    "ingredients": .array([
                        .object([
                            "name": .string("米饭"),
                            "amountGrams": .number(150),
                        ])
                    ]),
                    "notedOilG": .null,
                    "lowConfidence": .boolean(false),
                ])
            ]),
            "note": .null,
        ])
        XCTAssertNoThrow(try ToolSchemaValidator.validate(valid, against: schema))

        var stringified = valid.objectValue!
        stringified["dishes"] = .string("[]")
        XCTAssertThrowsError(
            try ToolSchemaValidator.validate(.object(stringified), against: schema)
        )

        var extra = valid.objectValue!
        extra["skipConfirmation"] = .boolean(true)
        XCTAssertThrowsError(try ToolSchemaValidator.validate(.object(extra), against: schema))
    }

    func testCreateTrainingPlanUsesBoundedStructuredWorkoutAndRestDays() throws {
        let registry = ToolRegistry()
        let definition = try XCTUnwrap(
            registry.toolDefinitions.first(where: { $0.name == "create_training_plan" })
        )
        XCTAssertEqual(definition.effect, .stagesAction)
        let valid: JSONValue = .object([
            "name": .string("轻松计划"),
            "sessions": .array([
                .object([
                    "date": .string("2027-01-01T18:00:00Z"),
                    "activity": .string("walking"),
                    "goalType": .string("time"),
                    "durationMinutes": .integer(30),
                    "distanceMeters": .null,
                    "location": .string("outdoor"),
                    "recommendedIntensity": .string("easy"),
                    "reason": .string("以轻松步行保持活动。"),
                ]),
                .object([
                    "date": .string("2027-01-02T00:00:00Z"),
                    "activity": .string("rest"),
                    "goalType": .null,
                    "durationMinutes": .null,
                    "distanceMeters": .null,
                    "location": .null,
                    "recommendedIntensity": .null,
                    "reason": .string("安排休息。"),
                ]),
            ]),
        ])
        XCTAssertNoThrow(try ToolSchemaValidator.validate(valid, against: definition.parameters))

        var invalid = valid.objectValue!
        guard case .array(var sessions) = invalid["sessions"],
              case .object(var first) = sessions[0] else {
            return XCTFail("training plan should contain structured sessions")
        }
        first["skipConfirmation"] = .boolean(true)
        sessions[0] = .object(first)
        invalid["sessions"] = .array(sessions)
        XCTAssertThrowsError(try ToolSchemaValidator.validate(.object(invalid), against: definition.parameters))
    }

    func testMissingAndOutOfRangeArgumentsFailLocally() {
        let weightSchema = LogWeightTool().definition.parameters
        XCTAssertThrowsError(
            try ToolSchemaValidator.validate(
                .object(["kilograms": .number(62.5)]),
                against: weightSchema
            )
        )
        XCTAssertThrowsError(
            try ToolSchemaValidator.validate(
                .object(["kilograms": .number(900), "measuredAt": .null]),
                against: weightSchema
            )
        )
    }

    private func makePendingAction(
        id: UUID,
        key: String,
        createdAt: Date,
        expiresAt: Date,
        state: PendingActionState
    ) -> PendingAction {
        PendingAction(
            id: id,
            idempotencyKey: key,
            clientRequestID: UUID(),
            createdAt: createdAt,
            expiresAt: expiresAt,
            payload: .weight(WeightDraft(measuredAt: createdAt, kilograms: 62.5)),
            state: state
        )
    }
}
