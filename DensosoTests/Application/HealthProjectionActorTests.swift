import DensosoDomain
import Foundation
import SwiftData
import XCTest
@testable import Densoso

@MainActor
final class HealthProjectionActorTests: XCTestCase {
    func testTodayNarrativeAndBoundedHistoryShareDeterministicReadModelWithoutCacheWrites() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let today = calendar.startOfDay(for: Date())
        let start = try XCTUnwrap(calendar.date(byAdding: .day, value: -2, to: today))
        let schema = Schema(versionedSchema: DensosoSchemaV4.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970

        for offset in -41...2 {
            let day = try XCTUnwrap(calendar.date(byAdding: .day, value: offset, to: start))
            let snapshot = DailyHealthSnapshot(
                dayStart: day,
                timezoneIdentifier: calendar.timeZone.identifier,
                stepCount: Double(5_000 + offset + 41),
                healthReadStates: [HealthMetricID.stepCount.rawValue: .available],
                algorithmVersion: "projection-actor-fixture-v1"
            )
            context.insert(DailyHealthSnapshotRecord(
                dayKey: dayKey(day, calendar: calendar),
                timezoneID: snapshot.timezoneIdentifier,
                payloadData: try encoder.encode(snapshot),
                snapshotHash: "projection-actor-\(offset)",
                algorithmVersion: snapshot.algorithmVersion
            ))
        }
        let futureDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: today))
        let futureSnapshot = DailyHealthSnapshot(
            dayStart: futureDay,
            timezoneIdentifier: calendar.timeZone.identifier,
            stepCount: 99_999,
            healthReadStates: [HealthMetricID.stepCount.rawValue: .available],
            algorithmVersion: "outside-query-window"
        )
        context.insert(DailyHealthSnapshotRecord(
            dayKey: dayKey(futureDay, calendar: calendar),
            timezoneID: futureSnapshot.timezoneIdentifier,
            payloadData: try encoder.encode(futureSnapshot),
            snapshotHash: "outside-query-window",
            algorithmVersion: futureSnapshot.algorithmVersion
        ))
        try context.save()

        let actor = HealthProjectionActor(modelContainer: container, calendar: calendar)
        let service = HealthIntelligenceService(modelContainer: container, calendar: calendar)
        let beforeDailyBriefs = try context.fetchCount(FetchDescriptor<DailyBriefRecord>())
        let beforeWeeklyBriefs = try context.fetchCount(FetchDescriptor<WeeklyBriefRecord>())

        let actorState = try await actor.todayHealthState(asOf: today)
        let narrativeContext = try await actor.healthNarrativeContext(asOf: today)
        let actorHistory = try await actor.healthHistory(from: start, through: today)
        let serviceHistory = try service.healthHistory(from: start, through: today)

        XCTAssertNotNil(actorState)
        XCTAssertEqual(narrativeContext.healthState, actorState)
        XCTAssertNotNil(narrativeContext.aggregateSummary)
        XCTAssertEqual(actorHistory, serviceHistory)
        XCTAssertEqual(actorHistory.map(\.date), [
            start,
            try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: start)),
            today,
        ])
        XCTAssertEqual(
            actorState?.domains.first(where: { $0.domain == .activity })?.currentValue,
            5_043
        )
        XCTAssertFalse(actorHistory.contains { $0.state.domains.contains { $0.currentValue == 99_999 } })
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DailyBriefRecord>()), beforeDailyBriefs)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<WeeklyBriefRecord>()), beforeWeeklyBriefs)
    }

    func testActorHistoryRetainsExistingRangeValidation() async throws {
        let schema = Schema(versionedSchema: DensosoSchemaV4.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let actor = HealthProjectionActor(modelContainer: container)
        let today = Calendar.current.startOfDay(for: Date())
        let oversizedStart = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -14, to: today))

        do {
            _ = try await actor.healthHistory(from: oversizedStart, through: today)
            XCTFail("Expected the existing fourteen-day bound to reject this query")
        } catch {
            XCTAssertEqual(error as? HealthHistoryQueryError, .rangeTooLarge)
        }
    }

    private func dayKey(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
