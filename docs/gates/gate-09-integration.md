# Gate 09 — UI, Privacy, Export and Integration

Status: exact-commit result is recorded in the Phase 10 acceptance manifest

Gate 9 integrates the V3 app surfaces and exercises the cumulative software
path after Gates 1–8. It does not turn simulator evidence into signed-device
acceptance.

## Scope

- Four-tab navigation: Today, Trends, Records and Settings. Today remains the
  voice-first interaction, with a prominent voice control, secondary photo
  capture, and an explicit editable-text entry. Quick actions and transcripts
  fill editable text and never submit by themselves.
- System App Intents hand meal text and workout plans to a one-shot draft inbox
  in `UserDefaults` and notify the running app directly. Cold startup drains
  both draft types. On scene activation, meal text is always received, while
  the main tab consumes workout plans only when its editor is closed; an
  unconsumed plan remains in the inbox while the editor is open, another plan
  is pending, or the main tab is not yet available.
  Meal text is appended to existing unsent composer text; workout plans open
  their editor automatically and wait behind an editor that is already open.
  Rapid meal-text intents accumulate as editable paragraphs, including when two
  intents contain identical text. Scene-active restoration reconciles a
  mirrored state/inbox aggregate without appending that same draft again.
  At most 16 plans are queued; when full, the incoming draft stays in the
  one-shot inbox until the open editor closes. Meal records and WorkoutKit
  scheduling still require the existing in-app confirmation steps.
- Trends presents the four health domains, evidence-linked briefs and
  individual vitals without a global score. Records covers meals, workouts,
  weights and sync state. Settings covers permissions, provider consent,
  diagnostics/cost, goal confirmation, notification settings, export and
  restore.
- Records history queries only the selected record kind and optional day
  window in stable 64-row pages, with an explicit load-older action. It reloads
  the selected records after relevant saves when no older page remains; while
  older rows remain, inserts, updates and invalidations preserve the reader
  position and show a
  "记录已更新，刷新列表" action to return to the newest page. Refresh and
  filter changes clear the action; deletes do not show a misleading newer-row
  action. Outbox/cursor saves refresh sync status only. Counts use database
  counts instead of materializing the full HealthKit outbox.
- Backups use format version 7 for profile history, weights, goals, health
  snapshots, schedules, cached briefs, weekly reports, check-ins, preferences
  and meal priors. Restore accepts formats V2 through V7; legacy V2, V3 and V5
  fixtures and the current V7 round-trip are covered by the export tests.
  Export reads every collection in ordered 64-row SwiftData pages, retaining
  the complete backup contents and existing serialization order.
  Restore likewise pages request/message history in batches while retaining
  completed and legacy conversation messages and removing unfinished fragments.
  Active credentials, provider consent, HealthKit cursors and pending sync
  outbox rows are not restored as user data; outbox/cursors are reset on
  restore. Schedule records may contain a confirmed WorkoutKit plan intent.
- UI-test evidence captures all four primary screens in portrait and in a
  large-text/dark appearance configuration. Automated tests assert tab labels
  and screen markers; screenshots remain review artifacts, not proof of a
  physical iPhone render.
- Privacy-focused diagnostics export offers a shareable JSON file with only
  OS/app/schema, provider/model, latency/usage/error codes, aggregate sync and
  projection status, provider-scoped cloud-policy revisions, bounded 42-day
  per-metric coverage counts/limitation flags, sanitized per-stream cursor
  watermarks, daily-loop generation time, earliest requested background
  refresh, and Watch availability. Coverage omits target/sample dates and raw
  values. Meals, weights, HealthKit metrics/samples, opaque anchors, notes,
  transcripts, preferences, API keys, policy contents, and consent contents are
  excluded and checked by `DiagnosticsExportPrivacyTests`.

## Gate contract

1. Four-tab startup, deep links/navigation, seeded primary screens and
   accessibility labels remain reachable.
2. Consent and confirmation boundaries are preserved across text, voice,
   photo, HealthKit and Watch paths; no model output writes directly. AppIntent
   meal text and workout-plan handoffs arrive on cold launch and scene
   activation as one-shot editable drafts that preserve unsent text and require
   in-app confirmation; an open workout editor defers consuming another plan.
3. HealthKit changes flow into local daily summaries and Trends; Watch messages
   route to the same phone-side confirmation draft.
4. Legacy V2/V3/V5 backup fixtures and the current V7 round-trip are tested,
   including exclusion/reset of secrets, consent, cursors and active outbox
   state; a
   65-meal export fixture and 65-request restore fixture cross their page
   boundaries without losing eligible records.
   Records history also retains 65 selected-day records of each kind across its
   page boundaries.
5. The complete Densoso unit suite and UI suite run on the iPhone 17 simulator
   with coverage, `.xcresult` bundles, logs and four-screen captures retained.
6. Integration evidence is uploaded as `gate-09-integration-results`.

## Evidence boundary

The simulator gate can show that the software paths execute against fakes and
the seeded store. It does not establish real provider credentials, real
HealthKit delivery, real Watch pairing, signed distribution or production use.
Signed-device acceptance remains `blocked-by-signing` until Gate 15 and Gate 16
have their separate device and signing evidence.
