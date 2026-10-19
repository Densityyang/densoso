# Gate 11 — AI-native Health Loop

Status: focused CI gate; this does not certify real HealthKit delivery.

## Scope

Checks the existing local path from HealthKit samples and profile history through
DailyMetrics and HealthState into the DailyLoop snapshot. The selected fixtures
cover effective historical profiles, weight timelines, unknown data, HealthKit
deletion/reprojection, projection fingerprints, snapshot composition, and the
structured health-narrative boundary. DeepSeek health summaries validate
evidence keys against local recommendation evidence; metric values remain
deterministically rendered by the app. Narrative validation rejects numeric
claims written with digits or Chinese or English quantity/unit words. Providers
without verified structured output use a deterministic local response.

## Focused tests

- DensosoDomain: `EffectiveProfileTests`, `WeightTimelineTests`,
  `HealthStateTests`, `DailyLoopSnapshotTests`, and `HealthNarrativeTests`.
- iOS tests: `HealthRepositoryTests.testInsertAndDeleteReprojectsTheSameDay`,
  `CaloricEnergySemanticsTests.testProjectionFingerprintIsRepeatableAndChangesWithSourceMetrics`,
  `HealthIntelligenceServiceTests.testHistoryBuildsDailyStatesFromThePriorBaselineWithoutWritingBriefCaches`,
  `HealthNarrativePolicyTests`,
  `DailyLoopSnapshotCompositionTests.testComposerUsesMatchingExistingBriefAndPreservesOptionalState`,
  and `DailyLoopSnapshotCompositionTests.testComposerIncludesOnlyTodayAndTomorrowTrainingSessionsAndSkipsRestDays`.

This gate uses fixtures and simulator persistence only. It does not prove access
to a real person's HealthKit data, authorization, or background delivery.
