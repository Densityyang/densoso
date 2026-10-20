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
full-day reads retain history but suppress it from the live projection. Pending
sample-index traversal uses stable, bounded 400-row pages; targeted UUID
membership queries are limited to 64 IDs, and deletion cleanup collects target
rows before changing the paged result set.
DailyMetrics fingerprints include source-record revisions, only HealthKit
cursors covering the projected day, the effective profile and goal revisions,
and the calorie-accounting algorithm version. Both projection entry points
share the same fingerprint comparison and skip writes when inputs are unchanged;
pending legacy rows still run through projection. Daily-brief cache versions
include the recommendation-policy version, while DailyLoop exposes its own
algorithm version for its on-demand composed snapshot.
HealthIntelligenceReadModel pages daily meal protein, weight and workout history
inside its bounded date window.
Daily-loop plan loading pages stored plan events and retains only active sessions
that can appear in today's or tomorrow's snapshot.
Tomorrow-plan inference first checks for any event, then pages confirmed plan
markers and returns on the first non-terminal plan.
Historical HealthKit weight lookup walks the V6 bodyMass index in bounded,
newest-first batches, fetches each batch's daily snapshots together, and skips
deleted or unknown summaries.
HealthKit stream failures retain a safe `HealthKitSyncError` diagnostic with
the stream, descriptor code/reason, and request ID; raw underlying error text
is omitted.
Historical DailyMetrics recompute scans only the existing `requiresRecompute`
rows in the most recent 90 local days. It preflights the effective profile's
valid DOB and that day's `WeightTimeline` result before calling the sole
`DailyMetricsProjector`; complete HealthKit basal/active values cannot bypass
either missing prerequisite. Ineligible rows surface no expenditure estimate;
the row and `requiresRecompute` flag stay unchanged, so legacy values are not
shown and no value is invented. The background batch projects at most ten eligible
days, saves each completed row before continuing, and yields between rows so
BGAppRefresh cancellation stops later work. Remaining eligible days request an
earlier retry; a restart can resume from rows whose flag is still set. No schema
field or migration is needed. Ordinary reproject callers use the same gate for
pending historical rows while preserving current-day behavior.
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
On foreground activation after local midnight, the app refreshes only when both
the cached brief and last successful refresh are from an older day, then updates
the Watch snapshot; failures keep the last successful cache for a later retry.

## Focused tests

- DensosoDomain: `EffectiveProfileTests`, `WeightTimelineTests`,
  `DailyHealthSampleSummaryTests`, `HealthStateTests`, `DailyLoopSnapshotTests`,
  `HealthNarrativeTests`, and `SharedErrorDescriptorTests` (the shared error
  code and safe HealthKit/Watch description contract). `DailyLoopSnapshotTests`
  also pins all main-PR algorithm versions and the daily-brief cache version.
