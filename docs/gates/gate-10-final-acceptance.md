# Gate 10 — Final Software Acceptance

Status: final acceptance definition; the workflow determines success from the exact-commit artifacts below

Phase 10 is the final acceptance pass requested by the user. It is a roll-up
over Phases 1–9, not a new feature phase and not an additional hardware or
signing claim.

## Software completion contract

- Gates 1–9 pass in one workflow run against the same tested commit. For a
  `pull_request` run, GitHub Actions checks out its generated merge candidate;
  the acceptance manifest records both that workflow SHA and the PR source
  head SHA.
- All required gate artifacts are present: test result bundles, build/test
  logs, contract reports, integration screenshots and coverage summary.
- No model, photo, speech or Watch path bypasses an explicit confirmation
  before creating user health data.
- HealthKit projections and writes remain idempotent; WorkoutKit scheduling
  is only attempted for a persisted confirmed plan.
- DeepSeek-only remains the core text route. Qwen remains an explicit optional
  fallback for supported open-ended image/speech tasks only.
- No local vision-model training, custom training-data pipeline, GPU
  dependency, global health score, diagnosis or custom workout-tracking system
  is introduced.
- Protected food OCR source material and its validator are outside this change
  and are not inspected, modified, staged or included in acceptance artifacts.

## Required CI summary

The final job downloads the artifacts from Gates 1–9, verifies their expected
names and writes a machine-readable acceptance manifest. A successful roll-up
means only that the committed software passed the defined CI contracts.

## Explicitly not accepted by Gate 10

- Apple signing, TestFlight, production enablement, or removal of the PR
  `blocked-by-signing` label.
- HealthKit background delivery on a signed physical iPhone.
- Watch Series 8 pairing, offline reconnection, or WorkoutKit behavior on a
  signed physical Watch.
- Visual certification of a physical device based solely on simulator
  screenshots.

PR #14 must remain OPEN, Draft and `blocked-by-signing`. Those device/signing
checks require a paid Apple development team and a later separately approved
hardware validation matrix.
