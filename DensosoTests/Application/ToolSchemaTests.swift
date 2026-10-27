import DensosoDomain
import Foundation
import XCTest
@testable import Densoso

@MainActor
final class ToolSchemaTests: XCTestCase {
    func testEveryToolUsesClosedObjectSchemaAndLocalEffect() throws {
        let registry = ToolRegistry()
        XCTAssertEqual(registry.toolDefinitions.count, 20)
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
        XCTAssertEqual(registry.effect(for: "get_today_plan"), .readOnly)
        XCTAssertEqual(registry.effect(for: "get_schedule"), .readOnly)
        XCTAssertNil(registry.effect(for: "log_workout"))
    }

    func testSearchFoodIsStrictReadOnlyV2Tool() throws {
        let registry = ToolRegistry()
        let definition = try XCTUnwrap(registry.toolDefinitions.first { $0.name == "search_food" })

        XCTAssertEqual(definition.effect, .readOnly)
        XCTAssertEqual(registry.effect(for: "search_food"), .readOnly)
        XCTAssertNil(registry.effect(for: "query_food"), "Do not expose a duplicate legacy search tool")
        guard case .object(let properties, let required, let additionalProperties, _) = definition.parameters else {
            return XCTFail("search_food must use a strict object")
        }
        XCTAssertEqual(required, ["query"])
        XCTAssertFalse(additionalProperties)
        guard let querySchema = properties["query"],
              case .string(_, _, let minimumQueryLength, let maximumQueryLength, _) = querySchema else {
            return XCTFail("search_food query must be bounded text")
        }
        XCTAssertEqual(minimumQueryLength, 1)
        XCTAssertEqual(maximumQueryLength, SearchFoodTool.maximumQueryLength)

        XCTAssertNoThrow(try ToolSchemaValidator.validate(
            .object(["query": .string("熟米饭"), "preparation": .string("cooked")]),
            against: definition.parameters
        ))
        XCTAssertThrowsError(try ToolSchemaValidator.validate(
            .object(["query": .string("米饭"), "foodID": .string("forged-id")]),
            against: definition.parameters
        ))
    }

    func testSearchFoodUsesV2AxesLimitsTopThreeAndOmitsStorageIdentifiers() throws {
        let tool = SearchFoodTool()
        let entries = [
            searchFoodEntry(
                id: "private-cooked-history-row",
                localFoodID: "private-cooked-history-id",
                name: "rice",
                aliases: ["cooked rice"],
                preparation: .cooked
            ),
            searchFoodEntry(
                id: "private-cooked-row-2",
                localFoodID: "private-cooked-id-2",
                name: "rice",
                aliases: ["cooked rice", "brown rice"],
                preparation: .cooked
            ),
            searchFoodEntry(
                id: "private-cooked-row-3",
                localFoodID: "private-cooked-id-3",
                name: "rice",
                aliases: ["cooked rice", "white rice"],
                preparation: .cooked
            ),
            searchFoodEntry(
                id: "private-raw-row",
                localFoodID: "private-raw-id",
                name: "rice",
                aliases: ["raw rice"],
                preparation: .raw
            ),
        ]

        let resolution = tool.resolve(
            query: "cooked rice",
            preparation: .cooked,
            massBasis: .cooked,
            categoryHint: "grain",
            confirmedFoodHistoryIDs: ["private-cooked-history-id"],
            catalog: entries
        )
        XCTAssertEqual(resolution.candidates.count, 3)
        XCTAssertEqual(resolution.candidates.first?.entry.id, "private-cooked-history-row")
        XCTAssertEqual(resolution.candidates.first?.score.preparation, 1)
        XCTAssertEqual(resolution.candidates.first?.score.massBasis, 1)
        XCTAssertEqual(resolution.candidates.first?.score.category, 1)
        XCTAssertEqual(resolution.candidates.first?.score.history, 1)
        XCTAssertEqual(resolution.candidates.first?.score.alias, 1)
        XCTAssertFalse(resolution.candidates.contains { $0.entry.preparation == .raw })
        XCTAssertNil(resolution.autoPreselect, "Similar candidates must stay unresolved")
        XCTAssertTrue(resolution.requiresConfirmation)

        let response = try tool.response(query: "cooked rice", resolution: resolution)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
        let candidates = try XCTUnwrap(object["candidates"] as? [[String: Any]])
        let first = try XCTUnwrap(candidates.first)
        let score = try XCTUnwrap(first["score"] as? [String: Any])
        XCTAssertEqual(candidates.count, 3)
        XCTAssertEqual(object["requiresConfirmation"] as? Bool, true)
        XCTAssertNil(object["autoPreselectCandidate"] as? String)
        for axis in ["lexical", "alias", "preparation", "massBasis", "category", "history", "evidence", "finalScore"] {
            XCTAssertNotNil(score[axis])
        }
        XCTAssertFalse(response.contains("private-cooked-history-row"))
        XCTAssertFalse(response.contains("private-cooked-history-id"))
        XCTAssertFalse(response.contains("\"id\""))
    }

