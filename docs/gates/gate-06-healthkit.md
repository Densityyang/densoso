# Gate 06 — HealthKit Synchronization and Energy Semantics

Status: original Gate 6 passed macOS CI; V5-to-V6 main-PR extension awaits current GitHub CI

Gate 6 extends Draft PR #14 after the user approved Gate 5. It adds the HealthKit
boundary, query/sync path, outbox worker and energy projection rules. The
original Gate 6 implementation retained the V3 schema; the current cumulative
main-PR extension adds the V5-to-V6 daily sample-summary migration described
below without changing V1–V5 schema identities.

## Scope

- `HealthStoreClient` is a Foundation-only boundary. HealthKit types are confined
  to the iOS adapter; authorization scopes, aggregate buckets, samples, anchors,
  writes and receipts are normalized Codable/Sendable values.
- The application sync coordinator receives a persistence protocol, not a
  SwiftData context; HealthKit and persistence adapters remain replaceable by
  deterministic fakes.
- Daily activity energy, resting energy, steps and exercise minutes use
  `HKStatisticsCollectionQuery` with local calendar day boundaries. Discrete
  body metrics, sleep/vitals and Workout changes use sample or anchored queries.
- Aggregate streams use the shared inclusive 42-day lower bound and reproject
  their daily buckets on observer sync. Anchored sample/workout streams keep the
  exact lower bound paired with each HealthKit anchor as the policy window moves;
  changed samples within that predicate are applied, and affected historical
  days are re-queried even when they fall before the current analysis window.
- A stream cursor and the compact daily summary/sample-ID index or daily
  aggregate are saved with one SwiftData save. A failed save rolls back data
  and cursor together. Anchored sample streams keep a persisted lower bound and
  fixed open upper predicate, and advance on successful empty pages;
  a user-initiated Settings resync rebaselines cursors in case HealthKit read
  access changed while the app was not running.
- When HealthKit reports a later limited-history boundary, cached per-metric
  values before the first fully authorized projection day are scrubbed,
  HealthKit-origin workouts and weight rows before that timestamp are removed,
  and body-mass dependent historical projections are recomputed. Sleep uses the
  wake-day window beginning at 18:00 on the prior day.
- If the limited-history boundary lookup fails, the current 42-day projection
  for that metric is marked unknown and anchored cursors are reset. This avoids
  consuming cached values while scope is unresolved and makes the next successful
  sync perform a fresh bounded read.
- The Xcode 26.6 CI SDK does not expose Apple's documented authorization-boundary
  method in its stable HealthKit interface; Apple currently marks that method
  Beta. The adapter therefore emits the typed
  `healthKitAuthorizationBoundaryUnavailable` failure instead of calling a
  missing member or substituting the system-wide `earliestPermittedSampleDate`.
  On this SDK, affected HealthKit streams remain unknown until a supported
  per-type boundary source is available. This is a fail-closed compatibility
  fallback, not evidence that production limited-history synchronization is
  complete.
- Observer updates are only wakeups. The coordinator drains the relevant query
  before calling HealthKit's completion handler, guarded to complete once; an
  observer error completes without starting a sync or advancing a cursor.
- The AI-native loop adds an opportunistic `BGAppRefreshTask` retry path for
  local HealthKit synchronization, health-state projection, notification copy,
  and Watch context. HealthKit observers remain the primary change signal; iOS
  chooses whether and when to run the refresh.
- A failure in one stream does not abort other independent streams; only the
  failed stream retains its prior cursor, and Settings reports partial completion.
- After a prior user-initiated HealthKit request, app launch reinstalls observers
  and runs a foreground incremental sync so missed events can converge.
- iOS target requests HealthKit background delivery in its entitlement. If the
  active signing profile cannot grant it, foreground observer/sync remains
  available and Settings reports that background delivery is unavailable.
