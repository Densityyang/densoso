# Gate 10 — Final Software Acceptance

Status: final acceptance definition; the workflow determines success from the exact-commit artifacts below

Phase 10 is the final acceptance pass requested by the user. It is a roll-up
over Phases 1–9, not a new feature phase and not an additional hardware or
signing claim. This existing Gate 10 CI job is a software roll-up; it is not
the product release decision defined by Gate 16.

Gates 11–14 add focused contracts after this roll-up. Gate 15 remains a manual
signed-device acceptance step, and Gate 16 remains a final human release
decision after the automated aggregate for Gates 1–15 and 17–19 and the manual
Gate 15 evidence are reviewed. Simulator output cannot mark Gate 15 or Gate 16
passed.

## Software completion contract

- Gates 1–9 pass in one workflow run against the same tested commit. For a
  `pull_request` run, GitHub Actions checks out its generated merge candidate;
  the acceptance manifest records both that workflow SHA and the PR source
  head SHA.
- All required gate artifacts are present: test result bundles, build/test
  logs, contract reports, integration screenshots and coverage summary.
- Privacy-focused diagnostics export is covered by
  `DiagnosticsExportPrivacyTests` and the Gate 9 whitelist static contract;
  Gate 10 requires that contract in its final roll-up.
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

The final job directly records all nine upstream job results from the same
workflow run. It requires every result to be `success` and verifies the
expected artifact files; artifact presence alone does not turn a failed gate
into a pass. The machine-readable manifest records each gate outcome, missing
artifacts, workflow SHA, PR source SHA, and validation errors. A diagnostic
manifest and summary are initialized before validation and uploaded even when
artifact download or validation fails. A successful roll-up means only that
the committed software passed the defined CI contracts.

## Explicitly not accepted by Gate 10

- Apple signing, TestFlight, production enablement, or removal of the PR
  `blocked-by-signing` label.
- HealthKit background delivery on a signed physical iPhone.
- Watch Series 8 pairing, offline reconnection, or WorkoutKit behavior on a
  signed physical Watch.
- Visual certification of a physical device based solely on simulator
  screenshots.

Hardware and signing acceptance remains `blocked-by-signing` until a signed
iPhone/Watch run supplies the evidence listed by Gates 15 and 16. Gate 10 does
not assign this branch to another pull request or turn a simulator result into
device acceptance.
