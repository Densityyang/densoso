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
Agent meal-capture history matching reads persisted meals in stable 128-row
keyset pages before reducing confirmed ingredient IDs.
DailyMetrics projection bounds profile revisions, local weights, and HealthKit
snapshot reads by the effective day and uses a keyed single-row lookup for the
target snapshot. HealthKit sample values and device metadata are reduced to
daily summaries before persistence; a sample-ID interval index with unresolved
projection-day keys supports deletion and moved-sample rebuilds. Ambiguous
full-day reads retain history but suppress it from the live projection.
HealthIntelligenceReadModel pages daily meal protein, weight and workout history
inside its bounded date window.
Daily-loop plan loading pages stored plan events and retains only active sessions
that can appear in today's or tomorrow's snapshot.
Tomorrow-plan inference first checks for any event, then pages confirmed plan
markers and returns on the first non-terminal plan.
Historical HealthKit weight lookup walks the V6 bodyMass index in bounded,
newest-first batches, fetches each batch's daily snapshots together, and skips
deleted or unknown summaries.
BGAppRefreshTask expiration stops later refresh stages, and its completion box
reports completion once while preventing a late expiration from cancelling
subsequent work.
The Today card distinguishes a snapshot read failure from optional health state
that has no available data; read failures show their error and a retry action.
It shows a progress indicator for the first asynchronous read and while retrying,
and skips overlapping refresh calls while one is in flight so loading state
remains consistent.
Agent context reads run only for health questions that need a narrative; plain
capture requests skip the history read. A failed local read is reported as a
read failure rather than presented as missing health data.

## Focused tests

- DensosoDomain: `EffectiveProfileTests`, `WeightTimelineTests`,
  `DailyHealthSampleSummaryTests`, `HealthStateTests`, `DailyLoopSnapshotTests`,
  and `HealthNarrativeTests`.
- iOS tests: `HealthRepositoryTests.testInsertAndDeleteReprojectsTheSameDay`,
  `HealthRepositoryTests.testConfirmedFoodHistoryRepositoryPagesMealsAndDeduplicatesFoodIDs`,
  `HealthRepositoryTests.testProjectionUsesEffectiveProfileAndHistoricalWeightWithoutBorrowingFutureData`,
  `HealthRepositoryTests.testAmbiguousDayRequeryKeepsOldSummaryAndRetriesDeletion`,
  `HealthKitSyncCoordinatorTests.testDeletedSampleRequeriesDayAndCommitsSummaryWithAnchor`,
  `HealthKitSyncCoordinatorTests.testDayRequeryDeduplicatesSamplesAcrossPagesInStableOrder`,
  `HealthRepositoryTests.testAffectedHealthSampleDaysReadsPendingIndexesInBoundedBatches`,
  `HealthRepositoryTests.testUnknownDayRequeryForMovedSampleRetainsBothDaysUntilEachIsAvailable`,
  `HealthRepositoryTests.testRepeatedAnchoredSampleIDsKeepDeterministicIndexWinnerWhenRequeryIsUnknown`,
  `HealthRepositoryTests.testHealthKitWeightProjectionPagesIndexRowsAndSkipsUnknownDays`,
  `HealthRepositoryTests.testLocalWeightProjectionPagesAndPreservesLatestIDTieWinner`,
  `ConfirmationCoordinatorTests.testStandaloneAndConfirmationProjectorsUseSameLatestProfileRevision`,
  `CaloricEnergySemanticsTests.testProjectionFingerprintIsRepeatableAndChangesWithSourceMetrics`,
  `HealthIntelligenceServiceTests.testRefreshBuildsSevenAndTwentyEightDaySummaryAndCachesBySourceHash`,
  `HealthIntelligenceServiceTests.testHistoryBuildsDailyStatesFromThePriorBaselineWithoutWritingBriefCaches`,
  `HealthProjectionActorTests.testTodayNarrativeAndBoundedHistoryShareDeterministicReadModelWithoutCacheWrites`,
  `AgentCoordinatorTests.testHealthContextLoadsOnlyForRelevantHealthQuestions`,
  `AgentCoordinatorTests.testHealthContextReadFailureDoesNotClaimDataIsMissing`,
  `GetTodayHealthStateToolTests.testUnavailableTrainingLoadEncodesMissingRecentLoadAsNull`,
  `GetHealthHistoryToolTests.testResponseCoalescesDuplicateLocalDaysAndDomainStatuses`,
  `GetHealthHistoryToolTests.testResponseTieBreaksEqualTimestampPointsIndependentOfInputOrder`,
  `HealthProjectionActorTests.testHealthContextSummaryAggregatesMealProteinAcrossStableFetchPages`,
  `HealthProjectionActorTests.testLoadDaysIncludesAllWorkoutsAcrossStableFetchPages`,
  `HealthProjectionActorTests.testLoadDaysIncludesAllWeightsAcrossStableFetchPages`,
  `HealthProjectionActorTests.testPlannedWorkoutTomorrowPagesTerminalPlansUntilActiveTrainingPlan`,
  `HealthProjectionActorTests.testActorHistoryRetainsExistingRangeValidation`,
  `HealthProjectionActorTests.testConfirmedPlanEntriesDecodeAndSortBothPlanTypesAndIgnoreOrdinaryEvents`,
  `HealthProjectionActorTests.testConfirmedPlanEntriesPageHistoricalPlansAndDailySnapshotRetainsOnlyCurrentSessions`,
  `DailyLoopBackgroundSchedulerTests.testExpirationAndCompletionAreIdempotentAndLateExpirationDoesNotCancelNextWork`,
  `HealthNarrativePolicyTests`,
  `DailyLoopSnapshotCompositionTests.testComposerUsesMatchingExistingBriefAndPreservesOptionalState`,
  and `DailyLoopSnapshotCompositionTests.testComposerIncludesOnlyTodayAndTomorrowTrainingSessionsAndSkipsRestDays`.

This gate uses fixtures and simulator persistence only. It does not prove access
to a real person's HealthKit data, authorization, or background delivery.
