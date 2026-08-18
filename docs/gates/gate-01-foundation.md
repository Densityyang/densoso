# Gate 01 — Foundation

Status: automated gate passed; awaiting user review

This is the first gate in the single staged V3 core Draft PR. A green Gate 1
does not authorize Phase 2; the user must review the recorded CI evidence first.

## Recorded implementation and CI evidence

- Implementation commit: `b970ab9dabc23fb44d6cb9ca36f984ff4c21aa24`
- Draft PR: [#14](https://github.com/Densityyang/densoso/pull/14)
- CI run: [32095852595](https://github.com/Densityyang/densoso/actions/runs/32095852595)
  — `gate-01-foundation` SUCCESS.
- Artifact: `gate-01-foundation-results`, artifact ID `9310216099`.
- Artifact contents: `Gate01UnitTests.xcresult`, `Gate01UITests.xcresult`, six
  `gate01-*.log` files, six PNG screenshots, and `manifest.json`.
- DensosoDomain tests: 27 passed, 0 failures.
- iOS 18 deployment build: `BUILD SUCCEEDED`.
- iOS 26 Simulator unit tests: 49 passed, 0 failures.
- UI tests: 2 passed, 0 failures.
- Watch app and extension build: successful at watchOS 11.
- UI screenshots: six iPhone 17 Pro portrait captures covering onboarding and
  the five current baseline tabs; each was reviewed and showed no top/bottom
  black bands or cropping.
- Signing remains blocked. Unsigned Simulator HealthKit/CoreData warnings are
  not device-signing evidence.
- User decision: pending; do not enter Phase 2.

## Scope

- Lower the iPhone deployment target to iOS 18 while keeping iOS 26 features
  behind explicit availability boundaries.
- Keep watchOS deployment at 11.
- Rename the Foundation-only package from `DensosoWorkoutDomain` to
  `DensosoDomain`.
- Move the Open Food Facts HTTP adapter and its tests into the iOS
  infrastructure boundary.
- Add deterministic, in-memory UI-test fixtures for onboarding and every current
  baseline tab. UI tests must not access real HealthKit, Keychain credentials,
  cloud providers, or the private OCR source directory.
- Establish the `foundation` CI job and artifact contract used by later gates.

## Non-goals

- No SwiftData V3 migration or confirmation transaction work from Phase 2.
- No provider or Agent behavior from Phase 3.
- No audio-session or transcription repair from Phase 4.
- No meal-capture, HealthKit, health-intelligence, or Watch feature expansion.
- No changes to `Densoso/Resources/food_composition_6th_ocr/` or
  `scripts/validate_food_composition_source.py`.
- No claim that unsigned Simulator checks prove signed-device HealthKit behavior.

## Gate contract

The `foundation` job must run and retain evidence for:

1. bundled food database validation;
2. pure `DensosoDomain` package tests;
3. two identical XcodeGen generations;
4. an iOS 18 deployment build;
5. iOS 26 Simulator unit tests;
6. Watch app and extension compilation with watchOS 11 deployment;
7. in-memory UI smoke tests and screenshot attachments;
8. launch-screen bundle validation; and
9. `.xcresult` bundles and build/test logs in `gate-01-foundation-results`.

## Local/static commands

```bash
python3 scripts/validate_food_db.py
python3 scripts/validate_gate0_ui.py
python3 scripts/validate_phase1_foundation.py
python3 scripts/validate_voice_goldens.py --input evals/voice-zh-CN.jsonl
python3 -m py_compile scripts/evaluate_voice_transcripts.py \
  scripts/generate_voice_goldens.py scripts/import_exercise_catalog.py \
  scripts/import_food_db.py scripts/validate_food_db.py \
  scripts/validate_gate0_ui.py scripts/validate_phase1_foundation.py \
  scripts/validate_voice_goldens.py
swift test --package-path Packages/DensosoDomain
```

## Evidence record

| Evidence | Required result | Current result |
| --- | --- | --- |
| PR head | Phase 1 commit on the core Draft PR | `b970ab9dabc23fb44d6cb9ca36f984ff4c21aa24` on Draft PR #14 |
| GitHub Actions | `foundation` succeeds | SUCCESS: run `32095852595` |
| Domain tests | All tests pass | 27 passed, 0 failures |
| iOS deployment build | iOS 18 target compiles | `BUILD SUCCEEDED` |
| iOS Simulator tests | Unit and UI suites pass on iPhone 17 Pro | Unit 49 passed; UI 2 passed |
| Watch build | App and extension compile at watchOS 11 target | Successful |
| UI evidence | Onboarding and five baseline-tab screenshots retained | 6 iPhone 17 Pro portrait PNGs reviewed; no bands/cropping |
| Signing | Explicitly blocked and not inferred from Simulator | `blocked-by-signing` |
| User decision | Approve or reject entry to Phase 2 | Pending review; Phase 2 prohibited |

Later gate jobs must be added only with implemented production code and tests,
using the dependency order documented in `PLAN_v3.md`; empty placeholder jobs do
not count as gates.
