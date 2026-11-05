import Foundation
import XCTest
@testable import DensosoDomain

final class HealthIntelligenceTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        value.firstWeekday = 2
        return value
    }

    func testSleepUnionHandlesCrossMidnightStagesAwakeAndNapWithoutDoubleCounting() throws {
        let wakeDate = try date(2026, 2, 2)
        let samples = [
            sleep(wakeDate, start: (-1, 22, 0), end: (-1, 23, 30), stage: .asleepCore),
            sleep(wakeDate, start: (-1, 23, 30), end: (0, 1, 0), stage: .asleepDeep),
            sleep(wakeDate, start: (0, 1, 0), end: (0, 2, 0), stage: .asleepREM),
            sleep(wakeDate, start: (0, 2, 0), end: (0, 4, 30), stage: .asleepCore),
            sleep(wakeDate, start: (0, 2, 30), end: (0, 3, 0), stage: .asleepCore), // overlapping duplicate
            sleep(wakeDate, start: (0, 4, 30), end: (0, 5, 30), stage: .awake),
            sleep(wakeDate, start: (0, 5, 30), end: (0, 6, 30), stage: .asleepUnspecified),
            sleep(wakeDate, start: (0, 13, 0), end: (0, 13, 40), stage: .asleepUnspecified),
            sleep(wakeDate, start: (-1, 21, 30), end: (0, 7, 0), stage: .inBed),
        ]

        let summary = try XCTUnwrap(HealthIntelligenceEngine(calendar: calendar).sleepSummary(for: wakeDate, samples: samples))
        XCTAssertEqual(summary.totalAsleepMinutes, 490, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(summary.mainSleepMinutes), 390, accuracy: 0.001)
        XCTAssertEqual(summary.napMinutes, 100, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(summary.stageCoverage), 1, accuracy: 0.001)
        let stages = try XCTUnwrap(summary.stages)
        XCTAssertEqual(stages.core, 240, accuracy: 0.001)
        XCTAssertEqual(stages.deep, 90, accuracy: 0.001)
        XCTAssertEqual(stages.rem, 60, accuracy: 0.001)
    }

    func testSleepPrefersWatchAndHidesStagesBelowSixtyPercentCoverage() throws {
        let wakeDate = try date(2026, 3, 10)
        let watch = sleep(
            wakeDate,
            start: (-1, 23, 0),
            end: (0, 0, 40),
            stage: .asleepUnspecified,
            device: "Watch8,1"
        )
        let phone = sleep(
            wakeDate,
            start: (-1, 23, 0),
            end: (0, 0, 40),
            stage: .asleepCore,
            source: "com.example.sleep"
        )
        let phoneNap = sleep(
            wakeDate,
            start: (0, 13, 0),
            end: (0, 13, 40),
            stage: .asleepUnspecified,
            source: "com.example.sleep"
        )
        let preferred = try XCTUnwrap(
            HealthIntelligenceEngine(calendar: calendar).sleepSummary(for: wakeDate, samples: [phone, phoneNap, watch])
        )
        XCTAssertEqual(preferred.totalAsleepMinutes, 140, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(preferred.mainSleepMinutes), 100, accuracy: 0.001)
        XCTAssertEqual(preferred.napMinutes, 40, accuracy: 0.001)
        XCTAssertEqual(preferred.selectedSourceBundleIdentifier, "com.apple.watchkitapp")

        let incompleteStages = [
            sleep(wakeDate, start: (-1, 23, 0), end: (0, 0, 0), stage: .asleepCore),
            sleep(wakeDate, start: (0, 0, 0), end: (0, 1, 30), stage: .asleepUnspecified),
        ]
        let staged = try XCTUnwrap(HealthIntelligenceEngine(calendar: calendar).sleepSummary(for: wakeDate, samples: incompleteStages))
        XCTAssertLessThan(try XCTUnwrap(staged.stageCoverage), 0.60)
        XCTAssertNil(staged.stages)
    }

    func testSleepDoesNotDoubleCountOverlappingNonWatchSourcesOutsideWatchCoverage() throws {
        let wakeDate = try date(2026, 3, 11)
        let watch = sleep(
            wakeDate,
            start: (-1, 23, 0),
            end: (0, 0, 0),
            stage: .asleepUnspecified,
            device: "Watch8,1"
        )
        let phoneA = sleep(
            wakeDate,
            start: (-1, 23, 30),
            end: (0, 2, 0),
            stage: .asleepCore,
            source: "com.example.sleep-a"
        )
        let phoneB = sleep(
            wakeDate,
            start: (0, 0, 0),
            end: (0, 2, 0),
            stage: .asleepDeep,
            source: "com.example.sleep-b"
        )

        let summary = try XCTUnwrap(
            HealthIntelligenceEngine(calendar: calendar).sleepSummary(
                for: wakeDate,
                samples: [watch, phoneA, phoneB]
            )
        )

        XCTAssertEqual(summary.totalAsleepMinutes, 180, accuracy: 0.001)
        let stages = try XCTUnwrap(summary.stages)
        XCTAssertEqual(stages.core + stages.deep + stages.rem, 120, accuracy: 0.001)
    }

    func testOverlappingDifferentSleepStagesDoNotDoubleCount() throws {
        let wakeDate = try date(2026, 3, 12)
        let samples = [
            sleep(wakeDate, start: (-1, 23, 0), end: (0, 1, 0), stage: .asleepCore),
            sleep(wakeDate, start: (0, 0, 0), end: (0, 2, 0), stage: .asleepDeep),
        ]

        let summary = try XCTUnwrap(HealthIntelligenceEngine(calendar: calendar).sleepSummary(
            for: wakeDate,
            samples: samples
        ))

        XCTAssertEqual(summary.totalAsleepMinutes, 180, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(summary.mainSleepMinutes), 180, accuracy: 0.001)
        XCTAssertTrue(summary.hasConflictingSourceStages)
        let stages = try XCTUnwrap(summary.stages)
        XCTAssertEqual(stages.core, 60, accuracy: 0.001)
        XCTAssertEqual(stages.deep, 120, accuracy: 0.001)
        XCTAssertLessThanOrEqual(stages.core + stages.deep + stages.rem, summary.mainSleepMinutes ?? 0)
        XCTAssertEqual(try XCTUnwrap(summary.stageCoverage), 1, accuracy: 0.001)
    }

    func testSleepStageDurationsNeverExceedMainSleepAndDuplicateStagesAreDeterministic() throws {
        let wakeDate = try date(2026, 3, 13)
        let samples = [
            sleep(wakeDate, start: (-1, 22, 30), end: (0, 2, 0), stage: .asleepCore),
            sleep(wakeDate, start: (-1, 23, 30), end: (0, 1, 0), stage: .asleepDeep),
            sleep(wakeDate, start: (0, 0, 30), end: (0, 1, 30), stage: .asleepREM),
            sleep(wakeDate, start: (0, 0, 30), end: (0, 1, 30), stage: .asleepREM),
        ]
        let engine = HealthIntelligenceEngine(calendar: calendar)

        let forward = try XCTUnwrap(engine.sleepSummary(for: wakeDate, samples: samples))
        let reversed = try XCTUnwrap(engine.sleepSummary(for: wakeDate, samples: Array(samples.reversed())))

        XCTAssertEqual(forward, reversed)
        let stages = try XCTUnwrap(forward.stages)
        let mainMinutes = try XCTUnwrap(forward.mainSleepMinutes)
        XCTAssertLessThanOrEqual(stages.core + stages.deep + stages.rem, mainMinutes)
        XCTAssertEqual(stages.core, 90, accuracy: 0.001)
        XCTAssertEqual(stages.deep, 90, accuracy: 0.001)
        XCTAssertEqual(stages.rem, 30, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(forward.stageCoverage), 1, accuracy: 0.001)
    }

    func testOverlappingSleepStagesAcrossSourcesRemainNonOverlapping() throws {
        let wakeDate = try date(2026, 3, 14)
        let watch = sleep(
            wakeDate,
            start: (-1, 23, 0),
            end: (0, 1, 0),
            stage: .asleepCore,
            source: "com.apple.watchkitapp",
            device: "Watch10,1"
        )
        let thirdParty = sleep(
            wakeDate,
            start: (0, 0, 0),
            end: (0, 2, 0),
            stage: .asleepDeep,
            source: "com.example.sleep"
        )

        let summary = try XCTUnwrap(HealthIntelligenceEngine(calendar: calendar).sleepSummary(
            for: wakeDate,
            samples: [thirdParty, watch]
        ))

        XCTAssertEqual(summary.totalAsleepMinutes, 180, accuracy: 0.001)
        XCTAssertEqual(summary.selectedSourceBundleIdentifier, "com.apple.watchkitapp")
        XCTAssertEqual(
            summary.selectedSourceIdentifier,
            "bundle:21:com.apple.watchkitapp|device:9:Watch10,1"
        )
        XCTAssertEqual(summary.supplementalSourceIdentifiers, ["com.example.sleep"])
        let stages = try XCTUnwrap(summary.stages)
        XCTAssertEqual(stages.core, 120, accuracy: 0.001)
        XCTAssertEqual(stages.deep, 60, accuracy: 0.001)
        XCTAssertEqual(stages.core + stages.deep + stages.rem, 180, accuracy: 0.001)
        XCTAssertTrue(summary.hasConflictingSourceStages)
    }

    func testSameBundleWatchSleepIsNotVetoedByPhoneAwakeAndIsOrderIndependent() throws {
        let wakeDate = try date(2026, 3, 23)
        let bundle = "com.example.sleep"
        let watchSleep = sleep(
            wakeDate,
            start: (-1, 23, 0),
            end: (0, 7, 0),
            stage: .asleepCore,
            source: bundle,
            device: "Watch10,1"
        )
        let phoneAwake = sleep(
            wakeDate,
            start: (0, 2, 0),
            end: (0, 3, 0),
            stage: .awake,
            source: bundle,
            device: "iPhone17,1"
        )
        let engine = HealthIntelligenceEngine(calendar: calendar)

        let summary = try XCTUnwrap(engine.sleepSummary(for: wakeDate, samples: [watchSleep, phoneAwake]))
        let reversed = try XCTUnwrap(engine.sleepSummary(for: wakeDate, samples: [phoneAwake, watchSleep]))

        XCTAssertEqual(summary, reversed)
        XCTAssertEqual(summary.totalAsleepMinutes, 480, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(summary.mainSleepMinutes), 480, accuracy: 0.001)
        XCTAssertEqual(summary.selectedSourceBundleIdentifier, bundle)
        XCTAssertEqual(
            summary.selectedSourceIdentifier,
            "bundle:\(bundle.utf8.count):\(bundle)|device:9:Watch10,1"
        )
        XCTAssertEqual(summary.sourceCoverage, [
            SleepSourceCoverage(
                sourceIdentifier: "bundle:\(bundle.utf8.count):\(bundle)|device:9:Watch10,1",
                asleepMinutes: 480
            ),
        ])
        XCTAssertTrue(summary.hasConflictingSourceStages)
    }

    func testNonWatchSourcesSupplementUncoveredSleepIntervals() throws {
        let wakeDate = try date(2026, 3, 15)
        let sourceA = sleep(
            wakeDate,
            start: (-1, 23, 0),
            end: (0, 2, 0),
            stage: .asleepCore,
            source: "com.example.sleep-a"
        )
        let sourceB = sleep(
            wakeDate,
            start: (0, 2, 0),
            end: (0, 7, 0),
            stage: .asleepREM,
            source: "com.example.sleep-b"
        )
        let engine = HealthIntelligenceEngine(calendar: calendar)

        let summary = try XCTUnwrap(engine.sleepSummary(for: wakeDate, samples: [sourceA, sourceB]))
        let reversed = try XCTUnwrap(engine.sleepSummary(for: wakeDate, samples: [sourceB, sourceA]))

        XCTAssertEqual(summary, reversed)
        XCTAssertEqual(summary.totalAsleepMinutes, 480, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(summary.mainSleepMinutes), 480, accuracy: 0.001)
        XCTAssertEqual(summary.selectedSourceBundleIdentifier, "com.example.sleep-b")
        XCTAssertEqual(summary.selectedSourceIdentifier, "com.example.sleep-b")
        XCTAssertEqual(summary.supplementalSourceIdentifiers, ["com.example.sleep-a"])
        XCTAssertFalse(summary.hasConflictingSourceStages)
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: summary.sourceCoverage.map { ($0.sourceIdentifier, $0.asleepMinutes) }),
            ["com.example.sleep-a": 180, "com.example.sleep-b": 300]
        )
    }

    func testNonWatchOverlappingSourcesDoNotDoubleCountAndTieBreakIsDeterministic() throws {
        let wakeDate = try date(2026, 3, 16)
        let sourceA = sleep(
            wakeDate,
            start: (-1, 23, 0),
            end: (0, 4, 0),
            stage: .asleepCore,
            source: "com.example.sleep-a"
        )
        let sourceB = sleep(
            wakeDate,
            start: (-1, 23, 0),
            end: (0, 4, 0),
            stage: .asleepDeep,
            source: "com.example.sleep-b"
        )
        let engine = HealthIntelligenceEngine(calendar: calendar)

        let first = try XCTUnwrap(engine.sleepSummary(for: wakeDate, samples: [sourceB, sourceA]))
        let reversed = try XCTUnwrap(engine.sleepSummary(for: wakeDate, samples: [sourceA, sourceB]))

        XCTAssertEqual(first, reversed)
        XCTAssertEqual(first.totalAsleepMinutes, 300, accuracy: 0.001)
        XCTAssertEqual(first.selectedSourceBundleIdentifier, "com.example.sleep-a")
        XCTAssertTrue(first.supplementalSourceIdentifiers.isEmpty)
        XCTAssertEqual(first.sourceCoverage, [SleepSourceCoverage(sourceIdentifier: "com.example.sleep-a", asleepMinutes: 300)])
        XCTAssertTrue(first.hasConflictingSourceStages)
    }

    func testSelectedSleepSourceMustContributeAfterSameSourceAwakeResolution() throws {
        let wakeDate = try date(2026, 3, 21)
        let preferredButVetoed = [
            sleep(
                wakeDate,
                start: (-1, 23, 0),
                end: (0, 1, 0),
                stage: .asleepCore,
                source: "com.apple.watch-a",
                device: "Watch10,1"
            ),
            sleep(
                wakeDate,
                start: (-1, 23, 0),
                end: (0, 1, 0),
                stage: .awake,
                source: "com.apple.watch-a",
                device: "Watch10,1"
            ),
        ]
        let contributing = sleep(
            wakeDate,
            start: (0, 0, 0),
            end: (0, 2, 0),
            stage: .asleepCore,
            source: "com.apple.watch-b",
            device: "Watch11,1"
        )

        let summary = try XCTUnwrap(HealthIntelligenceEngine(calendar: calendar).sleepSummary(
            for: wakeDate,
            samples: preferredButVetoed + [contributing]
        ))

        XCTAssertEqual(summary.totalAsleepMinutes, 60, accuracy: 0.001)
        XCTAssertEqual(summary.selectedSourceBundleIdentifier, "com.apple.watch-b")
        XCTAssertEqual(summary.selectedSourceIdentifier, "bundle:17:com.apple.watch-b|device:9:Watch11,1")
        XCTAssertTrue(summary.supplementalSourceIdentifiers.isEmpty)
        XCTAssertEqual(summary.sourceCoverage, [
            SleepSourceCoverage(
                sourceIdentifier: "bundle:17:com.apple.watch-b|device:9:Watch11,1",
                asleepMinutes: 60
            ),
        ])
    }

    func testHigherPriorityAwakeOnlySourcePreventsConflictingSleepFill() throws {
        let wakeDate = try date(2026, 3, 22)
        let watchAwake = sleep(
            wakeDate,
            start: (0, 0, 0),
            end: (0, 1, 0),
            stage: .awake,
            source: "com.apple.watchkitapp",
            device: "Watch10,1"
        )
        let thirdPartyAsleep = sleep(
            wakeDate,
            start: (0, 0, 0),
            end: (0, 1, 0),
            stage: .asleepCore,
            source: "com.example.sleep"
        )

        let summary = try XCTUnwrap(HealthIntelligenceEngine(calendar: calendar).sleepSummary(
            for: wakeDate,
            samples: [thirdPartyAsleep, watchAwake]
        ))

        XCTAssertNil(summary.mainSleepMinutes)
        XCTAssertTrue(summary.hasConflictingSourceStages)
        XCTAssertTrue(summary.sourceCoverage.isEmpty)
    }

    func testBriefAwakeGapDoesNotSplitMainSleepEpisode() throws {
        let wakeDate = try date(2026, 3, 17)
        let samples = [
            sleep(wakeDate, start: (-1, 23, 0), end: (0, 2, 0), stage: .asleepCore),
            sleep(wakeDate, start: (0, 2, 0), end: (0, 2, 5), stage: .awake),
            sleep(wakeDate, start: (0, 2, 5), end: (0, 7, 0), stage: .asleepREM),
        ]

        let summary = try XCTUnwrap(HealthIntelligenceEngine(calendar: calendar).sleepSummary(
            for: wakeDate,
            samples: samples
        ))

        XCTAssertEqual(summary.totalAsleepMinutes, 475, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(summary.mainSleepMinutes), 475, accuracy: 0.001)
        XCTAssertEqual(summary.napMinutes, 0, accuracy: 0.001)
        let stages = try XCTUnwrap(summary.stages)
        XCTAssertEqual(stages.core + stages.rem, 475, accuracy: 0.001)
    }

    func testLongAwakeGapSeparatesIndependentSleepEpisodesAndNapUsesEpisodeTotals() throws {
        let wakeDate = try date(2026, 3, 18)
        let samples = [
            sleep(wakeDate, start: (-1, 23, 0), end: (0, 2, 0), stage: .asleepCore),
            sleep(wakeDate, start: (0, 2, 0), end: (0, 3, 0), stage: .awake),
            sleep(wakeDate, start: (0, 3, 0), end: (0, 7, 0), stage: .asleepREM),
            sleep(wakeDate, start: (0, 13, 0), end: (0, 14, 0), stage: .asleepUnspecified),
        ]

        let summary = try XCTUnwrap(HealthIntelligenceEngine(calendar: calendar).sleepSummary(
            for: wakeDate,
            samples: samples
        ))

        XCTAssertEqual(summary.totalAsleepMinutes, 480, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(summary.mainSleepMinutes), 240, accuracy: 0.001)
        XCTAssertEqual(summary.napMinutes, 240, accuracy: 0.001)
    }

    func testAwakeDurationIsExcludedFromAsleepMinutesAndSleepStages() throws {
        let wakeDate = try date(2026, 3, 19)
        let samples = [
            sleep(wakeDate, start: (-1, 23, 0), end: (0, 2, 0), stage: .asleepCore),
            sleep(wakeDate, start: (0, 2, 0), end: (0, 2, 20), stage: .awake),
            sleep(wakeDate, start: (0, 2, 20), end: (0, 7, 0), stage: .asleepREM),
        ]

        let summary = try XCTUnwrap(HealthIntelligenceEngine(calendar: calendar).sleepSummary(
            for: wakeDate,
            samples: samples
        ))

        XCTAssertEqual(summary.totalAsleepMinutes, 460, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(summary.mainSleepMinutes), 460, accuracy: 0.001)
        let stages = try XCTUnwrap(summary.stages)
        XCTAssertEqual(stages.core, 180, accuracy: 0.001)
        XCTAssertEqual(stages.rem, 280, accuracy: 0.001)
        XCTAssertEqual(stages.core + stages.rem, summary.mainSleepMinutes ?? 0, accuracy: 0.001)
    }

    func testSleepEpisodeDurationUsesAbsoluteTimeAcrossDaylightSavingChange() throws {
        var daylightCalendar = Calendar(identifier: .gregorian)
        daylightCalendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let wakeDate = try XCTUnwrap(daylightCalendar.date(from: DateComponents(
            year: 2026,
            month: 3,
            day: 8,
            hour: 12
        )))
        let start = try XCTUnwrap(daylightCalendar.date(from: DateComponents(
            year: 2026,
            month: 3,
            day: 8,
            hour: 0,
            minute: 30
        )))
        let end = try XCTUnwrap(daylightCalendar.date(from: DateComponents(
            year: 2026,
            month: 3,
            day: 8,
            hour: 7
        )))
        let sample = SleepSampleInterval(startDate: start, endDate: end, stage: .asleepCore)

        let summary = try XCTUnwrap(HealthIntelligenceEngine(calendar: daylightCalendar).sleepSummary(
            for: wakeDate,
            samples: [sample]
        ))

        XCTAssertEqual(summary.totalAsleepMinutes, 330, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(summary.mainSleepMinutes), 330, accuracy: 0.001)
    }

    func testSleepSummaryPersistsSelectedSourcesAndDecodesLegacyPayload() throws {
        let wakeDate = try date(2026, 3, 20)
        let primary = sleep(
            wakeDate,
            start: (-1, 23, 0),
            end: (0, 2, 0),
            stage: .asleepCore,
            source: "com.example.primary"
        )
        let supplemental = sleep(
            wakeDate,
            start: (0, 2, 0),
            end: (0, 7, 0),
            stage: .asleepDeep,
            source: "com.example.supplemental"
        )
        let summary = try XCTUnwrap(HealthIntelligenceEngine(calendar: calendar).sleepSummary(
            for: wakeDate,
            samples: [primary, supplemental]
        ))

        XCTAssertEqual(summary.algorithmVersion, AlgorithmVersions.healthIntelligence)
        XCTAssertEqual(summary.selectedSourceIdentifier, "com.example.supplemental")
        XCTAssertEqual(summary.supplementalSourceIdentifiers, ["com.example.primary"])
        let roundTrip = try JSONDecoder().decode(SleepSummary.self, from: JSONEncoder().encode(summary))
        XCTAssertEqual(roundTrip, summary)

        let legacyPayload = Data("""
        {"wakeDate":0,"totalAsleepMinutes":240,"mainSleepMinutes":240,"napMinutes":0,"stageCoverage":null,"stages":null,"selectedSourceBundleIdentifier":null}
        """.utf8)
        let legacy = try JSONDecoder().decode(SleepSummary.self, from: legacyPayload)
        XCTAssertEqual(legacy.algorithmVersion, SleepSummary.legacyAlgorithmVersion)
        XCTAssertNil(legacy.selectedSourceIdentifier)
        XCTAssertTrue(legacy.supplementalSourceIdentifiers.isEmpty)
        XCTAssertTrue(legacy.sourceCoverage.isEmpty)
    }

    func testBaselineReadinessAndZeroMADDoNotCreateAnomaly() throws {
        let engine = HealthIntelligenceEngine(calendar: calendar)
        let asOf = try date(2026, 4, 1)
        XCTAssertEqual(engine.baseline(for: points(6, endingBefore: asOf, value: 5), before: asOf).readiness, .learning)
        XCTAssertEqual(engine.baseline(for: points(7, endingBefore: asOf, value: 5), before: asOf).readiness, .temporary)
        XCTAssertEqual(engine.baseline(for: points(28, endingBefore: asOf, value: 5), before: asOf).readiness, .mature)

        let stable = engine.baseline(for: points(28, endingBefore: asOf, value: 5), before: asOf)
        XCTAssertNil(stable.robustZScore(for: 100))
        XCTAssertFalse(stable.isSignificantChange(100))
    }

    func testBaselineUsesRobustOutlierRuleAndIgnoresInvalidValues() throws {
        let engine = HealthIntelligenceEngine(calendar: calendar)
        let asOf = try date(2026, 5, 1)
        var values = points(28, endingBefore: asOf, value: 5)
        values[0] = (date: calendar.date(byAdding: .day, value: -35, to: asOf)!, value: .nan)
        let baseline = engine.baseline(for: values, before: asOf)
        XCTAssertEqual(baseline.validDays, 27)
        XCTAssertEqual(baseline.readiness, .temporary)
        XCTAssertFalse(baseline.isSignificantChange(100))
    }

    func testTrainingLoadMaturityAndAllLoadRatioBoundaries() throws {
        let engine = HealthIntelligenceEngine(calendar: calendar)
        let asOf = try date(2026, 6, 30)

        func load(ratio: Double) -> TrainingLoadSummary {
            var workouts: [TrainingWorkoutInput] = []
            for offset in -34 ... -7 {
                workouts.append(TrainingWorkoutInput(
                    startedAt: calendar.date(byAdding: .day, value: offset, to: asOf)!,
                    durationMinutes: 20,
                    effortScore: 5
                ))
            }
            for offset in -6 ... 0 {
                workouts.append(TrainingWorkoutInput(
                    startedAt: calendar.date(byAdding: .day, value: offset, to: asOf)!,
                    durationMinutes: 20,
                    effortScore: 5 * ratio
                ))
            }
            return engine.trainingLoad(workouts: workouts, asOf: asOf)
        }

        XCTAssertEqual(load(ratio: 0.74).band, .belowTypical)
        XCTAssertEqual(load(ratio: 0.75).band, .gradualReturn)
        XCTAssertEqual(load(ratio: 0.90).band, .nearTypical)
        XCTAssertEqual(load(ratio: 1.10).band, .increased)
        XCTAssertEqual(load(ratio: 1.30).band, .sharplyIncreased)
        XCTAssertEqual(load(ratio: 1.10).readiness, .mature)

        let immature = engine.trainingLoad(
            workouts: [
                TrainingWorkoutInput(
                    startedAt: calendar.date(byAdding: .day, value: -7, to: asOf)!,
                    durationMinutes: 30,
                    effortScore: nil,
                    intensity: "light"
                ),
                TrainingWorkoutInput(startedAt: asOf, durationMinutes: 30, effortScore: nil, intensity: nil),
                TrainingWorkoutInput(startedAt: asOf, durationMinutes: 30, effortScore: nil, intensity: "light"),
            ],
            asOf: asOf
        )
        XCTAssertEqual(immature.readiness, .learning)
        XCTAssertNil(immature.ratio)
        XCTAssertEqual(immature.estimatedWorkoutCount, 2)
        XCTAssertEqual(immature.unavailableEffortCount, 1)
    }

    func testTrainingLoadCountsObservedRestDaysTowardMaturity() throws {
        let engine = HealthIntelligenceEngine(calendar: calendar)
        let asOf = try date(2026, 7, 31)
        let priorWorkoutOffsets = [-33, -29, -25, -21, -17, -13, -9]
        var workouts = priorWorkoutOffsets.map { offset in
            TrainingWorkoutInput(
                startedAt: calendar.date(byAdding: .day, value: offset, to: asOf)!,
                durationMinutes: 60,
                effortScore: 5
            )
        }
        workouts.append(TrainingWorkoutInput(
            startedAt: calendar.date(byAdding: .day, value: -2, to: asOf)!,
            durationMinutes: 60,
            effortScore: 5
        ))

        let load = engine.trainingLoad(workouts: workouts, asOf: asOf)

        XCTAssertEqual(load.readiness, .mature)
        XCTAssertEqual(try XCTUnwrap(load.priorTwentyEightDayAverage), 525, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(load.ratio), 300.0 / 525, accuracy: 0.001)
    }

    func testTrainingLoadMakesComparisonUnavailableWhenEffortIsUnknownInWindow() throws {
        let engine = HealthIntelligenceEngine(calendar: calendar)
        let asOf = try date(2026, 8, 31)
        var workouts = [-33, -29, -25, -21, -17, -13, -9].map { offset in
            TrainingWorkoutInput(
                startedAt: calendar.date(byAdding: .day, value: offset, to: asOf)!,
                durationMinutes: 60,
                effortScore: 5
            )
        }
        workouts.append(TrainingWorkoutInput(
            startedAt: calendar.date(byAdding: .day, value: -2, to: asOf)!,
            durationMinutes: 60,
            effortScore: nil,
            intensity: nil
        ))

        let load = engine.trainingLoad(workouts: workouts, asOf: asOf)

        XCTAssertEqual(load.readiness, .mature)
        XCTAssertNil(load.ratio)
        XCTAssertEqual(load.band, .unavailable)
        XCTAssertEqual(load.unavailableEffortCount, 1)
        XCTAssertEqual(load.dataCoverage, .partial)
        let encodedLoad = try JSONEncoder().encode(load)
        let encodedLoadObject = try XCTUnwrap(JSONSerialization.jsonObject(with: encodedLoad) as? [String: Any])
        XCTAssertEqual(encodedLoadObject["dataCoverage"] as? String, HealthDataCoverage.partial.rawValue)
        XCTAssertNil(encodedLoadObject["recentSevenDayLoad"])
        XCTAssertNil(encodedLoadObject["priorTwentyEightDayAverage"])
        XCTAssertNil(encodedLoadObject["ratio"])

        var priorUnknown = Array(workouts.dropLast())
        priorUnknown.append(TrainingWorkoutInput(
            startedAt: calendar.date(byAdding: .day, value: -11, to: asOf)!,
            durationMinutes: 60,
            effortScore: nil,
            intensity: nil
        ))
        priorUnknown.append(workouts.last!)
        let priorLoad = engine.trainingLoad(workouts: priorUnknown, asOf: asOf)
        XCTAssertNil(priorLoad.ratio)
        XCTAssertNil(priorLoad.priorTwentyEightDayAverage)
        XCTAssertEqual(priorLoad.band, .unavailable)
        XCTAssertEqual(priorLoad.unavailableEffortCount, 2)
        XCTAssertEqual(priorLoad.dataCoverage, .partial)
    }

    func testManualWorkoutEffortEstimateDoesNotBecomeUnknownHealthKitEffort() throws {
        let engine = HealthIntelligenceEngine(calendar: calendar)
        let asOf = try date(2026, 8, 31)
        let load = engine.trainingLoad(
            workouts: [TrainingWorkoutInput(
                startedAt: calendar.date(byAdding: .day, value: -2, to: asOf)!,
                durationMinutes: 30,
                effortScore: nil,
                intensity: "moderate"
            )],
            asOf: asOf,
            dataCoverage: .complete
        )

        XCTAssertEqual(load.dataCoverage, .complete)
        XCTAssertEqual(load.estimatedWorkoutCount, 1)
        XCTAssertEqual(load.unavailableEffortCount, 0)
    }

    func testDailyBriefMakesLoadCoveragePartialWhenWorkoutEffortIsUnknown() throws {
        let engine = HealthIntelligenceEngine(calendar: calendar)
        let asOf = try date(2026, 9, 30)
        var days: [HealthIntelligenceDay] = []
        for offset in -34 ... 0 {
            let day = calendar.date(byAdding: .day, value: offset, to: asOf)!
            let hasUnknownEffort = offset == -2
            let workouts = offset == -2
                ? [TrainingWorkoutInput(startedAt: day, durationMinutes: 45)]
                : ([-33, -29, -25, -21, -17, -13, -9].contains(offset)
                    ? [TrainingWorkoutInput(startedAt: day, durationMinutes: 45, effortScore: 5)]
                    : [])
            days.append(HealthIntelligenceDay(
                dayStart: day,
                workouts: workouts,
                healthReadStates: [
                    HealthMetricID.workout.rawValue: .available,
                    HealthMetricID.workoutEffort.rawValue: hasUnknownEffort
                        ? .dataUnavailableOrReadScopeUnknown
                        : .available,
                ]
            ))
        }

        let result = try XCTUnwrap(engine.makeDailyBrief(days: days))
        XCTAssertEqual(result.dailyBrief.trainingLoad.dataCoverage, .partial)
        XCTAssertNil(result.dailyBrief.trainingLoad.ratio)
        XCTAssertEqual(result.dailyBrief.trainingLoad.band, .unavailable)
    }

    func testWorkoutEffortReadStateMakesDependentDailyAndWeeklyLoadPartialButPreservesManualEstimates() throws {
        let engine = HealthIntelligenceEngine(calendar: calendar)
        let asOf = try date(2026, 9, 30)
        let baselineWorkoutOffsets: Set<Int> = [-33, -29, -25, -21, -17, -13, -9]

        func days(currentWorkoutRequiresHealthKitEffort: Bool) -> [HealthIntelligenceDay] {
            (-34...0).compactMap { offset in
                guard let day = calendar.date(byAdding: .day, value: offset, to: asOf) else { return nil }
                let workouts: [TrainingWorkoutInput]
                if baselineWorkoutOffsets.contains(offset) {
                    workouts = [TrainingWorkoutInput(
                        startedAt: day,
                        durationMinutes: 45,
                        effortScore: 5,
                        intensity: "unknown",
                        requiresHealthKitEffort: true
                    )]
                } else if offset == -2 {
                    workouts = [TrainingWorkoutInput(
                        startedAt: day,
                        durationMinutes: 45,
                        intensity: "moderate",
                        requiresHealthKitEffort: currentWorkoutRequiresHealthKitEffort
                    )]
                } else {
                    workouts = []
                }
                return HealthIntelligenceDay(
                    dayStart: day,
                    workouts: workouts,
                    healthReadStates: [
                        HealthMetricID.workout.rawValue: .available,
                        HealthMetricID.workoutEffort.rawValue: offset == -2
                            ? .dataUnavailableOrReadScopeUnknown
                            : .available,
                    ]
                )
            }
        }

        let weekStart = try XCTUnwrap(calendar.date(byAdding: .day, value: -6, to: asOf))
        let healthKitDependentDays = days(currentWorkoutRequiresHealthKitEffort: true)
        let daily = try XCTUnwrap(engine.makeDailyBrief(days: healthKitDependentDays)?.dailyBrief.trainingLoad)
        let weekly = engine.makeWeeklyBrief(days: healthKitDependentDays, weekStart: weekStart).trainingLoad

        XCTAssertEqual(daily.dataCoverage, .partial)
        XCTAssertEqual(weekly.dataCoverage, .partial)
        XCTAssertNotNil(daily.ratio, "The coverage flag, rather than nil effort alone, must withhold the estimated result from JSON")
        for summary in [daily, weekly] {
            let encoded = try JSONEncoder().encode(summary)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            XCTAssertEqual(object["dataCoverage"] as? String, HealthDataCoverage.partial.rawValue)
            XCTAssertEqual(object["readiness"] as? String, BaselineReadiness.mature.rawValue)
            XCTAssertNil(object["recentSevenDayLoad"])
            XCTAssertNil(object["priorTwentyEightDayAverage"])
            XCTAssertNil(object["ratio"])
            XCTAssertNil(object["band"])
            XCTAssertNil(object["estimatedWorkoutCount"])
            XCTAssertNil(object["unavailableEffortCount"])
        }

        let manualDays = days(currentWorkoutRequiresHealthKitEffort: false)
        let manualDaily = try XCTUnwrap(engine.makeDailyBrief(days: manualDays)?.dailyBrief.trainingLoad)
        let manualWeekly = engine.makeWeeklyBrief(days: manualDays, weekStart: weekStart).trainingLoad
        XCTAssertEqual(manualDaily.dataCoverage, .complete)
        XCTAssertEqual(manualDaily.estimatedWorkoutCount, 1)
        XCTAssertNotNil(manualDaily.ratio)
        XCTAssertEqual(manualWeekly.dataCoverage, .complete)
        XCTAssertEqual(manualWeekly.estimatedWorkoutCount, 1)
        XCTAssertNotNil(manualWeekly.ratio)
    }

    func testTrainingWorkoutInputLegacyDecodeInfersHealthKitEffortDependency() throws {
        let legacyUnknownIntensity = Data(
            #"{"startedAt":0,"durationMinutes":30,"effortScore":null,"intensity":"unknown"}"#.utf8
        )
        let decodedHealthKitInput = try JSONDecoder().decode(TrainingWorkoutInput.self, from: legacyUnknownIntensity)
        XCTAssertTrue(decodedHealthKitInput.requiresHealthKitEffort)

        let legacyManualIntensity = Data(
            #"{"startedAt":0,"durationMinutes":30,"intensity":"moderate"}"#.utf8
        )
        let decodedManualInput = try JSONDecoder().decode(TrainingWorkoutInput.self, from: legacyManualIntensity)
        XCTAssertFalse(decodedManualInput.requiresHealthKitEffort)

        let encodedHealthKitInput = try JSONEncoder().encode(decodedHealthKitInput)
        let roundTrippedHealthKitInput = try JSONDecoder().decode(TrainingWorkoutInput.self, from: encodedHealthKitInput)
        XCTAssertEqual(roundTrippedHealthKitInput, decodedHealthKitInput)
    }

    func testBriefUsesFourIndependentDomainsTwoRecommendationsAndAggregatedCloudContext() throws {
        let engine = HealthIntelligenceEngine(calendar: calendar)
        let today = try date(2026, 7, 29)
        var days: [HealthIntelligenceDay] = []
        for offset in -28 ... -1 {
            let variance = Double((offset + 28) % 5)
            let wake = calendar.date(byAdding: .day, value: offset, to: today)!
            days.append(HealthIntelligenceDay(
                dayStart: wake,
                energyIntakeKcal: 1_800 + variance * 50,
                stepCount: 6_000 + variance * 200,
                weightSamplesKilograms: [70 + variance * 0.2],
                sleepSamples: [
                    sleep(wake, start: (-1, 22, 0), end: (0, 6, 0), stage: .asleepCore),
                ]
            ))
        }
        days.append(HealthIntelligenceDay(
            dayStart: today,
            energyIntakeKcal: 3_500,
            stepCount: 18_000,
            weightSamplesKilograms: [73],
            sleepSamples: [
                sleep(today, start: (-1, 22, 0), end: (0, 1, 0), stage: .asleepCore),
            ]
        ))

        let result = try XCTUnwrap(engine.makeDailyBrief(
            days: days,
            goals: GoalProfile(effectiveFrom: today, targetWeightKilograms: 68, dailyDeficitKcal: 400)
        ))
        XCTAssertEqual(result.dailyBrief.domains.map(\.domain), HealthDomain.allCases)
        XCTAssertEqual(result.dailyBrief.healthState?.domains.map(\.domain), HealthDomain.allCases)
        XCTAssertEqual(result.dailyBrief.healthState?.recovery.status, .insufficientEvidence)
        XCTAssertEqual(result.dailyBrief.healthState?.recovery.recommendedAction, .collectData)
        XCTAssertLessThanOrEqual(result.dailyBrief.recommendations.count, 2)
        XCTAssertEqual(
            Set(result.dailyBrief.recommendations.map(\.conflictGroup)).count,
            result.dailyBrief.recommendations.count
        )
        XCTAssertTrue(result.dailyBrief.recommendations.allSatisfy {
            result.dailyBrief.domains.flatMap(\.evidenceKeys).contains($0.evidenceKey)
        })

        let encoded = try JSONEncoder().encode(result.dailyBrief.contextSummary)
        let json = String(decoding: encoded, as: UTF8.self)
        XCTAssertTrue(json.contains("sevenDay"))
        XCTAssertTrue(json.contains("twentyEightDay"))
        XCTAssertFalse(json.contains("healthKitSamples"))
        XCTAssertFalse(json.contains("startDate"))
    }

    func testHealthContextAveragesSignedEnergyBalanceAndReportsItsDenominator() throws {
        let today = try date(2026, 9, 12)
        let days = try (-6...0).map { offset -> HealthIntelligenceDay in
            let date = try XCTUnwrap(calendar.date(byAdding: .day, value: offset, to: today))
            if offset == -1 {
                return HealthIntelligenceDay(
                    dayStart: date,
                    energyIntakeKcal: 1_800,
                    proteinGrams: 80,
                    dailyDeficitKcal: -100,
                    nutritionRecordStatus: .complete,
                    nutritionIntakeAvailability: .partial,
                    nutritionProteinAvailability: .partial
                )
            }
            if offset == 0 {
                return HealthIntelligenceDay(
                    dayStart: date,
                    energyIntakeKcal: 1_900,
                    proteinGrams: 100,
                    dailyDeficitKcal: 300,
                    nutritionRecordStatus: .complete,
                    nutritionIntakeAvailability: .estimated,
                    nutritionProteinAvailability: .estimated
                )
            }
            return HealthIntelligenceDay(
                dayStart: date,
                energyIntakeKcal: 4_000,
                proteinGrams: 250,
                dailyDeficitKcal: 2_000,
                nutritionRecordStatus: .inProgress,
                nutritionIntakeAvailability: .partial,
                nutritionProteinAvailability: .partial
            )
        }
        let summary = HealthIntelligenceEngine(calendar: calendar).makeContextSummary(
            days: days,
            asOf: today,
            goals: nil,
            recommendations: []
        )

        XCTAssertEqual(try XCTUnwrap(summary.sevenDay.averageDailyDeficitKcal), 300, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(summary.sevenDay.averageEnergyIntakeKcal), 1_900, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(summary.sevenDay.averageProteinGrams), 100, accuracy: 0.001)
        XCTAssertEqual(summary.sevenDay.coverageDays["energyIntake"], 7)
        XCTAssertEqual(summary.sevenDay.coverageDays["dailyDeficitKcal"], 2)
        XCTAssertEqual(summary.sevenDay.coverageDays["proteinGrams"], 7)
        XCTAssertEqual(summary.sevenDay.metricWindowCoverage["energyIntake"]?.validCalendarDays, 7)
        XCTAssertEqual(summary.sevenDay.metricWindowCoverage["energyIntake"]?.completeRecordDays, 2)
        XCTAssertEqual(summary.sevenDay.metricWindowCoverage["energyIntake"]?.completeValidDays, 1)
        XCTAssertEqual(summary.sevenDay.metricWindowCoverage["proteinGrams"]?.completeRecordDays, 2)
        XCTAssertEqual(summary.sevenDay.metricWindowCoverage["proteinGrams"]?.completeValidDays, 1)

        let surplusOnly = HealthIntelligenceEngine(calendar: calendar).makeContextSummary(
            days: [HealthIntelligenceDay(
                dayStart: today,
                dailyDeficitKcal: -250,
                nutritionRecordStatus: .complete
            )],
            asOf: today,
            goals: nil,
            recommendations: []
        )
        XCTAssertEqual(try XCTUnwrap(surplusOnly.sevenDay.averageDailyDeficitKcal), -250, accuracy: 0.001)
        XCTAssertEqual(surplusOnly.sevenDay.coverageDays["dailyDeficitKcal"], 1)
    }

    func testHealthNarrativeKeepsRecordedCurrentIntakePartialAndBaselinesUseCompleteDays() throws {
        let today = try date(2026, 9, 18)
        let priorDay = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: today))
        let priorComplete = HealthIntelligenceDay(
            dayStart: priorDay,
            energyIntakeKcal: 1_800,
            nutritionRecordStatus: .complete,
            nutritionIntakeAvailability: .estimated
        )
        let currentInProgress = HealthIntelligenceDay(
            dayStart: today,
            energyIntakeKcal: 2_350,
            nutritionRecordStatus: .inProgress,
            nutritionIntakeAvailability: .partial
        )
        let engine = HealthIntelligenceEngine(calendar: calendar)

        let daily = try XCTUnwrap(engine.makeDailyBrief(days: [priorComplete, currentInProgress]))
        let dailyNutrition = try XCTUnwrap(daily.dailyBrief.domains.first(where: { $0.domain == .nutrition }))
        XCTAssertEqual(dailyNutrition.status, .partial)
        XCTAssertEqual(dailyNutrition.dataCoverage, .partial)
        XCTAssertEqual(dailyNutrition.currentValue, 2_350)
        XCTAssertEqual(dailyNutrition.evidenceKeys, ["nutrition.energyIntake.kcal"])
        XCTAssertEqual(dailyNutrition.baseline.validDays, 1)
        XCTAssertEqual(dailyNutrition.baseline.median, 1_800)

        let weekly = engine.makeWeeklyBrief(days: [priorComplete, currentInProgress], weekStart: today)
        let weeklyNutrition = try XCTUnwrap(weekly.domainStatuses.first(where: { $0.domain == .nutrition }))
        XCTAssertEqual(weeklyNutrition.status, .partial)
        XCTAssertEqual(weeklyNutrition.currentValue, 2_350)
        XCTAssertEqual(weeklyNutrition.evidenceKeys, ["nutrition.weekly.latest"])
        XCTAssertEqual(weeklyNutrition.baseline.validDays, 1)
        XCTAssertEqual(weeklyNutrition.baseline.median, 1_800)
        XCTAssertNil(weekly.averageEnergyIntakeKcal)
    }

    func testUnknownNutritionStatusRetainsRecordedEstimateAsPartialWithoutLegacyBaseline() throws {
        let today = try date(2026, 9, 19)
        let priorDay = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: today))
        let legacyDay = try XCTUnwrap(calendar.date(byAdding: .day, value: -2, to: today))
        let priorComplete = HealthIntelligenceDay(
            dayStart: priorDay,
            energyIntakeKcal: 1_800,
            nutritionRecordStatus: .complete,
            nutritionIntakeAvailability: .estimated
        )
        let unknownPrior = HealthIntelligenceDay(
            dayStart: legacyDay,
            energyIntakeKcal: 1_900,
            nutritionRecordStatus: .unknown,
            nutritionIntakeAvailability: .estimated
        )
        let currentUnknown = HealthIntelligenceDay(
            dayStart: today,
            energyIntakeKcal: 2_100,
            nutritionRecordStatus: .unknown,
            nutritionIntakeAvailability: .partial
        )

        let result = try XCTUnwrap(
            HealthIntelligenceEngine(calendar: calendar).makeDailyBrief(days: [priorComplete, unknownPrior, currentUnknown])
        )
        let nutrition = try XCTUnwrap(result.dailyBrief.domains.first(where: { $0.domain == .nutrition }))
        XCTAssertEqual(nutrition.status, .partial)
        XCTAssertEqual(nutrition.dataCoverage, .partial)
        XCTAssertEqual(nutrition.currentValue, 2_100)
        XCTAssertEqual(nutrition.evidenceKeys, ["nutrition.energyIntake.kcal"])
        XCTAssertEqual(nutrition.baseline.validDays, 1)
        XCTAssertEqual(nutrition.baseline.median, 1_800)

        let summary = HealthIntelligenceEngine(calendar: calendar).makeContextSummary(
            days: [priorComplete, unknownPrior, currentUnknown],
            asOf: today,
            goals: nil,
            recommendations: []
        )
        XCTAssertEqual(summary.sevenDay.metricWindowCoverage["energyIntake"]?.completeRecordDays, 1)
        XCTAssertEqual(summary.sevenDay.metricWindowCoverage["energyIntake"]?.completeValidDays, 1)
        XCTAssertEqual(summary.sevenDay.coverageDays["energyIntake"], 3)
        XCTAssertEqual(summary.sevenDay.averageEnergyIntakeKcal, 1_800)
    }

    func testUnknownHealthKitCoverageRemainsUnknownAndSelectedActivityMetricKeepsItsCoverage() throws {
        let today = try date(2026, 10, 20)
        let unknown = HealthReadState.dataUnavailableOrReadScopeUnknown
        let unknownStates = [
            HealthMetricID.sleepAnalysis,
            .stepCount,
            .exerciseMinutes,
            .activeEnergy,
            .bodyMass,
            .workout,
        ].reduce(into: [String: HealthReadState]()) { result, metric in
            result[metric.rawValue] = unknown
        }
        let engine = HealthIntelligenceEngine(calendar: calendar)
        let unknownDay = HealthIntelligenceDay(dayStart: today, healthReadStates: unknownStates)
        let unknownResult = try XCTUnwrap(engine.makeDailyBrief(days: [unknownDay]))

        XCTAssertEqual(unknownResult.dailyBrief.healthState?.domains.first(where: { $0.domain == .sleep })?.status, .unknown)
        XCTAssertEqual(unknownResult.dailyBrief.healthState?.domains.first(where: { $0.domain == .activity })?.status, .unknown)
        XCTAssertEqual(unknownResult.dailyBrief.healthState?.domains.first(where: { $0.domain == .body })?.status, .unknown)
        XCTAssertNil(unknownResult.dailyBrief.healthState?.domains.first(where: { $0.domain == .activity })?.currentValue)
        XCTAssertEqual(unknownResult.dailyBrief.trainingLoad.dataCoverage, .unknown)
        XCTAssertEqual(unknownResult.dailyBrief.contextSummary.sevenDay.dataCoverage["steps"], .unknown)
        XCTAssertNil(unknownResult.dailyBrief.contextSummary.sevenDay.coverageDays["steps"])
        XCTAssertNil(unknownResult.dailyBrief.contextSummary.sevenDay.averageStepCount)
        let unknownWindowCoverage = try XCTUnwrap(unknownResult.dailyBrief.contextSummary.analysisWindowCoverage["steps"])
        XCTAssertNil(unknownWindowCoverage.actualEarliestDate)
        XCTAssertNil(unknownWindowCoverage.validCalendarDays)
        XCTAssertNil(unknownWindowCoverage.missingCalendarDays)
        XCTAssertNil(unknownWindowCoverage.authorizationLimited)
        XCTAssertNil(unknownWindowCoverage.dataAvailabilityLimited)
        let weekly = engine.makeWeeklyBrief(days: [unknownDay], weekStart: today)
        XCTAssertEqual(weekly.domainStatuses.first(where: { $0.domain == .activity })?.status, .unknown)
        XCTAssertTrue(weekly.summary.contains("覆盖未知"))

        let partiallyKnownStates: [String: HealthReadState] = [
            HealthMetricID.sleepAnalysis.rawValue: .available,
            HealthMetricID.stepCount.rawValue: .available,
            HealthMetricID.exerciseMinutes.rawValue: unknown,
            HealthMetricID.activeEnergy.rawValue: unknown,
            HealthMetricID.bodyMass.rawValue: unknown,
            HealthMetricID.workout.rawValue: unknown,
        ]
        let partialResult = try XCTUnwrap(engine.makeDailyBrief(days: [HealthIntelligenceDay(
            dayStart: today,
            stepCount: 5_600,
            weightSamplesKilograms: [71.4],
            healthReadStates: partiallyKnownStates
        )]))
        let selectedActivity = try XCTUnwrap(
            partialResult.dailyBrief.healthState?.domains.first(where: { $0.domain == .activity })
        )
        XCTAssertEqual(selectedActivity.status, .learning)
        XCTAssertEqual(selectedActivity.dataCoverage, .complete)
        XCTAssertEqual(selectedActivity.currentValue, 5_600)
        XCTAssertEqual(selectedActivity.evidenceKeys, [HealthActivityMetric.steps.evidenceKey])
        XCTAssertEqual(partialResult.dailyBrief.healthState?.domains.first(where: { $0.domain == .body })?.status, .partial)
        XCTAssertEqual(partialResult.dailyBrief.healthState?.domains.first(where: { $0.domain == .sleep })?.status, .noData)
        XCTAssertEqual(partialResult.dailyBrief.trainingLoad.dataCoverage, .unknown)
    }

    func testActivityBaselineNeverMixesStepsMinutesAndCalories() throws {
        let today = try date(2026, 10, 22)
        var days: [HealthIntelligenceDay] = []
        for offset in -28 ... -1 {
            let day = try XCTUnwrap(calendar.date(byAdding: .day, value: offset, to: today))
            switch offset {
            case -7 ... -1:
                days.append(HealthIntelligenceDay(
                    dayStart: day,
                    stepCount: Double(6_000 + (offset + 7) * 20)
                ))
            case -17 ... -8:
                days.append(HealthIntelligenceDay(dayStart: day, exerciseMinutes: 40))
            default:
                days.append(HealthIntelligenceDay(dayStart: day, activeEnergyKcal: 450))
            }
        }
        days.append(HealthIntelligenceDay(dayStart: today, stepCount: 6_070))

        let result = try XCTUnwrap(HealthIntelligenceEngine(calendar: calendar).makeDailyBrief(days: days))
        let activity = try XCTUnwrap(result.dailyBrief.domains.first(where: { $0.domain == .activity }))
        let steps = try XCTUnwrap(result.dailyBrief.activityTrends.first(where: { $0.metric == .steps }))
        let exercise = try XCTUnwrap(result.dailyBrief.activityTrends.first(where: { $0.metric == .exerciseMinutes }))
        let energy = try XCTUnwrap(result.dailyBrief.activityTrends.first(where: { $0.metric == .activeEnergy }))

        XCTAssertEqual(result.dailyBrief.activityTrends.map(\.metric), HealthActivityMetric.allCases)
        XCTAssertEqual(activity.evidenceKeys, ["activity.steps"])
        XCTAssertEqual(activity.baseline.validDays, 7)
        XCTAssertEqual(activity.baseline.median, 6_060)
        XCTAssertEqual(activity.status, .withinTypicalRange)
        XCTAssertEqual(steps.unit, "steps")
        XCTAssertEqual(steps.evidenceKey, "activity.steps")
        XCTAssertEqual(steps.currentValue, 6_070)
        XCTAssertEqual(steps.baseline, activity.baseline)
        XCTAssertEqual(exercise.unit, "minutes")
        XCTAssertEqual(exercise.evidenceKey, "activity.exerciseMinutes")
        XCTAssertNil(exercise.currentValue)
        XCTAssertEqual(exercise.baseline.validDays, 10)
        XCTAssertEqual(exercise.baseline.median, 40)
        XCTAssertEqual(energy.unit, "kcal")
        XCTAssertEqual(energy.evidenceKey, "activity.activeEnergy.kcal")
        XCTAssertNil(energy.currentValue)
        XCTAssertEqual(energy.baseline.validDays, 11)
        XCTAssertEqual(energy.baseline.median, 450)
    }

    func testActivityBaselineUsesConsistentMetricAcrossHistoricalDaysAndWeeklyBrief() throws {
        let weekStart = try date(2026, 10, 26)
        var days: [HealthIntelligenceDay] = []
        for offset in -28 ... -1 {
            let day = try XCTUnwrap(calendar.date(byAdding: .day, value: offset, to: weekStart))
            switch offset {
            case -7 ... -1:
                days.append(HealthIntelligenceDay(dayStart: day, exerciseMinutes: Double(30 + offset + 7)))
            case -17 ... -8:
                days.append(HealthIntelligenceDay(dayStart: day, stepCount: 10_000))
            default:
                days.append(HealthIntelligenceDay(dayStart: day, activeEnergyKcal: 450))
            }
        }
        days.append(HealthIntelligenceDay(dayStart: weekStart, exerciseMinutes: 34))

        let engine = HealthIntelligenceEngine(calendar: calendar)
        let daily = try XCTUnwrap(engine.makeDailyBrief(days: days))
        let dailyActivity = try XCTUnwrap(daily.dailyBrief.domains.first(where: { $0.domain == .activity }))
        let dailyExercise = try XCTUnwrap(daily.dailyBrief.activityTrends.first(where: { $0.metric == .exerciseMinutes }))
        XCTAssertEqual(dailyActivity.evidenceKeys, ["activity.exerciseMinutes"])
        XCTAssertEqual(dailyActivity.baseline.validDays, 7)
        XCTAssertEqual(dailyActivity.baseline.median, 33)
        XCTAssertEqual(dailyActivity.status, .withinTypicalRange)
        XCTAssertEqual(dailyExercise.currentValue, 34)
        XCTAssertEqual(dailyExercise.evidenceKey, "activity.exerciseMinutes")
        XCTAssertEqual(dailyExercise.unit, "minutes")
        XCTAssertEqual(dailyExercise.baseline, dailyActivity.baseline)

        let weekly = engine.makeWeeklyBrief(days: days, weekStart: weekStart)
        let weeklyActivity = try XCTUnwrap(weekly.domainStatuses.first(where: { $0.domain == .activity }))
        let weeklyExercise = try XCTUnwrap(weekly.activityTrends.first(where: { $0.metric == .exerciseMinutes }))
        XCTAssertEqual(weeklyActivity.evidenceKeys, ["activity.exerciseMinutes"])
        XCTAssertEqual(weeklyActivity.currentValue, 34)
        XCTAssertEqual(weeklyActivity.baseline.validDays, 7)
        XCTAssertEqual(weeklyActivity.baseline.median, 33)
        XCTAssertEqual(weeklyActivity.status, .withinTypicalRange)
        XCTAssertEqual(weekly.activityTrends.map(\.metric), HealthActivityMetric.allCases)
        XCTAssertEqual(weeklyExercise.currentValue, 34)
        XCTAssertEqual(weeklyExercise.evidenceKey, "activity.exerciseMinutes")
        XCTAssertEqual(weeklyExercise.baseline, weeklyActivity.baseline)

        let encoder = JSONEncoder()
        let dailyJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(daily.dailyBrief)) as? [String: Any])
        var legacyDailyJSON = dailyJSON
        legacyDailyJSON.removeValue(forKey: "activityTrends")
        let legacyDaily = try JSONDecoder().decode(
            DailyHealthBrief.self,
            from: JSONSerialization.data(withJSONObject: legacyDailyJSON)
        )
        XCTAssertTrue(legacyDaily.activityTrends.isEmpty)

        let weeklyJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(weekly)) as? [String: Any])
        var legacyWeeklyJSON = weeklyJSON
        legacyWeeklyJSON.removeValue(forKey: "activityTrends")
        let legacyWeekly = try JSONDecoder().decode(
            WeeklyHealthBrief.self,
            from: JSONSerialization.data(withJSONObject: legacyWeeklyJSON)
        )
        XCTAssertTrue(legacyWeekly.activityTrends.isEmpty)
    }

    func testActivityMetricFallbackDoesNotUseOtherUnitsWhenSelectedMetricHasNoBaseline() throws {
        let today = try date(2026, 10, 23)
        let history = try (-28 ... -1).map { offset -> HealthIntelligenceDay in
            let day = try XCTUnwrap(calendar.date(byAdding: .day, value: offset, to: today))
            return HealthIntelligenceDay(
                dayStart: day,
                stepCount: 10_000,
                exerciseMinutes: 40
            )
        }
        let days = history + [HealthIntelligenceDay(dayStart: today, activeEnergyKcal: 480)]

        let result = try XCTUnwrap(HealthIntelligenceEngine(calendar: calendar).makeDailyBrief(days: days))
        let activity = try XCTUnwrap(result.dailyBrief.domains.first(where: { $0.domain == .activity }))

        XCTAssertEqual(activity.evidenceKeys, ["activity.activeEnergy.kcal"])
        XCTAssertEqual(activity.currentValue, 480)
        XCTAssertEqual(activity.baseline.readiness, .noData)
        XCTAssertEqual(activity.baseline.validDays, 0)
        XCTAssertEqual(activity.status, .learning)
        let energy = try XCTUnwrap(result.dailyBrief.activityTrends.first(where: { $0.metric == .activeEnergy }))
        XCTAssertEqual(energy.baseline.readiness, .noData)
        XCTAssertEqual(energy.status, .learning)
        XCTAssertEqual(energy.evidenceKey, activity.evidenceKeys.first)
    }

    func testActivityMetricAvailabilityChangesDoNotChangeAnotherMetricBaseline() throws {
        let today = try date(2026, 10, 24)
        let unknown = HealthReadState.dataUnavailableOrReadScopeUnknown
        func makeBrief(stepStreamAvailable: Bool) throws -> DailyHealthBrief {
            var days: [HealthIntelligenceDay] = []
            for offset in -7 ... 0 {
                let day = try XCTUnwrap(calendar.date(byAdding: .day, value: offset, to: today))
                let isCurrent = offset == 0
                let stepState: HealthReadState = isCurrent
                    ? unknown
                    : (stepStreamAvailable ? .available : unknown)
                let states: [String: HealthReadState] = [
                    HealthMetricID.stepCount.rawValue: stepState,
                    HealthMetricID.exerciseMinutes.rawValue: .available,
                    HealthMetricID.activeEnergy.rawValue: unknown,
                ]
                days.append(HealthIntelligenceDay(
                    dayStart: day,
                    stepCount: isCurrent ? 50_000 : (stepStreamAvailable ? 10_000 : nil),
                    exerciseMinutes: isCurrent ? 34 : Double(30 + offset + 7),
                    healthReadStates: states
                ))
            }
            return try XCTUnwrap(HealthIntelligenceEngine(calendar: calendar).makeDailyBrief(days: days)?.dailyBrief)
        }

        let beforeStepAuthorization = try makeBrief(stepStreamAvailable: false)
        let afterStepAuthorization = try makeBrief(stepStreamAvailable: true)
        let exerciseBefore = try XCTUnwrap(beforeStepAuthorization.activityTrends.first(where: { $0.metric == .exerciseMinutes }))
        let exerciseAfter = try XCTUnwrap(afterStepAuthorization.activityTrends.first(where: { $0.metric == .exerciseMinutes }))
        let stepsBefore = try XCTUnwrap(beforeStepAuthorization.activityTrends.first(where: { $0.metric == .steps }))
        let stepsAfter = try XCTUnwrap(afterStepAuthorization.activityTrends.first(where: { $0.metric == .steps }))

        XCTAssertEqual(stepsBefore.dataCoverage, .unknown)
        XCTAssertEqual(stepsAfter.dataCoverage, .partial)
        XCTAssertEqual(stepsBefore.baseline.validDays, 0)
        XCTAssertEqual(stepsAfter.baseline.validDays, 7)
        XCTAssertNil(stepsBefore.currentValue)
        XCTAssertNil(stepsAfter.currentValue)
        XCTAssertEqual(exerciseBefore.currentValue, 34)
        XCTAssertEqual(exerciseAfter.currentValue, 34)
        XCTAssertEqual(exerciseBefore.evidenceKey, "activity.exerciseMinutes")
        XCTAssertEqual(exerciseAfter.evidenceKey, "activity.exerciseMinutes")
        XCTAssertEqual(exerciseBefore.dataCoverage, .complete)
        XCTAssertEqual(exerciseAfter.dataCoverage, .complete)
        XCTAssertEqual(exerciseBefore.baseline.validDays, 7)
        XCTAssertEqual(exerciseAfter.baseline.validDays, 7)
        XCTAssertEqual(exerciseBefore.baseline, exerciseAfter.baseline)
        XCTAssertEqual(exerciseBefore.status, exerciseAfter.status)
        XCTAssertEqual(
            beforeStepAuthorization.domains.first(where: { $0.domain == .activity })?.evidenceKeys,
            ["activity.exerciseMinutes"]
        )
        XCTAssertEqual(
            afterStepAuthorization.domains.first(where: { $0.domain == .activity })?.evidenceKeys,
            ["activity.exerciseMinutes"]
        )
    }

    func testLegacyActivityAggregateCoverageFollowsSelectedMetricDailyAndWeekly() throws {
        let today = try date(2026, 10, 25)
        let unknown = HealthReadState.dataUnavailableOrReadScopeUnknown
        let days = try (-27...0).map { offset -> HealthIntelligenceDay in
            let day = try XCTUnwrap(calendar.date(byAdding: .day, value: offset, to: today))
            let states: [String: HealthReadState] = [
                HealthMetricID.stepCount.rawValue: unknown,
                HealthMetricID.exerciseMinutes.rawValue: .available,
                HealthMetricID.activeEnergy.rawValue: unknown,
            ]
            return HealthIntelligenceDay(
                dayStart: day,
                activeEnergyKcal: 900,
                stepCount: 40_000,
                exerciseMinutes: Double(25 + (offset + 27) % 12),
                healthReadStates: states
            )
        }
        let engine = HealthIntelligenceEngine(calendar: calendar)
        let daily = try XCTUnwrap(engine.makeDailyBrief(days: days)?.dailyBrief)
        let dailyActivity = try XCTUnwrap(daily.domains.first(where: { $0.domain == .activity }))
        let dailyExercise = try XCTUnwrap(daily.activityTrends.first(where: { $0.metric == .exerciseMinutes }))
        let weekStart = try XCTUnwrap(calendar.date(byAdding: .day, value: -6, to: today))
        let weekly = engine.makeWeeklyBrief(days: days, weekStart: weekStart)
        let weeklyActivity = try XCTUnwrap(weekly.domainStatuses.first(where: { $0.domain == .activity }))
        let weeklyExercise = try XCTUnwrap(weekly.activityTrends.first(where: { $0.metric == .exerciseMinutes }))

        XCTAssertEqual(dailyExercise.dataCoverage, .complete)
        XCTAssertEqual(dailyActivity.dataCoverage, dailyExercise.dataCoverage)
        XCTAssertEqual(dailyActivity.currentValue, dailyExercise.currentValue)
        XCTAssertEqual(dailyActivity.baseline, dailyExercise.baseline)
        XCTAssertEqual(dailyActivity.evidenceKeys, [dailyExercise.evidenceKey])

        XCTAssertEqual(weeklyExercise.dataCoverage, .complete)
        XCTAssertEqual(weeklyActivity.dataCoverage, weeklyExercise.dataCoverage)
        XCTAssertEqual(weeklyActivity.currentValue, weeklyExercise.currentValue)
        XCTAssertEqual(weeklyActivity.baseline, weeklyExercise.baseline)
        XCTAssertEqual(weeklyActivity.evidenceKeys, [weeklyExercise.evidenceKey])
    }

    func testConflictingSleepSourcesMarkHealthDomainCoveragePartial() throws {
        let today = try date(2026, 10, 21)
        let conflict = SleepSummary(
            wakeDate: today,
            totalAsleepMinutes: 0,
            mainSleepMinutes: nil,
            napMinutes: 0,
            stageCoverage: nil,
            stages: nil,
            selectedSourceBundleIdentifier: "com.apple.watchkitapp",
            hasConflictingSourceStages: true
        )
        let day = HealthIntelligenceDay(
            dayStart: today,
            sleepSummary: conflict,
            healthReadStates: [HealthMetricID.sleepAnalysis.rawValue: .available]
        )

        let result = try XCTUnwrap(HealthIntelligenceEngine(calendar: calendar).makeDailyBrief(days: [day]))
        let sleepDomain = try XCTUnwrap(result.dailyBrief.healthState?.domains.first { $0.domain == .sleep })

        XCTAssertEqual(sleepDomain.dataCoverage, .partial)
        XCTAssertEqual(sleepDomain.status, .partial)
    }

    func testMetricWindowCoverageReportsThirtyAuthorizedDaysWithinFortyTwoDayTarget() throws {
        let today = try date(2026, 10, 20)
        let todayStart = calendar.startOfDay(for: today)
        let authorizationStart = try XCTUnwrap(calendar.date(byAdding: .day, value: -29, to: todayStart))
        let days = (0..<42).compactMap { offset -> HealthIntelligenceDay? in
            guard let dayStart = calendar.date(byAdding: .day, value: offset - 41, to: todayStart) else { return nil }
            let readState: HealthReadState = dayStart < authorizationStart
                ? .dataUnavailableOrReadScopeUnknown
                : .available
            return HealthIntelligenceDay(
                dayStart: dayStart,
                stepCount: readState == .available ? 5_000 : nil,
                healthReadStates: [HealthMetricID.stepCount.rawValue: readState],
                healthQueryStartByMetric: [HealthMetricID.stepCount.rawValue: authorizationStart]
            )
        }
        let summary = HealthIntelligenceEngine(calendar: calendar).makeContextSummary(
            days: days,
            asOf: today,
            goals: nil,
            recommendations: []
        )
        let analysisCoverage = try XCTUnwrap(summary.analysisWindowCoverage["steps"])
        let twentyEightDayCoverage = try XCTUnwrap(summary.twentyEightDay.metricWindowCoverage["steps"])

        XCTAssertEqual(analysisCoverage.targetWindowStart, calendar.date(byAdding: .day, value: -41, to: todayStart))
        XCTAssertEqual(analysisCoverage.expectedCalendarDays, 42)
        XCTAssertEqual(analysisCoverage.actualEarliestDate, authorizationStart)
        XCTAssertEqual(analysisCoverage.validCalendarDays, 30)
        XCTAssertEqual(analysisCoverage.missingCalendarDays, 12)
        XCTAssertEqual(analysisCoverage.authorizationLimited, true)
        XCTAssertEqual(analysisCoverage.dataAvailabilityLimited, false)
        XCTAssertEqual(twentyEightDayCoverage.expectedCalendarDays, 28)
        XCTAssertEqual(twentyEightDayCoverage.validCalendarDays, 28)
        XCTAssertEqual(twentyEightDayCoverage.authorizationLimited, false)
    }

    func testSleepWindowCoverageUsesFirstFullyAuthorizedWakeDay() throws {
        let today = try date(2026, 10, 20)
        let todayStart = calendar.startOfDay(for: today)
        let authorizationDay = try XCTUnwrap(calendar.date(byAdding: .day, value: -21, to: todayStart))
        let authorizationStart = try XCTUnwrap(calendar.date(bySettingHour: 19, minute: 0, second: 0, of: authorizationDay))
        let firstFullyAuthorizedWakeDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 2, to: authorizationDay))
        let days = (0..<42).compactMap { offset -> HealthIntelligenceDay? in
            guard let dayStart = calendar.date(byAdding: .day, value: offset - 41, to: todayStart) else { return nil }
            let isAuthorized = dayStart >= firstFullyAuthorizedWakeDay
            return HealthIntelligenceDay(
                dayStart: dayStart,
                sleepSummary: isAuthorized ? SleepSummary(
                    wakeDate: dayStart,
                    totalAsleepMinutes: 420,
                    mainSleepMinutes: 420,
                    napMinutes: 0,
                    stageCoverage: nil,
                    stages: nil,
                    selectedSourceBundleIdentifier: nil
                ) : nil,
                healthReadStates: [HealthMetricID.sleepAnalysis.rawValue: isAuthorized ? .available : .dataUnavailableOrReadScopeUnknown],
                healthQueryStartByMetric: [HealthMetricID.sleepAnalysis.rawValue: authorizationStart]
            )
        }
        let summary = HealthIntelligenceEngine(calendar: calendar).makeContextSummary(
            days: days,
            asOf: today,
            goals: nil,
            recommendations: []
        )
        let coverage = try XCTUnwrap(summary.analysisWindowCoverage["sleep"])

        XCTAssertEqual(coverage.expectedCalendarDays, 42)
        XCTAssertEqual(coverage.actualEarliestDate, firstFullyAuthorizedWakeDay)
        XCTAssertEqual(coverage.validCalendarDays, 20)
        XCTAssertEqual(coverage.missingCalendarDays, 22)
        XCTAssertEqual(coverage.authorizationLimited, true)
        XCTAssertEqual(coverage.dataAvailabilityLimited, false)
    }

    func testLegacyTrainingLoadCacheWithoutCoverageDecodesUnknownAndOmitsNumericPlaceholders() throws {
        let legacy = #"{"recentSevenDayLoad":0,"priorTwentyEightDayAverage":null,"ratio":null,"readiness":"noData","band":"unavailable","estimatedWorkoutCount":0,"unavailableEffortCount":0}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(TrainingLoadSummary.self, from: legacy)

        XCTAssertEqual(decoded.dataCoverage, .unknown)
        let reencoded = try JSONEncoder().encode(decoded)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: reencoded) as? [String: Any])
        XCTAssertEqual(object["dataCoverage"] as? String, HealthDataCoverage.unknown.rawValue)
        XCTAssertNil(object["recentSevenDayLoad"])
        XCTAssertNil(object["priorTwentyEightDayAverage"])
        XCTAssertNil(object["ratio"])
        XCTAssertNil(object["estimatedWorkoutCount"])
        XCTAssertNil(object["unavailableEffortCount"])
    }

    func testLegacyHealthDomainVitalAndContextCachesFailClosedWithoutCoverage() throws {
        let baselineJSON = #"{"readiness":"mature","validDays":28,"median":420,"p10":360,"p90":480,"mad":30}"#
        let domainJSON = #"{"domain":"sleep","status":"withinTypicalRange","currentValue":420,"baseline":\#(baselineJSON),"evidenceKeys":["sleep.mainSleep.minutes"]}"#.data(using: .utf8)!
        let domain = try JSONDecoder().decode(HealthDomainResult.self, from: domainJSON)
        XCTAssertEqual(domain.dataCoverage, .unknown)
        XCTAssertEqual(domain.status, .unknown)
        XCTAssertNil(domain.currentValue)
        XCTAssertTrue(domain.evidenceKeys.isEmpty)

        let legacyNutritionDomainJSON = #"{"domain":"nutrition","status":"withinTypicalRange","currentValue":1800,"baseline":\#(baselineJSON),"evidenceKeys":["nutrition.energyIntake.kcal"]}"#.data(using: .utf8)!
        let legacyNutritionDomain = try JSONDecoder().decode(HealthDomainResult.self, from: legacyNutritionDomainJSON)
        XCTAssertEqual(legacyNutritionDomain.dataCoverage, .unknown)
        XCTAssertEqual(legacyNutritionDomain.status, .unknown)
        XCTAssertNil(legacyNutritionDomain.currentValue)
        XCTAssertTrue(legacyNutritionDomain.evidenceKeys.isEmpty)

        let legacyDayJSON = #"{"dayStart":0,"energyIntakeKcal":1800,"proteinGrams":80,"dailyDeficitKcal":300}"#.data(using: .utf8)!
        let legacyDay = try JSONDecoder().decode(HealthIntelligenceDay.self, from: legacyDayJSON)
        XCTAssertEqual(legacyDay.nutritionRecordStatus, .unknown)
        XCTAssertNil(legacyDay.completeEnergyIntakeKcal)
        XCTAssertNil(legacyDay.completeProteinGrams)

        let vitalJSON = #"{"metric":"restingHeartRate","latestMedian":58,"baseline":\#(baselineJSON),"status":"withinTypicalRange","evidenceKey":"vitals.restingHeartRate.median"}"#.data(using: .utf8)!
        let vital = try JSONDecoder().decode(HealthVitalTrend.self, from: vitalJSON)
        XCTAssertEqual(vital.dataCoverage, .unknown)
        XCTAssertEqual(vital.status, .unknown)
        XCTAssertNil(vital.latestMedian)

        let contextJSON = #"{"windowDays":7,"coverageDays":{"sleep":3,"steps":2,"energyIntake":4,"proteinGrams":4},"averageSleepMinutes":420,"averageStepCount":5200,"averageActiveEnergyKcal":450,"averageEnergyIntakeKcal":1800,"averageDailyDeficitKcal":300,"averageProteinGrams":80,"medianWeightKilograms":71}"#.data(using: .utf8)!
        let context = try JSONDecoder().decode(HealthContextWindowSummary.self, from: contextJSON)
        XCTAssertEqual(context.metricWindowCoverage, [:])
        XCTAssertEqual(context.dataCoverage["sleep"], .unknown)
        XCTAssertNil(context.coverageDays["sleep"])
        XCTAssertNil(context.averageSleepMinutes)
        XCTAssertNil(context.averageStepCount)
        XCTAssertEqual(context.coverageDays["energyIntake"], 4)
        XCTAssertEqual(context.coverageDays["proteinGrams"], 4)
        XCTAssertNil(context.averageEnergyIntakeKcal)
        XCTAssertNil(context.averageProteinGrams)
        XCTAssertNil(context.averageDailyDeficitKcal)
        XCTAssertNil(context.medianWeightKilograms)

        let legacyWindowObject = try XCTUnwrap(JSONSerialization.jsonObject(with: contextJSON) as? [String: Any])
        let legacySummaryData = try JSONSerialization.data(withJSONObject: [
            "sevenDay": legacyWindowObject,
            "twentyEightDay": legacyWindowObject,
            "recommendationReferences": [String](),
        ])
        let legacySummary = try JSONDecoder().decode(HealthContextSummary.self, from: legacySummaryData)
        XCTAssertEqual(legacySummary.analysisWindowCoverage, [:])
        XCTAssertEqual(legacySummary.sevenDay.metricWindowCoverage, [:])
    }

    func testWeightTrendRequiresFourValidDaysInEachSevenDayWindow() throws {
        let engine = HealthIntelligenceEngine(calendar: calendar)
        let today = try date(2026, 8, 30)
        let days = (-13 ... 0).map { offset in
            HealthIntelligenceDay(
                dayStart: calendar.date(byAdding: .day, value: offset, to: today)!,
                weightSamplesKilograms: (offset <= -7 || offset >= -3) ? [offset < -6 ? 70 : 71] : []
            )
        }
        let trend = engine.weightTrendKilograms(in: days)
        XCTAssertEqual(try XCTUnwrap(trend.difference), 1, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(trend.previousMedian), 70, accuracy: 0.001)
    }

    private func points(_ count: Int, endingBefore date: Date, value: Double) -> [(date: Date, value: Double)] {
        (1...count).map { offset in
            (calendar.date(byAdding: .day, value: -offset, to: date)!, value)
        }
    }

    private func sleep(
        _ wakeDate: Date,
        start: (dayOffset: Int, hour: Int, minute: Int),
        end: (dayOffset: Int, hour: Int, minute: Int),
        stage: SleepStage,
        source: String = "com.apple.watchkitapp",
        device: String? = nil
    ) -> SleepSampleInterval {
        let startDay = calendar.date(byAdding: .day, value: start.dayOffset, to: wakeDate)!
        let endDay = calendar.date(byAdding: .day, value: end.dayOffset, to: wakeDate)!
        let startDate = calendar.date(bySettingHour: start.hour, minute: start.minute, second: 0, of: startDay)!
        let endDate = calendar.date(bySettingHour: end.hour, minute: end.minute, second: 0, of: endDay)!
        return SleepSampleInterval(
            startDate: startDate,
            endDate: endDate,
            stage: stage,
            sourceBundleIdentifier: source,
            deviceModel: device
        )
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) throws -> Date {
        let components = DateComponents(year: year, month: month, day: day, hour: 12)
        return try XCTUnwrap(calendar.date(from: components))
    }
}
