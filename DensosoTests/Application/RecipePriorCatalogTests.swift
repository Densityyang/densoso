import Foundation
import XCTest
@testable import Densoso

@MainActor
final class RecipePriorCatalogTests: XCTestCase {
    func testBundledCatalogParsesProductionResourceEnvelope() throws {
        let catalog = try RecipePriorCatalog.bundled(bundle: .main)

        XCTAssertEqual(catalog.source.sourceID, "anduin-howtocook")
        XCTAssertEqual(catalog.source.sourceVersion, "5fb3140c20b2a713296696dc6fdd3b83ccc617a6")
        XCTAssertEqual(catalog.source.licenseSPDX, "Unlicense")
        XCTAssertEqual(catalog.matches("咖喱炒蟹").first?.kind, .exact)
    }

    func testCatalogRequiresVerifiedRedistributableRecipeSource() throws {
        let catalog = try RecipePriorCatalog(data: fixtureData())

        XCTAssertEqual(catalog.source.dataRole, "recipe-prior")
        XCTAssertEqual(catalog.source.licenseSPDX, "Unlicense")
        XCTAssertTrue(catalog.source.redistributionAllowed)
        XCTAssertEqual(catalog.matches("番茄炒蛋").first?.kind, .exact)
        XCTAssertEqual(catalog.matches("炒蛋").first?.kind, .partial)
        XCTAssertTrue(catalog.matches("咖喱牛肉").isEmpty)
    }

    func testRecipePriorToolReturnsSourceQuantitiesWithoutNutritionClaims() throws {
        let catalog = try RecipePriorCatalog(data: fixtureData())
        let result = GetRecipePriorTool(catalog: catalog).response(
            dishName: "番茄炒蛋",
            catalog: catalog
        )
        let data = try XCTUnwrap(result.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["status"] as? String, "available")
        XCTAssertEqual(object["dataRole"] as? String, "recipe-prior")
        XCTAssertEqual(object["nutritionAuthority"] as? Bool, false)
        let results = try XCTUnwrap(object["results"] as? [[String: Any]])
        let recipe = try XCTUnwrap(results.first)
        XCTAssertEqual(recipe["matchType"] as? String, "exact")
        XCTAssertEqual(recipe["id"] as? String, "anduin-howtocook:dishes/vegetable_dish/番茄炒蛋.md")
        XCTAssertEqual(recipe["sourceRecordID"] as? String, "dishes/vegetable_dish/番茄炒蛋.md")
        XCTAssertEqual(recipe["sourceVersion"] as? String, "5fb3140c20b2a713296696dc6fdd3b83ccc617a6")
        XCTAssertEqual(recipe["sourceRecordSHA256"] as? String, String(repeating: "a", count: 64))
        XCTAssertEqual(recipe["licenseStatus"] as? String, "verified")
        XCTAssertNotNil(recipe["cookedYieldEvidence"] as? [String: Any])
        XCTAssertNotNil(recipe["householdMeasures"] as? [String])
        XCTAssertNotNil(recipe["oilRetention"] as? [String: Any])
        let ingredients = try XCTUnwrap(recipe["ingredients"] as? [[String: Any]])
        let tomatoQuantity = try XCTUnwrap(ingredients.first?["quantityEvidence"] as? [String: Any])
        XCTAssertEqual(tomatoQuantity["sourceText"] as? String, "1个（约180g）*份数")
        XCTAssertFalse(result.localizedCaseInsensitiveContains("kcal"))
        XCTAssertFalse(result.contains("energyKcal"))
    }

    func testRecipeIDMustResolveToAnExactLocalDishMatch() throws {
        let catalog = try RecipePriorCatalog(data: fixtureData())
        let recipeID = "anduin-howtocook:dishes/vegetable_dish/番茄炒蛋.md"

        XCTAssertEqual(catalog.source.sourceVersion, RecipePriorCatalog.pinnedSourceVersion)
        XCTAssertEqual(catalog.exactRecord(dishName: "番茄炒蛋", id: recipeID)?.id, recipeID)
        XCTAssertNil(catalog.exactRecord(dishName: "番茄炒蛋盖饭", id: recipeID))
        XCTAssertNil(catalog.exactRecord(dishName: "番茄炒蛋", id: "unbundled:recipe"))
    }

    func testRecipePriorToolIsRegisteredAsReadOnlyWithStrictArguments() throws {
        let registry = ToolRegistry()
        let tool = GetRecipePriorTool()

        XCTAssertEqual(tool.definition.name, "get_recipe_prior")
        XCTAssertEqual(registry.effect(for: "get_recipe_prior"), .readOnly)
        XCTAssertThrowsError(try ToolSchemaValidator.validate(
            .object(["dishName": .string("番茄炒蛋"), "extra": .boolean(true)]),
            against: tool.definition.parameters
        ))
    }

    private func fixtureData() throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "dataRole": "recipe-prior",
            "source": [
                "sourceID": "anduin-howtocook",
                "sourceURL": "https://github.com/Anduin2017/HowToCook",
                "sourceVersion": "5fb3140c20b2a713296696dc6fdd3b83ccc617a6",
                "retrievedAt": "2026-10-26T07:17:41Z",
                "licenseSPDX": "Unlicense",
                "dataRole": "recipe-prior",
                "redistributionAllowed": true,
                "verificationStatus": "verified",
                "licenseURL": "https://github.com/Anduin2017/HowToCook/blob/5fb3140c20b2a713296696dc6fdd3b83ccc617a6/LICENSE",
                "notes": "Non-nutrition recipe prior.",
            ],
            "recipes": [[
                "id": "anduin-howtocook:dishes/vegetable_dish/番茄炒蛋.md",
                "canonicalDishName": "番茄炒蛋",
                "aliases": [],
                "category": "vegetable",
                "cookingMethod": "stirFry",
                "cookingMethodEvidence": "dish-title:番茄炒蛋",
                "ingredients": [[
                    "sourceName": "番茄",
                    "isOptional": false,
                    "isAlternative": false,
                    "quantityEvidence": [
                        "kind": "formula",
                        "sourceText": "1个（约180g）*份数",
                        "value": 1,
                        "upperValue": NSNull(),
                        "unit": "个",
                    ],
                ], [
                    "sourceName": "鸡蛋",
                    "isOptional": false,
                    "isAlternative": false,
                    "quantityEvidence": [
                        "kind": "sourceQuantity",
                        "sourceText": "2个",
                        "value": 2,
                        "upperValue": NSNull(),
                        "unit": "个",
                    ],
                ]],
                "servingsSourceText": "一份正好够 1 个人食用",
                "cookedYieldEvidence": ["kind": "notSpecifiedInSource", "sourceText": NSNull()],
                "householdMeasures": [],
                "oilRetention": ["kind": "notSpecifiedInSource", "sourceText": NSNull()],
                "sourceID": "anduin-howtocook",
                "sourceRecordID": "dishes/vegetable_dish/番茄炒蛋.md",
                "sourceVersion": "5fb3140c20b2a713296696dc6fdd3b83ccc617a6",
                "licenseStatus": "verified",
                "licenseSPDX": "Unlicense",
                "confidenceGrade": "moderate",
                "sourceRecordSHA256": String(repeating: "a", count: 64),
                "isNutritionAuthority": false,
            ]],
        ], options: [.fragmentsAllowed, .sortedKeys])
    }
}
