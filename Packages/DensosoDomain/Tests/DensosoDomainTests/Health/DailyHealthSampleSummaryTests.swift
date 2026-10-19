import Foundation
import XCTest
@testable import DensosoDomain

final class DailyHealthSampleSummaryTests: XCTestCase {
    func testDailySnapshotEncodingKeepsOnlySummaryAndDropsRawSamples() throws {
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let sample = HealthSampleSnapshot(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000701")!,
            metric: .heartRate,
            startDate: day,
            endDate: day,
            value: 72,
            sourceBundleIdentifier: "private.source.bundle",
            deviceName: "private-device",
            syncIdentifier: "private-sync-id"
        )
        let snapshot = DailyHealthSnapshot(
            dayStart: day,
            timezoneIdentifier: "UTC",
            healthKitSamples: [sample],
            algorithmVersion: "test"
        )

        let data = try JSONEncoder().encode(snapshot)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["healthKitSamples"])
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("private.source.bundle"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("private-device"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("private-sync-id"))

        let decoded = try JSONDecoder().decode(DailyHealthSnapshot.self, from: data)
        XCTAssertNil(decoded.healthKitSamples)
        XCTAssertEqual(decoded.healthKitSampleSummary?.aggregate(for: .heartRate)?.averageValue, 72)
        XCTAssertEqual(decoded.healthKitSampleSummary?.aggregate(for: .heartRate)?.sampleCount, 1)
    }

    func testSleepAggregationRetainsWatchPriorityAndLegacyCategoryAliases() throws {
        let calendar = Calendar.current
        let wakeDay = calendar.date(from: DateComponents(year: 2026, month: 10, day: 19))!
        let previousDay = calendar.date(byAdding: .day, value: -1, to: wakeDay)!
        let watchStart = calendar.date(bySettingHour: 22, minute: 0, second: 0, of: previousDay)!
        let wakeAt = calendar.date(bySettingHour: 6, minute: 0, second: 0, of: wakeDay)!
        let watchCore = HealthSampleSnapshot(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000702")!,
            metric: .sleepAnalysis,
            startDate: watchStart,
            endDate: wakeAt,
            categoryValue: "3",
            sourceBundleIdentifier: "com.example.watchhealth",
            deviceModel: "Watch6,1"
        )
        let phoneSleep = HealthSampleSnapshot(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000703")!,
            metric: .sleepAnalysis,
            startDate: watchStart,
            endDate: wakeAt,
            categoryValue: "asleep",
            sourceBundleIdentifier: "com.example.phonehealth",
            deviceModel: "iPhone15,2"
        )

        let summary = DailyHealthSampleSummary(
            samples: [watchCore, phoneSleep],
            dayStart: wakeDay,
            sleepSamples: [watchCore, phoneSleep]
        )

        XCTAssertEqual(summary.sleep?.totalAsleepMinutes, 480)
        XCTAssertEqual(summary.sleep?.stages?.core, 480)
        XCTAssertNil(summary.sleep?.selectedSourceBundleIdentifier)
    }

    func testSampleDeduplicationUsesSyncVersionThenStableTieOrder() throws {
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let sampleID = UUID(uuidString: "00000000-0000-0000-0000-000000000704")!
        let unversioned = HealthSampleSnapshot(
            id: sampleID,
            metric: .bodyMass,
            startDate: day,
            endDate: day,
            value: 69
        )
        let explicitlyVersioned = HealthSampleSnapshot(
            id: sampleID,
            metric: .bodyMass,
            startDate: day,
            endDate: day,
            value: 70,
            syncVersion: Int.min
        )
        XCTAssertEqual(
            HealthSampleSnapshot.deduplicated([unversioned, explicitlyVersioned]),
            [explicitlyVersioned]
        )
        XCTAssertEqual(
            HealthSampleSnapshot.deduplicated([explicitlyVersioned, unversioned]),
            [explicitlyVersioned]
        )

        let laterRevision = HealthSampleSnapshot(
            id: sampleID,
            metric: .bodyMass,
            startDate: day.addingTimeInterval(86_400),
            endDate: day.addingTimeInterval(86_400),
            value: 72,
            syncVersion: 7
        )
        let earlierTie = HealthSampleSnapshot(
            id: sampleID,
            metric: .bodyMass,
            startDate: day,
            endDate: day,
            value: 71,
            syncVersion: 7
        )
        XCTAssertEqual(
            HealthSampleSnapshot.deduplicated([laterRevision, earlierTie]),
            [earlierTie]
        )
        XCTAssertEqual(
            HealthSampleSnapshot.deduplicated([earlierTie, laterRevision]),
            [earlierTie]
        )

        let summary = DailyHealthSampleSummary(
            samples: [unversioned, explicitlyVersioned],
            dayStart: day
        )
        XCTAssertEqual(summary.aggregate(for: .bodyMass)?.sampleCount, 1)
        XCTAssertEqual(summary.aggregate(for: .bodyMass)?.latestValue, 70)
    }
}
