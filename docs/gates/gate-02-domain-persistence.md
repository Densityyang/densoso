# Gate 02 — Domain and Persistence

Status: approved by user on 2026-08-31; Phase 3 authorized

Gate 2 extends the same staged V3 core Draft PR. It may run only after
`gate-01-foundation` succeeds on the same commit, and a green automated result
does not authorize Phase 3 without explicit user approval.

## Scope

- Freeze the real V1 and V2 SwiftData model shapes and migrate through explicit
  bridge schemas into `DensosoSchemaV3`.
- Preserve historical point estimates and algorithm versions without applying
  V3 nutrition algorithms retroactively.
- Persist conversations, messages, pending actions, committed receipts, goal
  profiles, health snapshots, enhanced HealthKit outbox entries, briefs, Watch
  receipts, consent, and future provider-usage metadata.
- Stage actions for 24 hours using canonical payloads and
  `SHA256(actionType | canonicalPayload | clientRequestID)`.
- Confirm meal and weight actions through one transaction containing the local
  record, daily/weekly projections, receipt, and HealthKit outbox entry.
- Weight confirmation resolves the primary profile by `profileKey`, creating
  it when only a secondary profile exists.
- Recover interrupted commits from receipts and return interrupted outbox sends
  to a retryable state without duplicating health records.
- Back up the store before migration; migration failure restores it and enters a
  write-disabled diagnostic mode instead of creating a new writable user store.
- Detect legacy store versions by copying the complete store/WAL/SHM family to
  an isolated temporary directory, then reading Core Data metadata and model
  hashes with the read-only store option. Never hand the user store itself to a
  Core Data or SwiftData inspector that may mutate or migrate it.
- Use an isolated in-memory diagnostic container after recovery failure. Product
  writes are rejected by `PersistenceWriteGate`, and the app exposes only the
  recovery diagnostic view rather than normal record/import/settings flows.
- Remove `ModelContext` and direct Workout writes from the model-facing Agent
  and tool boundary.

## Cumulative schema extension

The original Gate 2 acceptance remains the historical V1/V2-to-V3 migration
record. The current cumulative main-PR branch extends the schema through V9;
V5-to-V6 adds a HealthKit sample-ID/day index with pending projection-day and
deletion state, and rewrites legacy daily snapshot payloads to compact
summaries. The migration groups workouts by local day and uses a single
wake-day overlap index for missing sleep snapshots, preserving cross-midnight
and adjacent-window coverage without rescanning every sample per day.
V1–V7 schema identities remain intact. V7-to-V8 renames the sample-index
tombstone flag while preserving its stored column. V8-to-V9 adds the isolated
`AgentRequestCostBudgetRecord` sidecar without rewriting V5 request rows. When an
older interrupted request has already used provider rounds but has no
recoverable request-cost reservations, restoration marks its cost state
unavailable and stops before another provider call. Gate 2 CI covers V1/V2 disk
fixtures reopened at the current schema, the V5-to-V6 through V8-to-V9
migrations, and request-budget recovery behavior.

## Non-goals

- No Provider retry policy, strict Provider JSON schema, Agent
  event stream, or Markdown rendering from Phase 3.
- No Speech/AVAudioSession repair from Phase 4.
- No candidate ambiguity, portion algorithm, OCR, photo, or VLM work from Phase 5.
- No HealthKit worker or expanded authorization behavior from Phase 6.
- No health-intelligence, WatchConnectivity, WorkoutKit scheduling, four-tab
  redesign, signing acceptance, or private OCR changes.

## Gate contract

The `domain-persistence` job has `needs: foundation` and must prove:

`foundation` remains a cumulative regression gate on the current PR head; the
second job then reruns the Phase 2 suites explicitly so failures are attributable
to domain/persistence behavior and have a dedicated evidence artifact.

1. range non-negativity, ordering, scaling, summation, and validated decoding;
2. canonical action payload stability;
3. concurrent duplicate staging/confirmation produces one record, receipt, and
   logical outbox entry;
4. unconfirmed, rejected, and expired actions write zero health records;
   expired pending rows are retired in stable 64-row batches while committing
   actions remain visible, covered by
   `ConfirmationCoordinatorTests.testActiveActionsExpiresPendingRowsAcrossBoundedBatchesAndKeepsCommitting`;
   active pending and committing actions are returned in stable 64-row pages
   ordered by creation time, covered by
   `ConfirmationCoordinatorTests.testActiveActionsKeysetPagesPendingAndCommittingInCreatedAtOrder`;
5. transaction fault injection rolls back record/projection/receipt/outbox;
6. a crash after commit returns the existing receipt without duplication;
7. interrupted outbox sends become retryable while retaining attempt state;
8. conversation and pending-action state survive repository recreation;
9. V1 and V2 disk stores migrate through the current V8 schema and reopen while
   preserving IDs, relationships, values, cursors, outbox state, and historical
   algorithm versions, covered by
   `DensosoMigrationTests.testV1DiskFixtureMigratesToCurrentSchemaWithoutRecalculation`
   and `DensosoMigrationTests.testV2DiskFixtureMigratesToCurrentSchemaAndPreservesCursorAndOutbox`; and
