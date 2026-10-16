import Foundation
import SwiftData
import XCTest
@testable import Densoso

@MainActor
final class GetRecentWorkoutsToolTests: XCTestCase {
    func testQueryWindowAndOutputUseLocalDaysSortNewestFirstAndEnforceLimit() throws {
        let calendar = localCalendar()
        let asOf = try date(2026, 10, 16, 0, 30, calendar: calendar)
        let tool = GetRecentWorkoutsTool(calendar: calendar)
        let window = try tool.queryWindow(days: 2, asOf: asOf)
        XCTAssertEqual(window.startDate, try date(2026, 10, 15, 0, 0, calendar: calendar))
        XCTAssertEqual(window.endDate, asOf)

        let today = try date(2026, 10, 16, 0, 20, calendar: calendar)
        let yesterdayLate = try date(2026, 10, 15, 23, 55, calendar: calendar)
        let outsideRange = try date(2026, 10, 14, 23, 59, calendar: calendar)
        let futureWorkout = try date(2026, 10, 16, 0, 31, calendar: calendar)
        let workouts = [
            workout(at: outsideRange, type: "old", duration: 40),
            workout(at: yesterdayLate, type: "cycling", duration: 30),
            workout(at: futureWorkout, type: "future", duration: 50),
            workout(at: today, type: "running", duration: 25),
        ]
        let response = try tool.response(
            workouts: workouts,
            from: window.startDate,
            through: window.endDate,
            limit: 2
        )
        let object = try jsonObject(response)

        XCTAssertEqual(object["status"] as? String, "available")
        XCTAssertEqual(object["startDate"] as? String, "2026-10-15")
        XCTAssertEqual(object["endDate"] as? String, "2026-10-16")
        XCTAssertEqual(object["returnedCount"] as? Int, 2)
        XCTAssertEqual(object["hasMore"] as? Bool, false)
        let results = try XCTUnwrap(object["workouts"] as? [[String: Any]])
        XCTAssertEqual(results.compactMap { $0["localTime"] as? String }, ["00:20", "23:55"])
        XCTAssertEqual(results.compactMap { $0["workoutType"] as? String }, ["running", "cycling"])
    }

    func testToolHasStrictReadOnlySchemaAndRejectsOutOfRangeArguments() throws {
        let definition = GetRecentWorkoutsTool().definition
        XCTAssertEqual(definition.name, "get_recent_workouts")
        XCTAssertEqual(definition.effect, .readOnly)
        guard case .object(_, let required, let additionalProperties, _) = definition.parameters else {
            return XCTFail("get_recent_workouts must use an object schema")
        }
        XCTAssertTrue(required.isEmpty)
        XCTAssertFalse(additionalProperties)
        XCTAssertNoThrow(try ToolSchemaValidator.validate(.object([:]), against: definition.parameters))
        XCTAssertThrowsError(try ToolSchemaValidator.validate(
            .object(["limit": .integer(21)]),
            against: definition.parameters
        ))
        XCTAssertThrowsError(try ToolSchemaValidator.validate(
            .object(["includeNotes": .boolean(true)]),
            against: definition.parameters
        ))
    }

    func testRepositoryReturnsCompletedRecordsOnlyWithoutWritesOrStoredFields() async throws {
        let calendar = localCalendar()
        let asOf = try date(2026, 10, 16, 18, 0, calendar: calendar)
        let start = try date(2026, 10, 15, 0, 0, calendar: calendar)
        let schema = Schema(versionedSchema: DensosoSchemaV4.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        let storedWorkoutID = UUID(uuidString: "00000000-0000-0000-0000-000000000933")!
        let healthKitUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000931")!
        let latest = WorkoutRecord(
            date: try date(2026, 10, 16, 12, 30, calendar: calendar),
            type: "running",
            durationMinutes: 45,
            estimatedCaloriesBurned: 360,
            intensity: "high",
            notes: "private-workout-note-marker",
            healthKitUUID: healthKitUUID,
            logicalSessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000932")!,
            workoutOrigin: "externalHealthKit",
            energySource: "measured",
            sourceBundleIdentifier: "private-source-bundle-marker",
            routeStatus: "private-route-marker",
            routePointCount: 44
        )
        latest.id = storedWorkoutID
        let earlier = WorkoutRecord(
            date: try date(2026, 10, 15, 11, 0, calendar: calendar),
            type: "cycling",
            durationMinutes: 30,
            estimatedCaloriesBurned: 210,
            intensity: "moderate",
            notes: "private-earlier-note"
        )
        let outside = WorkoutRecord(
            date: try date(2026, 10, 14, 23, 59, calendar: calendar),
            type: "outside-range",
            durationMinutes: 50
        )
        context.insert(latest)
        context.insert(earlier)
        context.insert(outside)
        context.insert(ScheduleEvent(
            date: try date(2026, 10, 16, 13, 0, calendar: calendar),
            title: "plan-only-workout-title",
            notes: "planned workout notes",
            startTime: try date(2026, 10, 16, 13, 0, calendar: calendar)
        ))
        try context.save()
        let beforeWorkoutCount = try context.fetchCount(FetchDescriptor<WorkoutRecord>())
        let beforeScheduleCount = try context.fetchCount(FetchDescriptor<ScheduleEvent>())

        let repository = SwiftDataAgentRepository(modelContainer: container)
        let summaries = try await repository.recentWorkouts(from: start, through: asOf, limit: 1)
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries.first?.workoutType, "running")

        let response = try GetRecentWorkoutsTool(calendar: calendar).response(
            workouts: summaries,
            from: start,
            through: asOf,
            limit: 1
        )
        let object = try jsonObject(response)
        let results = try XCTUnwrap(object["workouts"] as? [[String: Any]])
        let result = try XCTUnwrap(results.first)
        XCTAssertEqual(result["durationMinutes"] as? Int, 45)
        XCTAssertEqual(result["intensity"] as? String, "high")
        XCTAssertEqual(result["estimatedCaloriesKcal"] as? Int, 360)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<WorkoutRecord>()), beforeWorkoutCount)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ScheduleEvent>()), beforeScheduleCount)
        XCTAssertFalse(response.contains("private-workout-note-marker"))
        XCTAssertFalse(response.contains("private-source-bundle-marker"))
        XCTAssertFalse(response.contains("private-route-marker"))
        XCTAssertFalse(response.contains(healthKitUUID.uuidString))
        XCTAssertFalse(response.contains(storedWorkoutID.uuidString))
        XCTAssertFalse(response.contains("plan-only-workout-title"))
        XCTAssertFalse(response.contains("healthKitUUID"))
        XCTAssertFalse(response.contains("logicalSessionID"))
        XCTAssertFalse(response.contains("sourceBundleIdentifier"))
        XCTAssertFalse(response.contains("routePointCount"))
        XCTAssertFalse(response.contains("notes"))
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

    private func workout(
        at date: Date,
        type: String,
        duration: Int
    ) -> AgentRecentWorkout {
        AgentRecentWorkout(
            occurredAt: date,
            workoutType: type,
            durationMinutes: duration,
            intensity: "moderate",
            estimatedCaloriesKcal: 250
        )
    }

    private func jsonObject(_ string: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any])
    }
}
