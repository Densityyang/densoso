import XCTest
@testable import Densoso

@MainActor
final class ToolSchemaTests: XCTestCase {
    func testEveryToolUsesClosedObjectSchemaAndLocalEffect() throws {
        let registry = ToolRegistry()
        XCTAssertEqual(registry.toolDefinitions.count, 8)
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
        XCTAssertNil(registry.effect(for: "log_workout"))
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
}
