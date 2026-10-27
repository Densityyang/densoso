import XCTest
@testable import Densoso

final class FoodDatabaseTests: XCTestCase {
    func testSeedDatabaseRebuildsFTSIndex() throws {
        let database = try FoodDatabase(seedJSON: seedData)

        let results = try database.ftsSearch(query: "鸡胸肉")

        XCTAssertEqual(results.map(\.name), ["鸡胸肉"])
    }

    func testFTSSearchIgnoresWhitespaceOnlyQueries() throws {
        let database = try FoodDatabase(seedJSON: seedData)

        XCTAssertTrue(try database.ftsSearch(query: " \n\t ").isEmpty)
    }

    func testFTSSearchBoundsResultLimit() throws {
        let database = try FoodDatabase(seedJSON: seedData)

        XCTAssertTrue(try database.ftsSearch(query: "鸡胸肉", limit: 0).isEmpty)
        XCTAssertTrue(try database.ftsSearch(query: "鸡胸肉", limit: -1).isEmpty)
    }

    func testCatalogEntriesRemainStableAcrossRepeatedReads() throws {
        let database = try FoodDatabase(seedJSON: seedData)

        let firstRead = try database.catalogEntries()
        let secondRead = try database.catalogEntries()

        XCTAssertEqual(firstRead.map(\.id), secondRead.map(\.id))
        XCTAssertEqual(firstRead.first?.name, "鸡胸肉")
        let entry = try XCTUnwrap(firstRead.first)
        XCTAssertEqual(entry.sourceID, "fixture-food-source")
        XCTAssertEqual(entry.sourceRecordID, "fixture-chicken-breast")
        XCTAssertEqual(entry.licenseStatus, "verified")
        XCTAssertEqual(entry.dataQuality, "fixture-reviewed")
        XCTAssertEqual(entry.nutrientBasis, "per100g")
        XCTAssertEqual(entry.massBasis, "edibleRaw")
        XCTAssertEqual(entry.energyRaw, "133")
        XCTAssertEqual(entry.energyUnit, "kcal/100g")
        XCTAssertEqual(entry.importWarnings, ["fixture review warning"])
    }

    func testFoodSourceProvenanceSurvivesSeedDatabaseImport() throws {
        let database = try FoodDatabase(seedJSON: seedData)

        let item = try XCTUnwrap(database.lookup(id: 1))
        XCTAssertEqual(item.sourceID, "fixture-food-source")
        XCTAssertEqual(item.sourceRecordID, "fixture-chicken-breast")
        XCTAssertEqual(item.sourceVersion, "fixture-v1")
        XCTAssertEqual(item.licenseStatus, "verified")
        let entry = try XCTUnwrap(database.catalogEntries().first)
        XCTAssertEqual(entry.sourceVersion, "fixture-v1")
        XCTAssertEqual(entry.sourceID, "fixture-food-source")
        XCTAssertEqual(entry.sourceRecordID, "fixture-chicken-breast")
        XCTAssertEqual(entry.licenseStatus, "verified")
        XCTAssertEqual(entry.dataQuality, "fixture-reviewed")
        XCTAssertEqual(entry.nutrientBasis, "per100g")
        XCTAssertEqual(entry.massBasis, "edibleRaw")
        XCTAssertEqual(entry.energyRaw, "133")
        XCTAssertEqual(entry.energyUnit, "kcal/100g")
        XCTAssertEqual(entry.sourceName, "Chicken breast, cooked")
        XCTAssertEqual(entry.sourceDataType, "fixture")
        XCTAssertEqual(entry.importWarnings, ["fixture review warning"])
    }

    private var seedData: Data {
        Data(
            """
            [
              {
                "id": 1,
                "name": "鸡胸肉",
                "alias": "鸡胸",
                "category": "肉类",
                "edible": 100,
                "energyKcal": 133,
                "energyRaw": "133",
                "energyUnit": "kcal/100g",
                "sourceID": "fixture-food-source",
                "sourceRecordID": "fixture-chicken-breast",
                "sourceVersion": "fixture-v1",
                "licenseStatus": "verified",
                "sourceRecordJSON": "{\"nutrientBasis\":\"per100g\",\"massBasis\":\"edibleRaw\",\"dataQuality\":\"fixture-reviewed\",\"sourceName\":\"Chicken breast, cooked\",\"sourceDataType\":\"fixture\"}",
                "importWarningsJSON": "[\"fixture review warning\"]",
                "proteinG": 19.4,
                "fatG": 5.0,
                "carbohydrateG": 2.5,
                "fiberG": null
              }
            ]
            """.utf8
        )
    }
}