    func testGetTodayPlanHasEmptyStrictReadOnlySchema() throws {
        let registry = ToolRegistry()
        let definition = try XCTUnwrap(registry.toolDefinitions.first { $0.name == "get_today_plan" })

        XCTAssertEqual(definition.effect, .readOnly)
        guard case .object(let properties, let required, let additionalProperties, _) = definition.parameters else {
            return XCTFail("get_today_plan must use an object schema")
        }
        XCTAssertTrue(properties.isEmpty)
        XCTAssertTrue(required.isEmpty)
        XCTAssertFalse(additionalProperties)
        XCTAssertNoThrow(try ToolSchemaValidator.validate(.object([:]), against: definition.parameters))
        XCTAssertThrowsError(try ToolSchemaValidator.validate(
            .object(["date": .string("2026-10-19T00:00:00Z")]),
            against: definition.parameters
        ))
    }

    func testGetTodayPlanResponseUsesLocalDayAndBoundsEntries() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let tool = GetTodayPlanTool(calendar: calendar)
        let asOf = Date(timeIntervalSince1970: 0)
        let items = (0..<25).reversed().map { index in
            AgentScheduleItem(
                title: "Plan \(index)",
                startTime: Date(timeIntervalSince1970: Double(index * 60)),
                endTime: nil,
                notes: String(repeating: "routine ", count: 60)
            )
        }

        let response = try tool.response(asOf: asOf, items: items)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
        let plans = try XCTUnwrap(object["plans"] as? [[String: Any]])

        XCTAssertEqual(object["status"] as? String, "available")
        XCTAssertEqual(object["localDate"] as? String, "1970-01-01")
        XCTAssertEqual(object["count"] as? Int, GetTodayPlanTool.maximumEvents)
        XCTAssertEqual(object["hasMore"] as? Bool, true)
        XCTAssertEqual(plans.first?["title"] as? String, "Plan 0")
        XCTAssertLessThanOrEqual((plans.first?["summary"] as? String)?.count ?? 0, 80)
        XCTAssertLessThanOrEqual(response.utf8.count, 8_192)
        XCTAssertFalse(response.contains("storageID"))
        XCTAssertFalse(response.contains("notesPrefix"))
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
                            "quantityEvidence": .object([
                                "kind": .string("exactGrams"),
                                "value": .number(150),
                                "unit": .string("g"),
                                "gramsPerServing": .null,
                            ]),
                        ])
                    ]),
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

        var legacyAmount = valid.objectValue!
        var legacyDishes = legacyAmount["dishes"]!.arrayValue!
        var legacyDish = legacyDishes[0].objectValue!
        var legacyIngredients = legacyDish["ingredients"]!.arrayValue!
        var legacyIngredient = legacyIngredients[0].objectValue!
        legacyIngredient["amountGrams"] = .number(150)
        legacyIngredients[0] = .object(legacyIngredient)
        legacyDish["ingredients"] = .array(legacyIngredients)
        legacyDishes[0] = .object(legacyDish)
        legacyAmount["dishes"] = .array(legacyDishes)
        XCTAssertThrowsError(
            try ToolSchemaValidator.validate(.object(legacyAmount), against: schema)
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

    private func searchFoodEntry(
        id: String,
        localFoodID: String,
        name: String,
        aliases: [String],
        preparation: FoodPreparation
    ) -> FoodCatalogEntry {
        FoodCatalogEntry(
            id: id,
            localFoodID: localFoodID,
            name: name,
            aliases: aliases,
            preparation: preparation,
            category: "grain",
            edibleFraction: 1,
            nutrients: FoodNutrientProfile(
                energyKcalPer100Grams: 130,
                proteinGramsPer100Grams: 2.5,
                fatGramsPer100Grams: 0.4,
                carbohydrateGramsPer100Grams: 28
            ),
            sourceVersion: "search-food-fixture-v2"
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
