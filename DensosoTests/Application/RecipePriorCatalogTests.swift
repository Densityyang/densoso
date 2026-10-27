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

    func testBundledRecipeMappingsUseOnlyVerifiedRedistributableFoodIDs() throws {
        let catalogURL = try XCTUnwrap(Bundle.main.url(forResource: "recipe_priors", withExtension: "json"))
        let foodIDsURL = try XCTUnwrap(Bundle.main.url(forResource: "verified_food_ids", withExtension: "json"))
        let foodRecordsURL = try XCTUnwrap(Bundle.main.url(forResource: "verified_food_records", withExtension: "json"))
        let sourcesURL = try XCTUnwrap(Bundle.main.url(forResource: "sources", withExtension: "json"))
        let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [String: Any])
        let recipes = try XCTUnwrap(catalog["recipes"] as? [[String: Any]])
        let verifiedIDsManifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: foodIDsURL)) as? [String: Any])
        let verifiedFoodIDList = try XCTUnwrap(verifiedIDsManifest["foodIDs"] as? [NSNumber]).map(\.int64Value)
        let verifiedFoodIDs = Set(verifiedFoodIDList)
        let verifiedFoodRecordsFile = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: foodRecordsURL)) as? [String: Any])
        let verifiedFoodRecords = try XCTUnwrap(verifiedFoodRecordsFile["records"] as? [[String: Any]])
        let foodRecordByID = Dictionary(uniqueKeysWithValues: try verifiedFoodRecords.map { record in
            (try XCTUnwrap((record["id"] as? NSNumber)?.int64Value), record)
        })
        let recordIDList = try verifiedFoodRecords.map { record in
            try XCTUnwrap((record["id"] as? NSNumber)?.int64Value)
        }
        let sources = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: sourcesURL)) as? [String: Any])
        let sourceRows = try XCTUnwrap(sources["sources"] as? [[String: Any]])
        let eligibleSourceIDs = Set(sourceRows.compactMap { source -> String? in
            guard source["verificationStatus"] as? String == "verified",
                  source["dataRole"] as? String == "food-composition",
                  source["redistributionAllowed"] as? Bool == true,
                  let spdx = source["licenseSPDX"] as? String,
                  !spdx.isEmpty,
                  let licenseURL = source["licenseURL"] as? String,
                  !licenseURL.isEmpty else {
                return nil
            }
            return source["sourceID"] as? String
        })
        let mappedIngredients = recipes.flatMap { recipe in
            (recipe["ingredients"] as? [[String: Any]] ?? []).compactMap { ingredient in
                (ingredient["foodID"] as? NSNumber).map { (ingredient, $0.int64Value) }
            }
        }
        let mappedFoodIDs = Set(mappedIngredients.map { $0.1 })

        XCTAssertFalse(mappedIngredients.isEmpty)
        XCTAssertEqual(verifiedFoodIDList, recordIDList)
        XCTAssertEqual(verifiedFoodRecords.count, verifiedFoodIDs.count)
        XCTAssertEqual(Set(foodRecordByID.keys), verifiedFoodIDs)
        XCTAssertTrue(mappedFoodIDs.isSubset(of: verifiedFoodIDs))
        XCTAssertTrue(mappedIngredients.allSatisfy { entry in
            let ingredient = entry.0
            guard let evidence = ingredient["edibleFractionEvidence"] as? [String: Any],
                  let sourceID = evidence["sourceID"] as? String,
                  let foodRecord = foodRecordByID[entry.1],
                  (evidence["foodID"] as? NSNumber)?.int64Value == entry.1,
                  let fraction = (evidence["fraction"] as? NSNumber)?.doubleValue,
                  let edible = (foodRecord["edible"] as? NSNumber)?.doubleValue,
                  let sourceRow = sourceRows.first(where: { $0["sourceID"] as? String == sourceID }) else {
                return false
            }
            return evidence["licenseStatus"] as? String == "verified"
                && evidence["redistributionAllowed"] as? Bool == true
                && eligibleSourceIDs.contains(sourceID)
                && foodRecord["sourceID"] as? String == sourceID
                && evidence["sourceRecordID"] as? String == foodRecord["sourceRecordID"] as? String
                && evidence["sourceVersion"] as? String == foodRecord["sourceVersion"] as? String
                && evidence["licenseSPDX"] as? String == foodRecord["licenseSPDX"] as? String
                && foodRecord["dataRole"] as? String == "food-composition"
                && foodRecord["sourceDataType"] as? String == sourceRow["dataType"] as? String
                && foodRecord["sourceVersion"] as? String == sourceRow["sourceVersion"] as? String
                && foodRecord["licenseSPDX"] as? String == sourceRow["licenseSPDX"] as? String
                && foodRecord["redistributionAllowed"] as? Bool == true
                && abs(fraction - edible / 100.0) <= 1e-12
        })
    }

    func testCatalogRequiresVerifiedRedistributableRecipeSource() throws {
        let catalog = try fixtureCatalog()

        XCTAssertEqual(catalog.source.dataRole, "recipe-prior")
        XCTAssertEqual(catalog.source.licenseSPDX, "Unlicense")
        XCTAssertTrue(catalog.source.redistributionAllowed)
        XCTAssertEqual(catalog.matches("番茄炒蛋").first?.kind, .exact)
        XCTAssertEqual(catalog.matches("炒蛋").first?.kind, .partial)
        XCTAssertTrue(catalog.matches("咖喱牛肉").isEmpty)
    }

    func testRecipePriorToolReturnsSourceQuantitiesWithoutNutritionClaims() throws {
        let catalog = try fixtureCatalog()
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
        XCTAssertTrue(recipe["cuisineRegion"] is NSNull)
        XCTAssertEqual(recipe["sourceRecordSHA256"] as? String, String(repeating: "a", count: 64))
        XCTAssertEqual(recipe["licenseStatus"] as? String, "verified")
        XCTAssertNotNil(recipe["cookedYieldEvidence"] as? [String: Any])
        XCTAssertNotNil(recipe["householdMeasures"] as? [String])
        XCTAssertNotNil(recipe["oilRetention"] as? [String: Any])
        let ingredients = try XCTUnwrap(recipe["ingredients"] as? [[String: Any]])
        XCTAssertEqual(ingredients.first?["foodID"] as? Int, 101)
        XCTAssertEqual(
            (ingredients.first?["sourceProvenance"] as? [String: Any])?["sourceRecordID"] as? String,
            "dishes/vegetable_dish/番茄炒蛋.md"
        )
        let tomatoQuantity = try XCTUnwrap(ingredients.first?["quantityEvidence"] as? [String: Any])
        XCTAssertEqual(tomatoQuantity["sourceText"] as? String, "1个（约180g）*份数")
        XCTAssertFalse(result.localizedCaseInsensitiveContains("kcal"))
        XCTAssertFalse(result.contains("energyKcal"))
    }

    func testRecipeIDMustResolveToAnExactLocalDishMatch() throws {
        let catalog = try fixtureCatalog()
        let recipeID = "anduin-howtocook:dishes/vegetable_dish/番茄炒蛋.md"

        XCTAssertEqual(catalog.source.sourceVersion, RecipePriorCatalog.pinnedSourceVersion)
        XCTAssertEqual(catalog.exactRecord(dishName: "番茄炒蛋", id: recipeID)?.id, recipeID)
        XCTAssertNil(catalog.exactRecord(dishName: "番茄炒蛋盖饭", id: recipeID))
        XCTAssertNil(catalog.exactRecord(dishName: "番茄炒蛋", id: "unbundled:recipe"))
    }

    func testCatalogRejectsFoodIDsMissingFromTheBundledFoodSet() throws {
        XCTAssertThrowsError(try fixtureCatalog(validFoodIDs: [101]))
    }

    func testCatalogRejectsIngredientRowsWithoutSourceProvenance() throws {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: fixtureData()) as? [String: Any])
        var changed = object
        var recipes = try XCTUnwrap(changed["recipes"] as? [[String: Any]])
        var recipe = try XCTUnwrap(recipes.first)
        var ingredients = try XCTUnwrap(recipe["ingredients"] as? [[String: Any]])
        var ingredient = try XCTUnwrap(ingredients.first)
        ingredient.removeValue(forKey: "sourceProvenance")
        ingredients[0] = ingredient
        recipe["ingredients"] = ingredients
        recipes[0] = recipe
        changed["recipes"] = recipes
        let malformedData = try JSONSerialization.data(withJSONObject: changed, options: [.fragmentsAllowed])

        XCTAssertThrowsError(try fixtureCatalog(data: malformedData))
    }

    func testCatalogRejectsUnverifiedIngredientFoodLicenseEvidence() throws {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: fixtureData()) as? [String: Any])
        var changed = object
        var recipes = try XCTUnwrap(changed["recipes"] as? [[String: Any]])
        var recipe = try XCTUnwrap(recipes.first)
        var ingredients = try XCTUnwrap(recipe["ingredients"] as? [[String: Any]])
        var ingredient = try XCTUnwrap(ingredients.first)
        var edibleEvidence = try XCTUnwrap(ingredient["edibleFractionEvidence"] as? [String: Any])
        edibleEvidence["licenseStatus"] = "unverified"
        ingredient["edibleFractionEvidence"] = edibleEvidence
        ingredients[0] = ingredient
        recipe["ingredients"] = ingredients
        recipes[0] = recipe
        changed["recipes"] = recipes
        let malformedData = try JSONSerialization.data(withJSONObject: changed, options: [.fragmentsAllowed])

        XCTAssertThrowsError(try fixtureCatalog(data: malformedData))
    }

    func testCatalogRejectsFoodEvidenceThatDoesNotMatchTheVerifiedSourceRecord() throws {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: fixtureData()) as? [String: Any])
        var changed = object
        var recipes = try XCTUnwrap(changed["recipes"] as? [[String: Any]])
        var recipe = try XCTUnwrap(recipes.first)
        var ingredients = try XCTUnwrap(recipe["ingredients"] as? [[String: Any]])
        var ingredient = try XCTUnwrap(ingredients.first)
        var edibleEvidence = try XCTUnwrap(ingredient["edibleFractionEvidence"] as? [String: Any])
        edibleEvidence["sourceRecordID"] = "different-upstream-record"
        ingredient["edibleFractionEvidence"] = edibleEvidence
        ingredients[0] = ingredient
        recipe["ingredients"] = ingredients
        recipes[0] = recipe
        changed["recipes"] = recipes
        let malformedData = try JSONSerialization.data(withJSONObject: changed, options: [.fragmentsAllowed])

        XCTAssertThrowsError(try fixtureCatalog(data: malformedData))
    }

    func testCatalogRejectsARecipePriorSourceUsedAsFoodCompositionEvidence() throws {
        var sources = fixtureVerifiedFoodSources
        sources["usda-fdc-foundation-foods"] = RecipePriorFoodSource(
            sourceID: "usda-fdc-foundation-foods",
            sourceVersion: "2026-04-30",
            dataType: "Foundation",
            dataRole: "recipe-prior",
            licenseSPDX: "CC0-1.0",
            licenseURL: "https://creativecommons.org/publicdomain/zero/1.0/",
            redistributionAllowed: true,
            verificationStatus: "verified"
        )

        XCTAssertThrowsError(try fixtureCatalog(verifiedFoodSources: sources))
    }

    func testCatalogRejectsExactFoodEvidenceWithoutVerifiedFoodRows() throws {
        XCTAssertThrowsError(try RecipePriorCatalog(data: fixtureData()))
    }

    func testUnknownMassBasisIsRetainedAsUnknownInsteadOfInferred() throws {
        let catalog = try fixtureCatalog()
        let ingredient = try XCTUnwrap(catalog.matches("番茄炒蛋").first?.record.ingredients.first)

        XCTAssertEqual(ingredient.massBasis, .unknown)
        XCTAssertEqual(ingredient.massBasisEvidence.kind, .unknown)
        XCTAssertNil(ingredient.massBasisEvidence.sourceText)
        XCTAssertEqual(ingredient.edibleFractionEvidence.kind, .foodCompositionRecord)
        XCTAssertEqual(ingredient.edibleFractionEvidence.fraction, 0.97)
        XCTAssertEqual(ingredient.sourceProvenance.sourceRecordID, "dishes/vegetable_dish/番茄炒蛋.md")
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
            "schemaVersion": 2,
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
                "cuisineRegion": NSNull(),
                "cookingMethod": "stirFry",
                "cookingMethodEvidence": "dish-title:番茄炒蛋",
                "ingredients": [[
                    "sourceName": "番茄",
                    "foodID": 101,
                    "foodMatchStatus": "exact",
                    "edibleFractionEvidence": [
                        "kind": "foodCompositionRecord",
                        "fraction": 0.97,
                        "foodID": 101,
                        "sourceID": "usda-fdc-foundation-foods",
                        "sourceRecordID": "321360",
                        "sourceVersion": "2026-04-30",
                        "licenseStatus": "verified",
                        "licenseSPDX": "CC0-1.0",
                        "redistributionAllowed": true,
                        "reason": NSNull(),
                    ],
                    "massBasis": "unknown",
                    "massBasisEvidence": ["kind": "unknown", "sourceText": NSNull()],
                    "role": "ingredient",
                    "roleEvidence": "recipe-ingredient-role-v1:default-ingredient",
                    "sourceProvenance": [
                        "sourceID": "anduin-howtocook",
                        "sourceRecordID": "dishes/vegetable_dish/番茄炒蛋.md",
                        "sourceVersion": "5fb3140c20b2a713296696dc6fdd3b83ccc617a6",
                        "sourceText": "番茄 1个（约180g）*份数",
                    ],
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
                    "foodID": 102,
                    "foodMatchStatus": "exact",
                    "edibleFractionEvidence": [
                        "kind": "foodCompositionRecord",
                        "fraction": 0.87,
                        "foodID": 102,
                        "sourceID": "usda-fdc-sr-legacy",
                        "sourceRecordID": "171287",
                        "sourceVersion": "2018-04",
                        "licenseStatus": "verified",
                        "licenseSPDX": "CC0-1.0",
                        "redistributionAllowed": true,
                        "reason": NSNull(),
                    ],
                    "massBasis": "unknown",
                    "massBasisEvidence": ["kind": "unknown", "sourceText": NSNull()],
                    "role": "ingredient",
                    "roleEvidence": "recipe-ingredient-role-v1:default-ingredient",
                    "sourceProvenance": [
                        "sourceID": "anduin-howtocook",
                        "sourceRecordID": "dishes/vegetable_dish/番茄炒蛋.md",
                        "sourceVersion": "5fb3140c20b2a713296696dc6fdd3b83ccc617a6",
                        "sourceText": "鸡蛋：2个",
                    ],
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

    private var fixtureVerifiedFoodSources: [String: RecipePriorFoodSource] {
        [
            "usda-fdc-foundation-foods": RecipePriorFoodSource(
                sourceID: "usda-fdc-foundation-foods",
                sourceVersion: "2026-04-30",
                dataType: "Foundation",
                dataRole: "food-composition",
                licenseSPDX: "CC0-1.0",
                licenseURL: "https://creativecommons.org/publicdomain/zero/1.0/",
                redistributionAllowed: true,
                verificationStatus: "verified"
            ),
            "usda-fdc-sr-legacy": RecipePriorFoodSource(
                sourceID: "usda-fdc-sr-legacy",
                sourceVersion: "2018-04",
                dataType: "SR Legacy",
                dataRole: "food-composition",
                licenseSPDX: "CC0-1.0",
                licenseURL: "https://creativecommons.org/publicdomain/zero/1.0/",
                redistributionAllowed: true,
                verificationStatus: "verified"
            ),
        ]
    }

    private var fixtureVerifiedFoodRecords: [Int64: RecipePriorVerifiedFoodRecord] {
        [
            101: RecipePriorVerifiedFoodRecord(
                id: 101,
                sourceID: "usda-fdc-foundation-foods",
                sourceRecordID: "321360",
                sourceVersion: "2026-04-30",
                sourceDataType: "Foundation",
                licenseStatus: "verified",
                licenseSPDX: "CC0-1.0",
                redistributionAllowed: true,
                dataRole: "food-composition",
                edible: 97
            ),
            102: RecipePriorVerifiedFoodRecord(
                id: 102,
                sourceID: "usda-fdc-sr-legacy",
                sourceRecordID: "171287",
                sourceVersion: "2018-04",
                sourceDataType: "SR Legacy",
                licenseStatus: "verified",
                licenseSPDX: "CC0-1.0",
                redistributionAllowed: true,
                dataRole: "food-composition",
                edible: 87
            ),
        ]
    }

    private func fixtureCatalog(
        data: Data? = nil,
        validFoodIDs: Set<Int64>? = nil,
        verifiedFoodSources: [String: RecipePriorFoodSource]? = nil
    ) throws -> RecipePriorCatalog {
        let catalogData: Data
        if let data {
            catalogData = data
        } else {
            catalogData = try fixtureData()
        }
        return try RecipePriorCatalog(
            data: catalogData,
            validFoodIDs: validFoodIDs ?? Set(fixtureVerifiedFoodRecords.keys),
            verifiedFoodSources: verifiedFoodSources ?? fixtureVerifiedFoodSources,
            verifiedFoodRecords: fixtureVerifiedFoodRecords
        )
    }
}
