# Gate 09 — UI, Privacy, Export and Integration

Status: exact-commit result is recorded in the Phase 10 acceptance manifest

Gate 9 integrates the V3 app surfaces and exercises the cumulative software
path after Gates 1–8. It does not turn simulator evidence into signed-device
acceptance.

## Scope

- Four-tab navigation: Today, Trends, Records and Settings. Today remains the
  voice-first interaction, with text and photo capture as alternate inputs.
- Trends presents the four health domains, evidence-linked briefs and
  individual vitals without a global score. Records covers meals, workouts,
  weights and sync state. Settings covers permissions, provider consent,
  diagnostics/cost, goal confirmation, notification settings, export and
  restore.
- Backups use format version 5 for profile history, weights, goals, health
  snapshots, schedules, cached briefs and weekly reports while preserving
  V2/V3/V4 import.
  Active credentials, provider consent, HealthKit cursors and pending sync
  outbox rows are not restored as user data; outbox/cursors are reset on
  restore. Schedule records may contain a confirmed WorkoutKit plan intent.
- UI-test evidence captures all four primary screens in portrait and in a
  large-text/dark appearance configuration. Automated tests assert tab labels
  and screen markers; screenshots remain review artifacts, not proof of a
  physical iPhone render.

## Gate contract

1. Four-tab startup, deep links/navigation, seeded primary screens and
   accessibility labels remain reachable.
2. Consent and confirmation boundaries are preserved across text, voice,
   photo, HealthKit and Watch paths; no model output writes directly.
3. HealthKit changes flow into local daily summaries and Trends; Watch messages
   route to the same phone-side confirmation draft.
4. Backup V2/V3/V4 compatibility and V5 round-trip are tested, including that
   secrets, consent, cursors and active outbox state are excluded/reset.
5. The complete Densoso unit suite and UI suite run on the iPhone 17 simulator
   with coverage, `.xcresult` bundles, logs and four-screen captures retained.
6. Integration evidence is uploaded as `gate-09-integration-results`.

## Evidence boundary

The simulator gate can show that the software paths execute against fakes and
the seeded store. It does not establish real provider credentials, real
HealthKit delivery, real Watch pairing, signed distribution or production use.
PR #14 remains Draft and `blocked-by-signing`.
