#!/usr/bin/env python3
"""Validate Phase 7 health-intelligence source and privacy contracts."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def require_text(relative: str, needles: tuple[str, ...], errors: list[str]) -> str:
    path = ROOT / relative
    if not path.is_file():
        errors.append(f"missing {relative}")
        return ""
    text = path.read_text(encoding="utf-8")
    for needle in needles:
        if needle not in text:
            errors.append(f"{relative} is missing {needle}")
    return text


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--report")
    args = parser.parse_args()
    errors: list[str] = []

    domain = require_text(
        "Packages/DensosoDomain/Sources/DensosoDomain/HealthIntelligence.swift",
        (
            "func baseline(for values:",
            "1..<7",
            "7..<28",
            "mad > 1e-9",
            "func sleepSummary(for wakeDate:",
            "public func trainingLoad(workouts: [TrainingWorkoutInput], asOf date: Date)",
            "divide load across the full four-week calendar window",
            "public struct RecommendationEngine",
            "recommendations.prefix(2)",
            "func makeContextSummary(",
            "sevenDay:",
            "twentyEightDay:",
        ),
        errors,
    )
    if "HKHealthStore" in domain or "import HealthKit" in domain:
        errors.append("domain health-intelligence code must remain HealthKit-free")

    service = require_text(
        "Densoso/Services/HealthIntelligenceService.swift",
        (
            "func refresh(asOf date: Date = Date()) async throws",
            "try await projectionActor.refresh(asOf: date)",
            "lastError = \"无法更新健康摘要：",
            "if snapshot.updatesWeeklyBrief",
            "func loadCachedBriefs() async",
            "func saveGoalProfile(_ goal: GoalProfile) async throws",
            "if snapshot.updatesWeeklyBrief",
        ),
        errors,
    )
    projection_actor = require_text(
        "Densoso/Services/HealthProjectionActor.swift",
        (
            "@ModelActor",
            "func refresh(asOf date: Date = Date()) throws -> HealthIntelligenceRefreshSnapshot",
            "let reader = HealthIntelligenceReadModel(calendar: calendar)",
            "snapshotHash == snapshotHash",
            "cachedDailyBrief(",
            "cachedWeeklyBrief(",
            "func loadCachedBriefs() -> HealthIntelligenceCachedBriefs",
            "saveGoalProfile(",
            "descriptor.fetchLimit = 1",
            "algorithmVersion: result.dailyBrief.algorithmVersion",
            "existing.algorithmVersion == brief.algorithmVersion",
            "struct HealthIntelligenceRefreshSnapshot: Sendable",
            "struct HealthIntelligenceCachedBriefs: Sendable",
        ),
        errors,
    )
    require_text(
        "Densoso/Services/HealthIntelligenceReadModel.swift",
        (
            "DailyHealthSnapshotRecord",
            "WeightRecord",
            "WorkoutRecord",
            "let snapshotPredicate = #Predicate<DailyHealthSnapshotRecord>",
            "let metricsPredicate = #Predicate<DailyMetrics>",
            "let weightPredicate = #Predicate<WeightRecord>",
            "let workoutPredicate = #Predicate<WorkoutRecord>",
            "let metricReadResult = metric.map(DailyMetricsReadModelMapper.make)",
            "let proteinGrams = metricReadResult?.proteinG.value",
            "let energyIntake = metricReadResult?.intake.value?.likely",
            "let dailyDeficit = metricReadResult?.deficit.value?.likely",
            "descriptor.fetchLimit = 1",
        ),
        errors,
    )
    read_model = (ROOT / "Densoso" / "Services" / "HealthIntelligenceReadModel.swift").read_text(
        encoding="utf-8"
    )
    if "MealRecord" in read_model or "mealPredicate" in read_model:
        errors.append("HealthIntelligence must consume canonical DailyMetrics instead of summing meals again")
    prompt = require_text(
        "Densoso/Application/Health/HealthContextPromptBuilder.swift",
        (
            "HealthContextSummary?",
            "shouldIncludeSummary(for userText:",
            "以下仅包含 7/28 日聚合",
        ),
        errors,
    )
    for forbidden in ("HealthSampleSnapshot", "healthKitSamples", "startDate", "endDate"):
        if forbidden in prompt:
            errors.append(f"provider context builder must not contain {forbidden}")

    notifications = require_text(
        "Densoso/Infrastructure/Notifications/BriefNotificationScheduler.swift",
        (
            "defaults.object(forKey: Self.morningKey)",
            "defaults.bool(forKey: Self.eveningKey)",
            "defaults.bool(forKey: Self.weeklyKey)",
            "setMorningTime(hour: Int, minute: Int)",
            "setEveningTime(hour: Int, minute: Int)",
            "DailyLoopNotificationCopy.make(snapshot: latestSnapshot, phase: phase)",
            "requestAuthorization",
        ),
        errors,
    )
    if any(
        word in notifications for word in ("kcal", "体重", "摄入", "缺口")
    ):
        # Measurement terms may appear in error text; inspect only literal bodies.
        bodies = [line for line in notifications.splitlines() if "body:" in line]
        if any(any(word in body for word in ("kcal", "体重", "摄入", "缺口")) for body in bodies):
            errors.append("notification body must not disclose personal health measurements")

    require_text(
        "Packages/DensosoDomain/Tests/DensosoDomainTests/HealthIntelligenceTests.swift",
        (
            "testSleepUnionHandlesCrossMidnightStagesAwakeAndNapWithoutDoubleCounting",
            "testSleepPrefersWatchAndHidesStagesBelowSixtyPercentCoverage",
            "testSleepDoesNotDoubleCountOverlappingNonWatchSourcesOutsideWatchCoverage",
            "testBaselineReadinessAndZeroMADDoNotCreateAnomaly",
            "testTrainingLoadMaturityAndAllLoadRatioBoundaries",
            "testBriefUsesFourIndependentDomainsTwoRecommendationsAndAggregatedCloudContext",
            "testWeightTrendRequiresFourValidDaysInEachSevenDayWindow",
            "testTrainingLoadCountsObservedRestDaysTowardMaturity",
            "testTrainingLoadMakesComparisonUnavailableWhenEffortIsUnknownInWindow",
        ),
        errors,
    )
    require_text(
        "DensosoTests/HealthIntelligenceServiceTests.swift",
        (
            "testRefreshBuildsSevenAndTwentyEightDaySummaryAndCachesBySourceHash",
            "testPreviousWeekUsesItsFullTwentyEightDayBaselineOnSunday",
            "testHistoryBuildsDailyStatesFromThePriorBaselineWithoutWritingBriefCaches",
            "outside-history-window",
            "testHealthHistoryRejectsInvalidAndOversizedRanges",
        ),
        errors,
    )
    require_text(
        "DensosoTests/Application/GetHealthHistoryToolTests.swift",
        (
            "testRegistryExposesStrictReadOnlyBoundedHistoryTool",
            "testResponseContainsOnlyDailyAggregatesAndExplicitEvidenceStatus",
            "testNoHistoryReportsMissingDataInsteadOfZero",
            "testResponseRejectsMoreThanFourteenDaysAndFutureDates",
        ),
        errors,
    )
    require_text(
        "DensosoTests/HealthContextPromptBuilderTests.swift",
        ("testAggregatedHealthContextIsOnlyAttachedToRelevantCloudQuestions",),
        errors,
    )
    require_text(
        "DensosoTests/BriefNotificationSchedulerTests.swift",
        (
            "testNotificationsAreOffByDefaultAndRestoreDoesNotRequestPermission",
            "testDeniedPermissionLeavesReminderDisabled",
            "testLegacyDailyPreferenceMigratesToMorningReminder",
            "testMorningAndEveningTimesAreConfigurableAndCopyUsesLocalSnapshot",
            "testInvalidReminderTimeIsRejected",
        ),
        errors,
    )
    require_text(
        "Densoso/Views/Components/HealthIntelligenceCards.swift",
        ("unavailableEffortCount > 0", "缺少强度数据，暂不比较"),
        errors,
    )
    require_text(
        "docs/gates/gate-07-health-intelligence.md",
        (
            "Status:",
            "`<7`, `7–27`, and `>=28`",
            "Provider context contains only aggregate",
            "Gate 15/16 signed-device acceptance remains blocked",
        ),
        errors,
    )

    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        return 1

    report = {
        "status": "pass",
        "scope": "local-health-intelligence-and-aggregate-context",
        "rawHealthSamplesExposedToProvider": False,
        "notificationsDefaultOff": True,
        "clinicalValidityClaimed": False,
    }
    if args.report:
        Path(args.report).write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print("Phase 7 health-intelligence static contracts: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