10. an injected migration failure restores the store, leaves store/WAL/SHM
    unchanged, and causes the write gate and ConfirmationCoordinator to reject
    writes in recovery mode; and
11. metadata-only V1/V2 version inspection does not change the store family.
12. standalone and confirmation-driven daily projections page same-day meals
    and workouts in stable 64-row keyset batches while preserving totals and
    source fingerprints, covered by
    `ConfirmationCoordinatorTests.testConfirmationAndStandaloneProjectionPageCompleteDailyMealsAndWorkouts`;
    confirmation-driven health snapshots read intake from the just-refreshed
    canonical `DailyMetrics` read model and select the latest local weight with
    a one-row query, covered by
    `ConfirmationCoordinatorTests.testConfirmationDailySnapshotPagesMealsAndReadsLatestWeightOnly` and
    `ConfirmationCoordinatorTests.testConfirmationSnapshotDoesNotExposeLegacyPointMealAsCurrentIntake`.
13. crash recovery pages committing actions and sending outbox rows in stable
    64-row keyset batches, then saves all recovered states once, covered by
    `ConfirmationCoordinatorTests.testRecoveryPagesCommittingActionsAndSendingOutboxAcrossBoundaries`.
14. interrupted workout-plan recovery searches confirmed schedule events in
    stable 64-row pages and recognizes an idempotency match beyond page one,
    covered by
    `ConfirmationCoordinatorTests.testRecoveryFindsInterruptedWorkoutPlanAfterFirstScheduleEventPage`.
15. V5-to-V6 migration indexes workouts by day and sleep samples once by
    overlapping wake day, preserving summaries across midnight-adjacent
    windows, covered by
    `DensosoMigrationTests.testV5MigrationIndexesSleepSamplesAcrossMidnightAndAdjacentWindows`.
16. a confirmed meal action remains traceable from the pending action through
    its receipt, local record and HealthKit outbox by action ID and idempotency
    key, covered by
    `ConfirmationCoordinatorTests.testConfirmedActionTraceabilityLinksReceiptLocalRecordAndOutbox`.
17. V8-to-V9 adds an isolated Agent cost-budget sidecar without rewriting the
    existing request ledger. Requests from before V9 with prior provider rounds
    and no recoverable reservations become cost-unavailable and cannot make
    another provider call; new reservations persist their cap and cumulative
    conservative estimate across resume, covered by
    `DensosoMigrationTests.testV8MigrationPreservesInterruptedRequestForSafeCostBudgetBackfill` and
    `AgentRequestResumeTests.testPerRequestCostReservationPersistsAndCannotResetOnResume`.

The restore routine verifies store/WAL/SHM checksums, stages replacement files,
and rolls back ordinary file-operation errors. The immutable migration backup is
retained if the process is terminated during the multi-file replacement; a
power-loss-safe multi-file commit is not claimed by this gate.

## Static commands

```bash
python3 scripts/validate_phase1_foundation.py
python3 scripts/validate_phase2_domain_persistence.py
python3 -m py_compile scripts/validate_phase1_foundation.py \
  scripts/validate_phase2_domain_persistence.py
swift test --package-path Packages/DensosoDomain
```

## Evidence record

| Evidence | Required result | Current result |
| --- | --- | --- |
| PR head | Phase 2 evidence on Draft PR #14 | Implementation `799737713cbb23e16e6eb4e7d7ff66a2005af557`; evidence head `8978b376704456675b4b95d0dabf9ff9bcecdf6d` |
| CI run | Same-head `foundation → domain-persistence` succeeds | Final run `33357491207` — `SUCCESS` |
| Dependency | `foundation` succeeds on the same head | `gate-01-foundation`: passed |
| Domain tests | Range and canonical payload suites pass | `foundation`: 38/38; `domain-persistence`: 38/38 |
| Persistence tests | Concurrency, TTL, rejection, crash and outbox suites pass | Persistence/migration selected tests: 20/20 |
| Runtime | Gate 2 Simulator evidence is captured on the required device | iPhone 17 Pro, iOS 26.2 Simulator |
| Migration tests | V1/V2 disk fixtures migrate and reopen once | V1: `migrated`; V2: `migrated-and-reopened` |
| Recovery tests | Original/backup restored; write attempt fails | `read-only-recovery`; `originalRestored=true`; `backupFileCount=3` |
| Artifact | `.xcresult`, logs and JSON attachments retained | ID `9745960033` (259,612 bytes): `.xcresult`, manifest, 3 JSON reports, 2 logs, and test summary |
| Signing | Remains separate from Simulator evidence | `blocked-by-signing` |
| User decision | Approve or reject entry to Phase 3 | Approved 2026-08-31; Phase 3 authorized |
