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
without verified structured output use a deterministic local response. Agent
today-state, bounded-history, and narrative-context reads now share one
read-only data model inside `HealthProjectionActor`; results cross back as
Sendable domain snapshots, with the UI refresh/cache-write path left separate.
DailyMetrics projection bounds profile revisions, local weights, and HealthKit
snapshot reads by the effective day and uses a keyed single-row lookup for the
target snapshot. HealthKit sample values and device metadata are reduced to
daily summaries before persistence; a sample-ID interval index with unresolved
projection-day keys supports deletion and moved-sample rebuilds. Ambiguous
full-day reads retain history but suppress it from the live projection.
Historical HealthKit weight lookup walks the V6 bodyMass index in bounded,
newest-first batches and skips deleted or unknown daily summaries.

## Focused tests

- DensosoDomain: `EffectiveProfileTests`, `WeightTimelineTests`,
  `DailyHealthSampleSummaryTests`, `HealthStateTests`, `DailyLoopSnapshotTests`,
  and `HealthNarrativeTests`.
- iOS tests: `HealthRepositoryTests.testInsertAndDeleteReprojectsTheSameDay`,
  `HealthRepositoryTests.testProjectionUsesEffectiveProfileAndHistoricalWeightWithoutBorrowingFutureData`,
  `HealthRepositoryTests.testAmbiguousDayRequeryKeepsOldSummaryAndRetriesDeletion`,
  `HealthKitSyncCoordinatorTests.testDeletedSampleRequeriesDayAndCommitsSummaryWithAnchor`,
  `HealthKitSyncCoordinatorTests.testDayRequeryDeduplicatesSamplesAcrossPagesInStableOrder`,
  `HealthRepositoryTests.testAffectedHealthSampleDaysReadsPendingIndexesInBoundedBatches`,
  `HealthRepositoryTests.testUnknownDayRequeryForMovedSampleRetainsBothDaysUntilEachIsAvailable`,
  `HealthRepositoryTests.testRepeatedAnchoredSampleIDsKeepDeterministicIndexWinnerWhenRequeryIsUnknown`,
  `HealthRepositoryTests.testHealthKitWeightProjectionPagesIndexRowsAndSkipsUnknownDays`,
  `HealthRepositoryTests.testLocalWeightProjectionPagesAndPreservesLatestIDTieWinner`,
  `CaloricEnergySemanticsTests.testProjectionFingerprintIsRepeatableAndChangesWithSourceMetrics`,
  `HealthIntelligenceServiceTests.testRefreshBuildsSevenAndTwentyEightDaySummaryAndCachesBySourceHash`,
  `HealthIntelligenceServiceTests.testHistoryBuildsDailyStatesFromThePriorBaselineWithoutWritingBriefCaches`,
  `HealthProjectionActorTests.testTodayNarrativeAndBoundedHistoryShareDeterministicReadModelWithoutCacheWrites`,
  `HealthProjectionActorTests.testActorHistoryRetainsExistingRangeValidation`,
  `HealthProjectionActorTests.testConfirmedPlanEntriesDecodeAndSortBothPlanTypesAndIgnoreOrdinaryEvents`,
  `HealthNarrativePolicyTests`,
  `DailyLoopSnapshotCompositionTests.testComposerUsesMatchingExistingBriefAndPreservesOptionalState`,
  and `DailyLoopSnapshotCompositionTests.testComposerIncludesOnlyTodayAndTomorrowTrainingSessionsAndSkipsRestDays`.

This gate uses fixtures and simulator persistence only. It does not prove access
to a real person's HealthKit data, authorization, or background delivery.
