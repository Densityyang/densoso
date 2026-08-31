# Gate 02 — Domain and Persistence

Status: awaiting CI evidence and user review

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
- Recover interrupted commits from receipts and return interrupted outbox sends
  to a retryable state without duplicating health records.
- Back up the store before migration; migration failure restores it and enters a
  write-disabled diagnostic mode instead of creating a new writable user store.
- Detect legacy store versions through read-only Core Data metadata and model
  hashes; never probe the user store by opening a SwiftData container that may
  migrate it.
- Use an isolated in-memory diagnostic container after recovery failure. Product
  writes are rejected by `PersistenceWriteGate`, and the app exposes only the
  recovery diagnostic view rather than normal record/import/settings flows.
- Remove `ModelContext` and direct Workout writes from the model-facing Agent
  and tool boundary.

## Non-goals

- No Provider retry/budget/usage behavior, strict Provider JSON schema, Agent
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
5. transaction fault injection rolls back record/projection/receipt/outbox;
6. a crash after commit returns the existing receipt without duplication;
7. interrupted outbox sends become retryable while retaining attempt state;
8. conversation and pending-action state survive repository recreation;
9. V1 and V2 disk stores migrate to V3 while preserving IDs, relationships,
   values, cursors, and historical algorithm versions; and
10. an injected migration failure restores the store, leaves store/WAL/SHM
    unchanged, and causes the write gate and ConfirmationCoordinator to reject
    writes in recovery mode; and
11. metadata-only V1/V2 version inspection does not change the store family.

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
| PR head | Phase 2 commit on Draft PR #14 | Pending publish |
| Dependency | `foundation` succeeds on the same head | Pending CI |
| Domain tests | Range and canonical payload suites pass | Pending CI |
| Persistence tests | Concurrency, TTL, rejection, crash and outbox suites pass | Pending CI |
| Migration tests | V1/V2 disk fixtures migrate and reopen once | Pending CI |
| Recovery tests | Original/backup restored; write attempt fails | Pending CI |
| Artifact | `.xcresult`, logs and JSON attachments retained | Pending CI |
| Signing | Remains separate from Simulator evidence | `blocked-by-signing` |
| User decision | Approve or reject entry to Phase 3 | Pending review |
