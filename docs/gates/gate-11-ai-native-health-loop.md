# Gate 11 — AI-native Health Loop

Status: focused CI gate; this does not certify real HealthKit delivery.

## Scope

Checks the existing local path from HealthKit samples and profile history through
DailyMetrics and HealthState into the DailyLoop snapshot. The selected fixtures
cover effective historical profiles, weight timelines, unknown data, HealthKit
deletion/reprojection, projection fingerprints, and snapshot composition.

## Focused tests

- DensosoDomain: `EffectiveProfileTests`, `WeightTimelineTests`,
  `HealthStateTests`, and `DailyLoopSnapshotTests`.
- iOS tests: `HealthRepositoryTests.testInsertAndDeleteReprojectsTheSameDay`,
  `CaloricEnergySemanticsTests.testProjectionFingerprintIsRepeatableAndChangesWithSourceMetrics`,
  `HealthIntelligenceServiceTests.testHistoryBuildsDailyStatesFromThePriorBaselineWithoutWritingBriefCaches`,
  `DailyLoopSnapshotCompositionTests.testComposerUsesMatchingExistingBriefAndPreservesOptionalState`,
  and `DailyLoopSnapshotCompositionTests.testComposerIncludesOnlyTodayAndTomorrowTrainingSessionsAndSkipsRestDays`.

This gate uses fixtures and simulator persistence only. It does not prove access
to a real person's HealthKit data, authorization, or background delivery.