- A confirmed meal writes the likely energy point and only known macro values.
  A confirmed manual weight writes body mass; weight edits and deletes queue
  newer upserts or exact owned-sample deletes. Stable sync identifiers and
  monotonically increasing record versions make edits replace prior samples;
  retries reuse the outbox version and deletes use the exact application-owned
  sync identifier, treating an already-absent object as converged.
- Write authorization denial/restriction is terminal; authorization not yet
  requested and locked-device database access remain retryable rather than being
  conflated with a read-denial conclusion.
- The outbox worker queries interrupted and eligible state rows separately,
  orders eligible work in SwiftData, and resolves supersession only among
  entries for the same source record. Future retries and terminal rows are not
  processed during the current pass.
- The app no longer queries workout routes or writes/deletes Workout samples.
  The Watch workout recorder and iPhone session-mirroring listener are removed,
  and the Watch extension no longer requests HealthKit entitlement. Old schema
  fields remain untouched for V1–V3 compatibility, but are no longer active
  data paths. The Watch provides a read-only daily companion and forwards
  transcript/snapshot commands to iPhone. Pending actions can be reviewed on
  Watch, but confirm/reject controls are absent; iPhone rejects any legacy or
  malformed Watch command that attempts either action.
- `DailyMetrics` uses measured HealthKit resting/active energy when present.
  Otherwise it uses the existing BMR/TDEE estimate. Workout count remains
  descriptive; Workout energy is never added to daily active energy.
- Workout-effort re-projection reads every same-day Workout record in stable
  64-row `(date, id)` pages; a focused fixture matches an effort sample to a
  workout on page 2.
- Empty HealthKit reads map to “data unavailable or read scope unknown.” They do
  not claim that the user denied read access; there is no read permission denial
  conclusion inferred from an empty result. When limited-history authorization
  begins later, cached values before that boundary are removed from the metric's
  daily summaries, imported HealthKit workouts/weights are removed from direct
  read paths, and affected daily projections are recomputed. Ambiguous reads
  without a reported boundary keep cached values but mark them unusable while
  that metric's read state is unknown.
- The app read model now passes an explicit HealthKit read-state map into the
  domain projection. A missing map entry is treated as unknown; `noData` is
  emitted only when the relevant streams report an available read with no
  observation. Domain results and vital trends carry typed `unknown` or
  `partial` status, and training-load values are not serialized to tools or
  narrative requests when source coverage is not complete. Legacy cached domain,
  vital, context-summary and training-load payloads without coverage decode
  fail-closed; the health-intelligence cache version is `health-intelligence-v3`.

## V5-to-V6 daily sample summary

V6 rewrites V5 `DailyHealthSnapshot` payloads so raw HealthKit sample values,
source/device details and sync metadata are not stored in the daily cache. The
cache retains per-metric daily aggregates and sleep summaries. A separate index
keeps sample ID, stream, current day key, date interval, unresolved projection
day keys and deletion state so anchored additions/deletions can locate every
affected day, including both sides of a moved sample. After a change, the
coordinator re-queries each affected projection day (sleep uses its wake-date
window) before the summary, index and anchor commit together. If the full-day
read is ambiguous, the prior summary remains stored and that stream is marked
unknown so the live projection does not reuse it as current.

## Gate contract

1. Anchored insertion, update, deletion, duplicate IDs and empty pages converge.
2. Cursor-save failure leaves both cursor and local projection unchanged.
3. Late samples are accepted into their local day and reprojected; empty pages
   advance their cursor and an explicit settings resync rebaselines read streams.
4. One HealthKit Workout UUID yields at most one local Workout record.
   The repository pushes the non-null HealthKit UUID filter into SwiftData,
   collapses duplicate imported rows to the oldest record (then lowest record
   UUID), leaves local workouts untouched, and reprojects every affected day;
   imported changes and their cursor save together.
5. A measured active-energy aggregate is not increased by Workout energy; the
   fallback active-energy interpretation is identical with or without a Workout.
