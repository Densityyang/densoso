import XCTest
@testable import Densoso

final class ExerciseCatalogTests: XCTestCase {
    func testChineseAliasCanResolveCatalogEntry() {
        let squat = ExerciseCatalog.Entry(
            id: "free-exercise-db:Barbell_Squat",
            sourceID: "Barbell_Squat",
            name: "Barbell Squat",
            aliases: ["深蹲", "杠铃深蹲"],
            category: "strength",
            equipment: "barbell",
            primaryMuscles: ["quadriceps"],
            secondaryMuscles: []
        )
        let catalog = ExerciseCatalog(
            schemaVersion: 1,
            catalogVersion: "free-exercise-db-test",
            source: .init(repository: "https://example.invalid", revision: "test", inputSHA256: "abc", license: "Unlicense"),
            entries: [squat]
        )

        XCTAssertEqual(catalog.entry(matching: "深蹲")?.id, squat.id)
        XCTAssertEqual(catalog.entry(matching: "squat")?.name, "Barbell Squat")
    }
}
