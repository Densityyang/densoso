import Foundation
import DensosoDomain
import SwiftData
import XCTest
@testable import Densoso

@MainActor
final class GetRecentMealsToolTests: XCTestCase {
    func testQueryWindowAndOutputUseLocalDaysSortNewestFirstAndEnforceLimit() throws {
        let calendar = localCalendar()
        let asOf = try date(2026, 10, 16, 0, 30, calendar: calendar)
        let tool = GetRecentMealsTool(calendar: calendar)
        let window = try tool.queryWindow(days: 2, asOf: asOf)
        XCTAssertEqual(window.startDate, try date(2026, 10, 15, 0, 0, calendar: calendar))
        XCTAssertEqual(window.endDate, asOf)

        let today = try date(2026, 10, 16, 0, 20, calendar: calendar)
        let yesterdayLate = try date(2026, 10, 15, 23, 55, calendar: calendar)
        let outsideRange = try date(2026, 10, 14, 23, 59, calendar: calendar)
        let futureMeal = try date(2026, 10, 16, 0, 31, calendar: calendar)
        let earlierYesterday = try date(2026, 10, 15, 1, 0, calendar: calendar)
        let response = try tool.response(
            meals: [
                meal(at: earlierYesterday, name: "早餐"),
                meal(at: outsideRange, name: "更早的餐食"),
                meal(at: futureMeal, name: "未来餐食"),
                meal(at: today, name: "今早餐食"),
                meal(at: yesterdayLate, name: "昨晚餐食"),
            ],
            from: window.startDate,
            through: window.endDate,
            limit: 2
        )
        let object = try jsonObject(response)
        XCTAssertEqual(object["status"] as? String, "available")
        XCTAssertEqual(object["startDate"] as? String, "2026-10-15")
        XCTAssertEqual(object["endDate"] as? String, "2026-10-16")
        XCTAssertEqual(object["returnedCount"] as? Int, 2)
        XCTAssertEqual(object["hasMore"] as? Bool, true)
        let meals = try XCTUnwrap(object["meals"] as? [[String: Any]])
        XCTAssertEqual(meals.compactMap { $0["localTime"] as? String }, ["00:20", "23:55"])
        XCTAssertEqual(meals.compactMap { $0["localDate"] as? String }, ["2026-10-16", "2026-10-15"])
    }

    func testSizeBoundReportsThatAdditionalMealsRemain() throws {
        let calendar = localCalendar()
        let asOf = try date(2026, 10, 16, 18, 0, calendar: calendar)
        let start = calendar.startOfDay(for: asOf)
        let longDishName = String(repeating: "菜", count: AgentRecentMealsLimits.maximumDishNameLength)
        let meals = (0..<AgentRecentMealsLimits.maximumMealCount).map { offset in
            AgentRecentMeal(
                occurredAt: asOf.addingTimeInterval(-Double(offset * 60)),
                mealType: "lunch",
                energyEstimate: AgentMealEnergyEstimate(lowKcal: 400, likelyKcal: 500, highKcal: 650),
                dishes: (0..<AgentRecentMealsLimits.maximumDishesPerMeal).map { _ in
                    AgentMealDishSummary(name: longDishName, likelyKcal: 500)
                }
            )
        }

        let response = try GetRecentMealsTool(calendar: calendar).response(
            meals: meals,
            from: start,
            through: asOf,
            limit: AgentRecentMealsLimits.maximumMealCount
        )
        let object = try jsonObject(response)

        XCTAssertLessThan(response.count, AgentRecentMealsLimits.maximumOutputCharacters)
        XCTAssertLessThan(try XCTUnwrap(object["returnedCount"] as? Int), AgentRecentMealsLimits.maximumMealCount)
        XCTAssertEqual(object["hasMore"] as? Bool, true)
    }

    func testToolHasStrictReadOnlySchemaAndRejectsOutOfRangeArguments() throws {
        let definition = GetRecentMealsTool().definition
        XCTAssertEqual(definition.name, "get_recent_meals")
        XCTAssertEqual(definition.effect, .readOnly)
        guard case .object(_, let required, let additionalProperties, _) = definition.parameters else {
            return XCTFail("get_recent_meals must use an object schema")
        }
        XCTAssertTrue(required.isEmpty)
        XCTAssertFalse(additionalProperties)
        XCTAssertNoThrow(try ToolSchemaValidator.validate(.object([:]), against: definition.parameters))
        XCTAssertThrowsError(try ToolSchemaValidator.validate(
            .object(["days": .integer(31)]),
            against: definition.parameters
        ))
        XCTAssertThrowsError(try ToolSchemaValidator.validate(
            .object(["includeNotes": .boolean(true)]),
            against: definition.parameters
        ))
    }