6. Meal/weight retries reuse their sync identifier and version; optional macros
   remain absent rather than becoming fabricated zeroes; later edits/deletes
   supersede stale unsent versions.
7. Delete predicates target only this application's samples, and repeated
   deletion is successful once the owned sample is absent.
8. No-data/read-scope ambiguity never becomes a false “read denied” state.
   Local semantic coverage includes
   `HealthIntelligenceTests.testUnknownHealthKitCoverageRemainsUnknownAndKnownValuesRemainPartial`,
   `HealthIntelligenceTests.testLegacyTrainingLoadCacheWithoutCoverageDecodesUnknownAndOmitsNumericPlaceholders`,
   `HealthIntelligenceTests.testLegacyHealthDomainVitalAndContextCachesFailClosedWithoutCoverage`,
   `HealthStateTests.testUnknownAndPartialDomainStatusesDoNotBecomeUsableRecoveryEvidence`,
   `HealthNarrativeTests.testNarrativeContextOmitsUnknownTrainingLoadZeroPlaceholders`,
   `GetHealthHistoryToolTests.testHistoryResponsePreservesUnknownAndPartialCoverageWithoutAbsenceOrZero`,
   `GetHealthHistoryToolTests.testReadModelHistoryKeepsUnknownHealthKitCoverageTypedWithoutZeroObservations`,
   and `GetTodayHealthStateToolTests.testUnknownTrainingLoadOmitsZeroAndDerivedValuesAndReportsCoverage`.
   Test source presence is not execution evidence; current local semantic test
   execution remains `NOT_MEASURED` until CI reports each result. Live HealthKit
   authorization/read-scope evidence also remains `NOT_MEASURED`.
9. Fake observer delivery verifies anchored synchronization occurs before the
   background completion callback.
10. Background refresh registration is allowlisted in the generated app plist,
    reschedules after each run, cancels on task expiration, and does not invoke
    a model provider.
11. macOS CI retains the result bundle, test summary, logs and static-contract
    report under `gate-06-healthkit-results`.
12. V5-to-V6 migration removes legacy raw samples from encoded snapshots and
    creates the sample-ID/day index; day re-query rebuilds summaries after
    anchored deletions without advancing the cursor on query failure. Static
    contracts also bound pending-index reads, batch index writes, snapshot
    reads for the reverse body-mass lookup, and pending HealthKit outbox work.
    The outbox worker recovers interrupted writes and processes pending/retryable
    entries in 64-row batches using a stable `(createdAt, idempotencyKey)` cursor.
    Supersession checks page same-record, higher-version candidates in the same
    stable 64-row order and preserve canonical sync-identifier matching.
    Local daily weight refresh now selects its newest eligible same-day record
    with a one-row query and excludes the record being deleted.
    Focused
    coverage includes `DensosoMigrationTests.testV5MigrationMovesRawSamplesIntoIndexAndDailySummary`,
    `DailyHealthSampleSummaryTests.testDailySnapshotEncodingKeepsOnlySummaryAndDropsRawSamples`,
    `DailyHealthSampleSummaryTests.testSampleDeduplicationUsesSyncVersionThenStableTieOrder`,
    `HealthKitSyncCoordinatorTests.testDeletedSampleRequeriesDayAndCommitsSummaryWithAnchor`,
    `HealthKitSyncCoordinatorTests.testAuthorizationBoundaryLookupFailureMasksWindowAndResetsAnchoredCursor`,
    `HealthKitSyncCoordinatorTests.testObserverBoundaryLookupFailureMasksWindowAndResetsAnchoredCursor`,
    `HealthKitSyncCoordinatorTests.testDayRequeryDeduplicatesSamplesAcrossPagesInStableOrder`,
    `HealthRepositoryTests.testAffectedHealthSampleDaysReadsPendingIndexesInBoundedBatches`,
    `HealthRepositoryTests.testRepeatedAnchoredSampleIDsKeepDeterministicIndexWinnerWhenRequeryIsUnknown`,
    `HealthRepositoryTests.testUnknownDayRequeryForMovedSampleRetainsBothDaysUntilEachIsAvailable`,
    `HealthRepositoryTests.testHealthKitWeightProjectionPagesIndexRowsAndSkipsUnknownDays`,
    `HealthRepositoryTests.testLocalWeightProjectionPagesAndPreservesLatestIDTieWinner`,
    `HealthRepositoryTests.testDuplicateHealthAggregateBucketsKeepLastBucketPerDay`,
    `ConfirmationCoordinatorTests.testStandaloneAndConfirmationProjectorsUseSameLatestProfileRevision`,
    `HealthRepositoryTests.testImportedWorkoutDedupProcessesUUIDGroupsAcrossFetchBatchBoundary`,
    `HealthRepositoryTests.testOutboxEnqueueReadsMatchingVersionsAndLatestReceiptAmongManyRows`,
    `HealthRepositoryTests.testDeletingLatestSameDayWeightFallsBackToNextLocalThenHealthKitWeight`,
    `HealthRepositoryTests.testBodyMassReplacementPrefersLatestSameDayLocalWeightOverHealthKitSummary`,
    `HealthRepositoryTests.testWorkoutEffortReprojectionPagesSameDayWorkoutsAcross64RowBoundary`,
    `HealthSyncOutboxWorkerTests.testSupersessionCheckPagesPast64SameRecordRows`,
    `HealthSyncOutboxWorkerTests.testInterruptedOutboxRecoveryAndProcessingPagePastBoundedBatch`,
    `HealthRepositoryTests.testAmbiguousDayRequeryKeepsOldSummaryAndRetriesDeletion`,
    and `HealthRepositoryTests.testSleepDeletionTargetsOnlyWakeDaysIntersectingTheStoredInterval`.

