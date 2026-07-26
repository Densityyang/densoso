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