    func testRepositoryUsesUUIDAsStableTieBreakBeforeApplyingFetchLimit() async throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let createdAt = Date(timeIntervalSince1970: 1_799_000_000)
        let schema = Schema(versionedSchema: DensosoSchemaV4.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        let earlierID = UUID(uuidString: "00000000-0000-0000-0000-000000000911")!
        let laterID = UUID(uuidString: "00000000-0000-0000-0000-000000000912")!
        for (id, name) in [(earlierID, "UUID-较小"), (laterID, "UUID-较大")] {
            let meal = MealRecord(
                id: id,
                date: date,
                mealType: "lunch",
                totalCaloriesKcal: 500,
                sourceActionKey: "tie-break-\(id.uuidString)",
                energyLowKcal: 450,
                energyLikelyKcal: 500,
                energyHighKcal: 600
            )
            meal.createdAt = createdAt
            meal.dishes = [DishEntry(dishName: name, estimatedCaloriesKcal: 500)]
            context.insert(meal)
        }
        try context.save()

        let repository = SwiftDataAgentRepository(modelContainer: container)
        let summaries = try await repository.recentMeals(from: date, through: date, limit: 1)

        XCTAssertEqual(summaries.first?.dishes.first?.name, "UUID-较大")
    }

    func testRepositoryReturnsBoundedSummariesWithoutWritingOrExposingStoredFields() async throws {
        let calendar = localCalendar()
        let asOf = try date(2026, 10, 16, 18, 0, calendar: calendar)
        let start = try date(2026, 10, 15, 0, 0, calendar: calendar)
        let schema = Schema(versionedSchema: DensosoSchemaV4.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        let latest = makeStoredMeal(
            at: try date(2026, 10, 16, 12, 30, calendar: calendar),
            name: "蔬菜炒饭",
            rawMarker: "private-ingredient-json-marker"
        )
        let earlier = makeStoredMeal(
            at: try date(2026, 10, 15, 11, 0, calendar: calendar),
            name: "燕麦牛奶",
            rawMarker: "private-note-marker"
        )
        let outside = makeStoredMeal(
            at: try date(2026, 10, 14, 23, 59, calendar: calendar),
            name: "不应返回",
            rawMarker: "outside-range-marker"
        )
        context.insert(latest)
        context.insert(earlier)
        context.insert(outside)
        try context.save()
        let beforeMealCount = try context.fetchCount(FetchDescriptor<MealRecord>())
        let beforeBriefCount = try context.fetchCount(FetchDescriptor<DailyBriefRecord>())

        let repository = SwiftDataAgentRepository(modelContainer: container)
        let summaries = try await repository.recentMeals(from: start, through: asOf, limit: 1)
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries.first?.dishes.first?.name, "蔬菜炒饭")

        let response = try GetRecentMealsTool(calendar: calendar).response(
            meals: summaries,
            from: start,
            through: asOf,
            limit: 1
        )
        let object = try jsonObject(response)
        let outputs = try XCTUnwrap(object["meals"] as? [[String: Any]])
        let output = try XCTUnwrap(outputs.first)
        XCTAssertEqual(output["mealType"] as? String, "lunch")
        XCTAssertNotNil(output["energyEstimate"] as? [String: Any])
        let dishOutputs = try XCTUnwrap(output["dishes"] as? [[String: Any]])
        XCTAssertEqual(dishOutputs.first?["likelyKcal"] as? Int, 500)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<MealRecord>()), beforeMealCount)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DailyBriefRecord>()), beforeBriefCount)
        XCTAssertFalse(response.contains("private-ingredient-json-marker"))
        XCTAssertFalse(response.contains("private-note-marker"))
        XCTAssertFalse(response.contains("sourceActionKey"))
        XCTAssertFalse(response.contains("ingredientJSON"))
        XCTAssertFalse(response.contains("evidenceData"))
        XCTAssertFalse(response.contains("notes"))
        XCTAssertFalse(response.contains("algorithmVersion"))
    }

    func testUnavailableLegacyDishEnergyIsOmittedWhileEvidenceBackedZeroIsPreserved() async throws {
        let calendar = localCalendar()
        let date = try date(2026, 10, 16, 12, 0, calendar: calendar)
        let legacyEvidenceData = try JSONEncoder().encode([
            EvidenceSnapshot(
                grade: .legacyPointEstimate,
                sourceID: "swiftdata-v2",
                summary: "Migrated without recalculating the historical point estimate."
            ),
        ])
        let measuredZeroEvidenceData = try JSONEncoder().encode([
            EvidenceSnapshot(
                grade: .measured,
                sourceID: "user-confirmed-measurement",
                summary: "Explicitly measured as zero energy."
            ),
        ])
        let schema = Schema(versionedSchema: DensosoSchemaV4.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        let meal = MealRecord(
            date: date,
            mealType: "lunch",
            totalCaloriesKcal: 0,
            sourceActionKey: "legacy-meal-with-unavailable-energy",
            energyLowKcal: 0,
            energyLikelyKcal: 0,
            energyHighKcal: 0,
            evidenceData: legacyEvidenceData
        )
        meal.dishes = [
            DishEntry(
                dishName: "未估算菜品",
                estimatedCaloriesKcal: 0,
                evidenceData: legacyEvidenceData
            ),
            DishEntry(
                dishName: "已确认零热量的水",
                estimatedCaloriesKcal: 0,
                evidenceData: measuredZeroEvidenceData
            ),
        ]
        context.insert(meal)
        try context.save()

        let repository = SwiftDataAgentRepository(modelContainer: container)
        let summaries = try await repository.recentMeals(from: date, through: date, limit: 1)

        let summary = try XCTUnwrap(summaries.first)
        XCTAssertNil(summary.energyEstimate)
        let legacyDish = try XCTUnwrap(summary.dishes.first { $0.name == "未估算菜品" })
        let measuredZeroDish = try XCTUnwrap(summary.dishes.first { $0.name == "已确认零热量的水" })
        XCTAssertNil(legacyDish.likelyKcal)
        XCTAssertEqual(measuredZeroDish.likelyKcal, 0)

        let start = calendar.startOfDay(for: date)
        let response = try GetRecentMealsTool(calendar: calendar).response(
            meals: summaries,
            from: start,
            through: date,
            limit: 1
        )
        let object = try jsonObject(response)
        let outputs = try XCTUnwrap(object["meals"] as? [[String: Any]])
        let output = try XCTUnwrap(outputs.first)
        XCTAssertNil(output["energyEstimate"])
        let dishOutputs = try XCTUnwrap(output["dishes"] as? [[String: Any]])
        let legacyDishOutput = try XCTUnwrap(
            dishOutputs.first { $0["name"] as? String == "未估算菜品" }
        )
        let measuredZeroDishOutput = try XCTUnwrap(
            dishOutputs.first { $0["name"] as? String == "已确认零热量的水" }
        )
        XCTAssertNil(legacyDishOutput["likelyKcal"])
        XCTAssertEqual(measuredZeroDishOutput["likelyKcal"] as? Int, 0)
    }

    private func localCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, calendar: Calendar) throws -> Date {
        try XCTUnwrap(calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        )))
    }

    private func meal(at date: Date, name: String) -> AgentRecentMeal {
        AgentRecentMeal(
            occurredAt: date,
            mealType: "lunch",
            energyEstimate: AgentMealEnergyEstimate(lowKcal: 400, likelyKcal: 500, highKcal: 650),
            dishes: [AgentMealDishSummary(name: name, likelyKcal: 500)]
        )
    }

    private func makeStoredMeal(at date: Date, name: String, rawMarker: String) -> MealRecord {
        let meal = MealRecord(
            date: date,
            mealType: "lunch",
            totalCaloriesKcal: 500,
            proteinG: 25,
            fatG: 18,
            carbsG: 60,
            notes: "private-note-marker",
            sourceActionKey: "private-storage-\(date.timeIntervalSince1970)",
            energyLowKcal: 420,
            energyLikelyKcal: 500,
            energyHighKcal: 700,
            evidenceData: Data("private-evidence-marker".utf8)
        )
        meal.dishes = [
            DishEntry(
                dishName: name,
                ingredientJSON: rawMarker,
                estimatedCaloriesKcal: 500,
                evidenceData: Data(rawMarker.utf8),
                algorithmVersion: "private-algorithm-version"
            ),
        ]
        return meal
    }

    private func jsonObject(_ string: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any])
    }
}