## Evidence record

| Evidence | Required result | Current result |
| --- | --- | --- |
| Phase 6 implementation commit | Phase 6 implementation on Draft PR #14 | `b4230aee2961e4aa1e784428935616feba77e42c`; PR #14 remains OPEN, Draft, and `blocked-by-signing` |
| Workflow | Gates 1–6 pass on the same head | [Run 38661937756](https://github.com/Densityyang/densoso/actions/runs/38661937756) — success |
| Prior dependency | Gate 5 succeeds on the same head | 49 domain tests + 44 meal-capture tests, 0 failures; [Gate 5 artifact 11942720241](https://github.com/Densityyang/densoso/actions/runs/38661937756/artifacts/11942720241) |
| Domain package | Foundation-only HealthKit contracts pass | 49 tests, 0 failures |
| iOS tests | Repository, coordinator, outbox and energy semantics pass | 167 cumulative iOS unit tests, 0 failures |
| Static contract | HealthKit boundary, route removal and no Workout writes | Passed in Gate 6 |
| Unknown/partial semantics | Domain/read-tool tests preserve typed coverage and omit unknown load placeholders | Source/test contract present; CI execution `NOT_MEASURED` |
| Artifact | `.xcresult`, summary, logs and contract report retained | [gate-06-healthkit-results, artifact 11942416503](https://github.com/Densityyang/densoso/actions/runs/38661937756/artifacts/11942416503) |
| Device background delivery | Signed-device observer/background matrix | Not claimed; signing remains blocked |
| User decision | Approve or reject entry to Phase 7 | Approved; Phase 7–10 implementation is now included in the cumulative V3 delivery |

## Gate boundary

Simulator fakes validate ordering and transaction behavior, not Apple's real
HealthKit server delivery. No signed-device background-delivery result is
claimed. Gate 6 does not claim medical interpretation, complete Phase 7
health-intelligence behavior, or production/signing acceptance. PR #14 remains
Draft and `blocked-by-signing` unless the user separately approves otherwise.
Weight edit/delete controls are not added in this synchronization gate; the
repository/outbox operations are covered so a later Records UI can call them.
