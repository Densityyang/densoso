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
        XCTAssertEqual(summary.sleep?.selectedSourceBundleIdentifier, "com.example.watchhealth")
        XCTAssertEqual(
            summary.sleep?.selectedSourceIdentifier,
            "bundle:18:com.example.watchhealth|device:8:Watch6,1"
        )
        XCTAssertTrue(summary.sleep?.hasConflictingSourceStages == true)
        XCTAssertTrue(summary.sleep?.supplementalSourceIdentifiers.isEmpty == true)
        XCTAssertEqual(summary.sleep?.sourceCoverage, [
            SleepSourceCoverage(
                sourceIdentifier: "bundle:18:com.example.watchhealth|device:8:Watch6,1",
                asleepMinutes: 480
            ),
        ])
        XCTAssertEqual(summary.sleep?.algorithmVersion, AlgorithmVersions.healthIntelligence)

        let encodedSummary = try JSONEncoder().encode(summary)
        let decodedSummary = try JSONDecoder().decode(DailyHealthSampleSummary.self, from: encodedSummary)
        XCTAssertEqual(decodedSummary.sleep, summary.sleep)
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

    func testMetricSpecificDailyRepresentativesResistSamplingFrequencyBias() throws {
        // Align with the metric's absolute 15-minute buckets so the four
        // dense samples represent one window and the later sample a second.
        let day = Date(timeIntervalSince1970: 1_700_000_100)
        let samples = [
            sample(801, metric: .heartRate, at: day.addingTimeInterval(60), value: 60),
            sample(802, metric: .heartRate, at: day.addingTimeInterval(120), value: 60),
            sample(803, metric: .heartRate, at: day.addingTimeInterval(180), value: 60),
            sample(804, metric: .heartRate, at: day.addingTimeInterval(240), value: 60),
            sample(805, metric: .heartRate, at: day.addingTimeInterval(4_000), value: 100),
            sample(806, metric: .heartRateVariabilitySDNN, at: day.addingTimeInterval(60), value: 20),
            sample(807, metric: .heartRateVariabilitySDNN, at: day.addingTimeInterval(120), value: 30),
            sample(808, metric: .heartRateVariabilitySDNN, at: day.addingTimeInterval(180), value: 40),
            sample(809, metric: .heartRateVariabilitySDNN, at: day.addingTimeInterval(4_000), value: 100),
            sample(810, metric: .respiratoryRate, at: day.addingTimeInterval(60), value: 12),
            sample(811, metric: .respiratoryRate, at: day.addingTimeInterval(4_000), value: 20),
            sample(812, metric: .wristTemperature, at: day.addingTimeInterval(60), value: 35.8),
            sample(813, metric: .wristTemperature, at: day.addingTimeInterval(4_000), value: 36.2),
            sample(814, metric: .restingHeartRate, at: day.addingTimeInterval(60), value: 62),
            sample(815, metric: .restingHeartRate, at: day.addingTimeInterval(4_000), value: 58),
            sample(816, metric: .bodyMass, at: day.addingTimeInterval(60), value: 70),
            sample(817, metric: .bodyMass, at: day.addingTimeInterval(4_000), value: 80),
        ]

        let summary = DailyHealthSampleSummary(samples: samples, dayStart: day)

        XCTAssertEqual(summary.aggregate(for: .heartRate)?.averageValue, 68)
        XCTAssertEqual(summary.aggregate(for: .heartRate)?.representativeValue, 80)
        XCTAssertEqual(summary.aggregate(for: .heartRate)?.sampleCount, 2)
        XCTAssertEqual(summary.aggregate(for: .heartRate)?.rawSampleCount, 5)
        XCTAssertEqual(summary.aggregate(for: .heartRateVariabilitySDNN)?.averageValue, 47.5)
        XCTAssertEqual(summary.aggregate(for: .heartRateVariabilitySDNN)?.representativeValue, 65)
        XCTAssertEqual(summary.aggregate(for: .heartRateVariabilitySDNN)?.sampleCount, 2)
        XCTAssertEqual(summary.aggregate(for: .heartRateVariabilitySDNN)?.rawSampleCount, 4)
        XCTAssertEqual(summary.aggregate(for: .respiratoryRate)?.representativeValue, 16)
        XCTAssertEqual(summary.aggregate(for: .wristTemperature)?.representativeValue, 36.0)
        XCTAssertEqual(summary.aggregate(for: .restingHeartRate)?.representativeValue, 58)
        XCTAssertEqual(summary.aggregate(for: .bodyMass)?.averageValue, 75)
        XCTAssertEqual(summary.aggregate(for: .bodyMass)?.representativeValue, 80)
    }

    func testOverlappingHealthMetricSourcesCountOneIndependentWindow() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let samples = [
            HealthSampleSnapshot(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000818")!,
                metric: .heartRate,
                startDate: start,
                endDate: start,
                value: 60,
                sourceBundleIdentifier: "com.example.watch"
            ),
            HealthSampleSnapshot(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000819")!,
                metric: .heartRate,
                startDate: start.addingTimeInterval(30),
                endDate: start.addingTimeInterval(30),
                value: 80,
                sourceBundleIdentifier: "com.example.phone"
            ),
        ]

        let aggregate = try XCTUnwrap(
            DailyHealthSampleSummary(samples: samples, dayStart: start).aggregate(for: .heartRate)
        )

        XCTAssertEqual(aggregate.sampleCount, 1)
        XCTAssertEqual(aggregate.rawSampleCount, 2)
        XCTAssertEqual(aggregate.representativeValue, 70)
    }

    func testHourlyHRVSeparatesDevicesWithTheSameSourceBundle() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let bundle = "com.example.health"
        let samples = [
            sample(830, metric: .heartRateVariabilitySDNN, at: start.addingTimeInterval(60), value: 58)
                .withSource(bundle, device: "Watch10,1"),
            sample(831, metric: .heartRateVariabilitySDNN, at: start.addingTimeInterval(120), value: 62)
                .withSource(bundle, device: "Watch10,1"),
            sample(832, metric: .heartRateVariabilitySDNN, at: start.addingTimeInterval(180), value: 110)
                .withSource(bundle, device: "iPhone17,1"),
            sample(833, metric: .heartRateVariabilitySDNN, at: start.addingTimeInterval(240), value: 130)
                .withSource(bundle, device: "iPhone17,1"),
        ]

        let aggregate = try XCTUnwrap(
            DailyHealthSampleSummary(samples: samples, dayStart: start).aggregate(for: .heartRateVariabilitySDNN)
        )

        XCTAssertEqual(aggregate.representativeValue, 90)
        XCTAssertEqual(aggregate.sampleCount, 1)
        XCTAssertEqual(aggregate.rawSampleCount, 4)
    }

    func testLegacyMetricAggregateDecodesWithAverageAsRepresentativeFallback() throws {
        let data = Data(#"{"metric":"heartRate","sampleCount":2,"averageValue":72,"minimumValue":60,"maximumValue":84,"latestValue":84}"#.utf8)

        let aggregate = try JSONDecoder().decode(HealthMetricSampleAggregate.self, from: data)

        XCTAssertEqual(aggregate.averageValue, 72)
        XCTAssertEqual(aggregate.representativeValue, 72)
        XCTAssertEqual(aggregate.sampleCount, 2)
        XCTAssertEqual(aggregate.rawSampleCount, 2)
    }

    func testBodyMassUsesLatestPositiveMeasurement() throws {
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let summary = DailyHealthSampleSummary(samples: [
            sample(820, metric: .bodyMass, at: day.addingTimeInterval(60), value: 70),
            sample(821, metric: .bodyMass, at: day.addingTimeInterval(120), value: 0),
        ], dayStart: day)

        let aggregate = try XCTUnwrap(summary.aggregate(for: .bodyMass))
        XCTAssertEqual(aggregate.latestValue, 70)
        XCTAssertEqual(aggregate.representativeValue, 70)
        XCTAssertEqual(aggregate.sampleCount, 1)
        XCTAssertEqual(aggregate.rawSampleCount, 1)
    }

    private func sample(
        _ id: Int,
        metric: HealthMetricID,
        at date: Date,
        value: Double
    ) -> HealthSampleSnapshot {
        HealthSampleSnapshot(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", id))!,
            metric: metric,
            startDate: date,
            endDate: date,
            value: value
        )
    }
}

private extension HealthSampleSnapshot {
    func withSource(_ bundleIdentifier: String, device: String) -> HealthSampleSnapshot {
        HealthSampleSnapshot(
            id: id,
            metric: metric,
            startDate: startDate,
            endDate: endDate,
            value: value,
            categoryValue: categoryValue,
            sourceBundleIdentifier: bundleIdentifier,
            deviceName: deviceName,
            deviceModel: device,
            syncIdentifier: syncIdentifier,
            syncVersion: syncVersion
        )
    }
}