- iOS tests: `HealthRepositoryTests.testInsertAndDeleteReprojectsTheSameDay`,
  `HealthRepositoryTests.testConfirmedFoodHistoryRepositoryPagesMealsAndDeduplicatesFoodIDs`,
  `HealthRepositoryTests.testProjectionUsesEffectiveProfileAndHistoricalWeightWithoutBorrowingFutureData`,
  `HealthRepositoryTests.testAmbiguousDayRequeryKeepsOldSummaryAndRetriesDeletion`,
  `HealthRepositoryTests.testPendingDeletedSampleIndexesFinishCleanupAcrossMutatingPages`,
  `HealthKitSyncCoordinatorTests.testDeletedSampleRequeriesDayAndCommitsSummaryWithAnchor`,
  `HealthKitSyncCoordinatorTests.testDayRequeryDeduplicatesSamplesAcrossPagesInStableOrder`,
  `HealthKitSyncCoordinatorTests.testOneFailedStreamDoesNotBlockOtherHealthMetrics`,
  `HealthSyncOutboxWorkerTests.testRetryReusesStableSyncIdentifierAndVersion`,
  `HealthSyncOutboxWorkerTests.testInterruptedSendingEntryIsRecoveredAndRetried`,
  `HealthSyncOutboxWorkerTests.testInterruptedOutboxRecoveryAndProcessingPagePastBoundedBatch`,
  `BriefNotificationSchedulerTests.testNotificationErrorsExposeSharedSafeDescriptors`,
  `HealthRepositoryTests.testAffectedHealthSampleDaysReadsPendingIndexesInBoundedBatches`,
  `HealthRepositoryTests.testUnknownDayRequeryForMovedSampleRetainsBothDaysUntilEachIsAvailable`,
  `HealthRepositoryTests.testRepeatedAnchoredSampleIDsKeepDeterministicIndexWinnerWhenRequeryIsUnknown`,
  `HealthRepositoryTests.testHealthKitWeightProjectionPagesIndexRowsAndSkipsUnknownDays`,
  `HealthRepositoryTests.testLocalWeightProjectionPagesAndPreservesLatestIDTieWinner`,
  `ConfirmationCoordinatorTests.testStandaloneAndConfirmationProjectorsUseSameLatestProfileRevision`,
  `CaloricEnergySemanticsTests.testProjectionFingerprintIsRepeatableAndChangesWithSourceMetrics`,
  `DailyMetricsProjectionFingerprintTests.testUnchangedFingerprintSkipsWriteButPendingLegacyMetricIsReprojected`,
  `DailyMetricsProjectionFingerprintTests.testSourceCursorProfileAndGoalRevisionsChangeProjectionFingerprint`,
  `DailyMetricsProjectionFingerprintTests.testWorkoutEnergyAndProvenanceChangesProjectionFingerprint`,
  `HealthIntelligenceServiceTests.testRefreshBuildsSevenAndTwentyEightDaySummaryAndCachesBySourceHash`,
  `HealthIntelligenceServiceTests.testHistoryBuildsDailyStatesFromThePriorBaselineWithoutWritingBriefCaches`,
  `HealthProjectionActorTests.testTodayNarrativeAndBoundedHistoryShareDeterministicReadModelWithoutCacheWrites`,
  `AgentCoordinatorTests.testHealthContextLoadsOnlyForRelevantHealthQuestions`,
  `AgentCoordinatorTests.testHealthContextReadFailureDoesNotClaimDataIsMissing`,
  `DailyBriefRefreshPolicyTests.testActivationRefreshWaitsForInitialRefreshAndOnlyRefreshesStaleLocalDay`,
  `GetTodayHealthStateToolTests.testProviderReadFailurePropagatesInsteadOfReturningUnavailable`,
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
  `HistoricalMetricsRecomputeServiceTests.testRecomputesOnlyExistingEligiblePendingMetricsWithinBatch`,
  `HistoricalMetricsRecomputeServiceTests.testMissingDOBDoesNotLetObservedEnergyClearRecomputeFlag`,
  `HistoricalMetricsRecomputeServiceTests.testOrdinaryHistoricalReprojectKeepsPendingFlagWhenDOBMissingWithObservedEnergy`,
  `HistoricalMetricsRecomputeServiceTests.testCurrentDayReprojectRetainsObservedEnergyBehaviorWithoutProfileOrWeight`,
  `HistoricalMetricsRecomputeServiceTests.testMissingWeightDoesNotLetObservedEnergyClearRecomputeFlag`,
  `HistoricalMetricsRecomputeServiceTests.testCancellationStopsAfterSavedRowAndReportsRetryableWork`,
  `ConfirmationCoordinatorTests.testHistoricalConfirmationKeepsPendingMetricsWhenProfileAndWeightAreMissing`,
  `HealthNarrativePolicyTests`,
  `DailyLoopSnapshotCompositionTests.testComposerUsesMatchingExistingBriefAndPreservesOptionalState`,
  and `DailyLoopSnapshotCompositionTests.testComposerIncludesOnlyTodayAndTomorrowTrainingSessionsAndSkipsRestDays`.

This gate uses fixtures and simulator persistence only. It does not prove access
to a real person's HealthKit data, authorization, or background delivery.
