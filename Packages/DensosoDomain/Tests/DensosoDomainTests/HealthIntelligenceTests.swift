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
                HealthIntelligenceDay(dayStart: yesterday, dailyDeficitKcal: -100, proteinGrams: 80),
                HealthIntelligenceDay(dayStart: today, dailyDeficitKcal: 300, proteinGrams: 100),
            ],
            asOf: today,
            goals: nil,
            recommendations: []
        )

        XCTAssertEqual(summary.sevenDay.averageDailyDeficitKcal, 100)
        XCTAssertEqual(summary.sevenDay.averageProteinGrams, 90)
        XCTAssertEqual(summary.sevenDay.coverageDays["dailyDeficitKcal"], 2)
        XCTAssertEqual(summary.sevenDay.coverageDays["proteinGrams"], 2)

        let surplusOnly = HealthIntelligenceEngine(calendar: calendar).makeContextSummary(
            days: [HealthIntelligenceDay(dayStart: today, dailyDeficitKcal: -250)],
            asOf: today,
            goals: nil,
            recommendations: []
        )
        XCTAssertEqual(surplusOnly.sevenDay.averageDailyDeficitKcal, -250)
        XCTAssertEqual(surplusOnly.sevenDay.coverageDays["dailyDeficitKcal"], 1)
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
