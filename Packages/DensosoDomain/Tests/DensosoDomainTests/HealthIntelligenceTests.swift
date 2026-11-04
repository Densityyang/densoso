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
        XCTAssertEqual(summary.selectedSourceIdentifier, "com.apple.watchkitapp")
        XCTAssertEqual(summary.supplementalSourceIdentifiers, ["com.example.sleep"])
        let stages = try XCTUnwrap(summary.stages)
        XCTAssertEqual(stages.core, 120, accuracy: 0.001)
        XCTAssertEqual(stages.deep, 60, accuracy: 0.001)
        XCTAssertEqual(stages.core + stages.deep + stages.rem, 180, accuracy: 0.001)
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
        XCTAssertEqual(summary.selectedSourceIdentifier, "com.apple.watch-b")
        XCTAssertTrue(summary.supplementalSourceIdentifiers.isEmpty)
        XCTAssertEqual(summary.sourceCoverage, [
            SleepSourceCoverage(sourceIdentifier: "com.apple.watch-b", asleepMinutes: 60),
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
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: today))
        let summary = HealthIntelligenceEngine(calendar: calendar).makeContextSummary(
            days: [
                HealthIntelligenceDay(dayStart: yesterday, proteinGrams: 80, dailyDeficitKcal: -100),
                HealthIntelligenceDay(dayStart: today, proteinGrams: 100, dailyDeficitKcal: 300),
            ],
            asOf: today,
            goals: nil,
            recommendations: []
        )

        XCTAssertEqual(try XCTUnwrap(summary.sevenDay.averageDailyDeficitKcal), 100, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(summary.sevenDay.averageProteinGrams), 90, accuracy: 0.001)
        XCTAssertEqual(summary.sevenDay.coverageDays["dailyDeficitKcal"], 2)
        XCTAssertEqual(summary.sevenDay.coverageDays["proteinGrams"], 2)

        let surplusOnly = HealthIntelligenceEngine(calendar: calendar).makeContextSummary(
            days: [HealthIntelligenceDay(dayStart: today, dailyDeficitKcal: -250)],
            asOf: today,
            goals: nil,
            recommendations: []
        )
        XCTAssertEqual(try XCTUnwrap(surplusOnly.sevenDay.averageDailyDeficitKcal), -250, accuracy: 0.001)
        XCTAssertEqual(surplusOnly.sevenDay.coverageDays["dailyDeficitKcal"], 1)
    }

    func testUnknownHealthKitCoverageRemainsUnknownAndKnownValuesRemainPartial() throws {
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
        XCTAssertEqual(partialResult.dailyBrief.healthState?.domains.first(where: { $0.domain == .activity })?.status, .partial)
        XCTAssertEqual(partialResult.dailyBrief.healthState?.domains.first(where: { $0.domain == .activity })?.currentValue, 5_600)
        XCTAssertEqual(partialResult.dailyBrief.healthState?.domains.first(where: { $0.domain == .body })?.status, .partial)
        XCTAssertEqual(partialResult.dailyBrief.healthState?.domains.first(where: { $0.domain == .sleep })?.status, .noData)
        XCTAssertEqual(partialResult.dailyBrief.trainingLoad.dataCoverage, .unknown)
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
        XCTAssertEqual(context.averageEnergyIntakeKcal, 1_800)
        XCTAssertEqual(context.averageProteinGrams, 80)
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
