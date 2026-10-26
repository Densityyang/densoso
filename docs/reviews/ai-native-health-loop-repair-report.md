# AI-Native Health Loop Repair Report

Date: 2026-10-26
Repository: `Densityyang/densoso`  
Worktree: `E:\howtodo\densoso-ai-native-loop`  
Branch: `codex/ai-native-health-loop`  
Code baseline reviewed in this report: `6ef976dfd34e6ecdbbb96bdc15c4da08f3d8f096`
Associated pull request: none

## Decision

**NOT READY.** Full Gate 1–14 run [#40267935485](https://github.com/Densityyang/densoso/actions/runs/40267935485) targets `6ef976d` and is in progress. At the last observed workflow snapshot, Gate 1 static validation and the pure DensosoDomain package test had passed; simulator preparation was running, with the iOS 18 build and simulator tests not yet started. Run [#40264693729](https://github.com/Densityyang/densoso/actions/runs/40264693729) on `d076595` completed Gate 1 with 494 iOS unit tests and two failures: the `This Friday` and `Monday` cases in `DailyCheckInConfirmationTests.testSelfReportResolverRejectsConflictingOrMalformedExplicitDates` were not rejected; Gate 1 UI tests passed. Gate 2 had started when the old run was force-cancelled. Commit `e7ed46b` fixes the weekday token-boundary defect. Earlier completed Gate 1 evidence, run [#40261281251](https://github.com/Densityyang/densoso/actions/runs/40261281251) on `e54558b`, reported five failures: three date-error classification assertions and `GetMetricsToolTests.testResponseKeepsPartialCoverageAndPagesDailyBreakdownAsValidJSON` encoded 12,908 bytes against the 8,192-byte limit. Commit `a1dcaf8` fixes those findings. `d076595` added the initial durable Watch outbox; `d684811` adds bounded atomic persistence, expiry enforcement, and iPhone-only pending-action confirmation. Run [#40266448669](https://github.com/Densityyang/densoso/actions/runs/40266448669) on `d684811` was cancelled before jobs started. Runs [#40259694920](https://github.com/Densityyang/densoso/actions/runs/40259694920) on `8954dce` and [#40259037874](https://github.com/Densityyang/densoso/actions/runs/40259037874) on `ec298ac` exposed test-source compilation errors corrected in later commits. The timezone/DST projection fixes are also included; same-SHA Actions evidence remains pending.

The real-meal field benchmark remains `BLOCKED/MISSING_EVIDENCE`. Gate 15 signed iPhone/Watch evidence and Gate 16 owner acceptance remain unperformed. Provider fixture tests do not establish live DeepSeek multimodal/structured API behavior. Gate 11/13 now contain p50/p95 performance measurements for a 42-day health refresh and a 12-ingredient meal estimate; current-code results are pending. No local heavy tests were run; tests are assigned to GitHub Actions.

## CI evidence and boundaries

- Run [#39714060743](https://github.com/Densityyang/densoso/actions/runs/39714060743) on `e7d273a` failed in Gate 3 static validation after Gates 1 and 2 passed. The seven failures were static contract/source-location drift involving Provider documentation, pricing, DeepSeek configuration, DailyLoop plan lookup, and DailyCheckIn terminology. The validator exited before writing its fixture report, and the Gate 3 XCTest step did not run.
- Build IPA [#39716002512](https://github.com/Densityyang/densoso/actions/runs/39716002512) succeeded on the original reviewed SHA. It was an unsigned device-build path; it is not full test CI or signed-device acceptance.
- Run [#39917725806](https://github.com/Densityyang/densoso/actions/runs/39917725806) on `70b248a` was superseded and cancelled; it is older partial evidence. Gate 1 failed five assertions across two tests; Gates 2–5 passed; Gate 3 reported 134/134 domain tests and 165/165 iOS tests. Gate 6's static validator failed because it required a sentence absent from the gate document, so Gate 6 XCTest/domain steps did not run. Gate 7 passed. It did not provide Gate 9–14 or full aggregate evidence.
- Run [#39925916390](https://github.com/Densityyang/densoso/actions/runs/39925916390) on `92612ec` and run [#39926774913](https://github.com/Densityyang/densoso/actions/runs/39926774913) on `1ec9cb3` were superseded and cancelled before any jobs started.
- Run [#39927223905](https://github.com/Densityyang/densoso/actions/runs/39927223905) targeted `e3daa44`; it was superseded and cancelled before any jobs started.
- Runs [#39928118439](https://github.com/Densityyang/densoso/actions/runs/39928118439) (`6c1b9dd`), [#39928521018](https://github.com/Densityyang/densoso/actions/runs/39928521018) (`9621491`), and [#39928746526](https://github.com/Densityyang/densoso/actions/runs/39928746526) (`59b5376`) were superseded and cancelled before jobs started.
- Run [#39931797028](https://github.com/Densityyang/densoso/actions/runs/39931797028) targeted `8fc70e4` and failed. Gate 3 static contract validation passed. Retained artifacts show Swift argument-order compilation errors at `HealthIntelligenceTests.swift` (the `proteinGrams`/`dailyDeficitKcal` labels) and `GetMetricsToolTests.swift` (`projectionVersion`/`requiresRecompute`). Those errors prevented multiple independent test targets from compiling; Gate 10 correctly failed its roll-up when upstream evidence failed.
- Run [#40258141876](https://github.com/Densityyang/densoso/actions/runs/40258141876) targeted `332c750`; it was cancelled while Gate 1 was running. Its pure DensosoDomain package step passed, but it is not a full same-SHA result.
- Run [#40258580812](https://github.com/Densityyang/densoso/actions/runs/40258580812) targeted `74ce6c4` and was cancelled after the DST boundary regression was added.
- Run [#40258831376](https://github.com/Densityyang/densoso/actions/runs/40258831376) targeted `68761eb` and was cancelled after snapshot day-key lookup was aligned to the explicit projection calendar.
- Run [#40259037874](https://github.com/Densityyang/densoso/actions/runs/40259037874) targeted `ec298ac` and was force-cancelled after the remaining `GetMetricsToolTests` initializer argument error was diagnosed. Gate 1 static checks, Domain package tests, iOS 18 build, Watch build, and launch-screen validation passed. Gate 1 iOS unit/UI test steps and Gate 2 migration/confirmation test step failed to compile on that same error. Gate 2 static validation and domain contracts passed. This older SHA is not final evidence.
- Run [#40259694920](https://github.com/Densityyang/densoso/actions/runs/40259694920) targeted `8954dce` and was force-cancelled after Gate 1's unit/UI test targets failed to compile at `CalorieEstimatorTests.swift:44` because the compiler could not type-check the 12-ingredient fixture expression in reasonable time. Gate 1 static validation, Domain package tests, and the iOS 18 build passed. Gate 2 was cancelled before its persistence test result was available; this is not final evidence.
- Run [#40261281251](https://github.com/Densityyang/densoso/actions/runs/40261281251) targeted `e54558b`; Gate 1 static checks, Domain package tests, and iOS 18 build completed, but the iOS unit suite failed with five assertions. Gate 1 UI tests passed and the `gate-01-foundation-results` artifact was uploaded. Gate 2 was still running when the successor run was dispatched; the stale run was then force-cancelled to free the branch concurrency slot. This is diagnostic evidence for an older SHA, not current-code acceptance.
- Run [#40263663535](https://github.com/Densityyang/densoso/actions/runs/40263663535) targeted `a1dcaf8` and was force-cancelled during Gate 1's iOS 18 build after the successor commit was pushed. It did not provide a same-SHA Gate 1 result.
- Run [#40264693729](https://github.com/Densityyang/densoso/actions/runs/40264693729) was manually dispatched with `run_scope=full` for `d076595`. Gate 1 failed the two weekday-date assertions described below; Gate 2 had started when the run was force-cancelled.
- Run [#40266448669](https://github.com/Densityyang/densoso/actions/runs/40266448669) was manually dispatched with `run_scope=full` for `d684811` and cancelled before jobs started after the weekday defect was found.
- Run [#40267935485](https://github.com/Densityyang/densoso/actions/runs/40267935485) was manually dispatched with `run_scope=full` for `6ef976d`, because the workflow push trigger includes only `master` and this branch has no PR. At the last observed workflow snapshot, Gate 1 static validation and pure DensosoDomain tests had passed; simulator preparation was running, and the iOS 18 deployment-target build and iOS 26 simulator tests had not started.
- The last known full Build CI pass before this repair series was `3628d42`, earlier than the reviewed HEAD.

## Findings addressed

### GATE-3-001 — validator drift obscured independent test evidence

- **Classification:** `GATE_DEFECT` / `CONTRACT_DRIFT`; **priority:** P1.
- **Affected path:** `scripts/validate_phase3_agent_provider.py`, `.github/workflows/build.yml`, Gate 3 source/config/test contracts.
- **Old behavior:** the static validator could exit before emitting its report, skip Gate 3 XCTest, and leave downstream gates without evidence.
- **Change:** validate real configuration and interfaces rather than brittle long-form wording; write failure diagnostics; continue independent Gate 3 tests; record step outcomes and upload artifacts with `always()`; retain a final fail-closed job result. The full workflow also records Gate 1–14 aggregate statuses.
- **Tests/evidence:** Gate 3 contract tests and run #399177 on `70b248a` passed (165 iOS tests, 134 domain tests). Current-HEAD confirmation is pending in #40267935485.
- **Residual risk:** no current-HEAD full Build result yet.

### BUILD-001 — test-source argument ordering blocked the gate suite

- **Classification:** `CODE_DEFECT` in regression-test source; **priority:** P1.
- **Affected path:** `HealthIntelligenceTests` and `GetMetricsToolTests` compiled by Gates 1–14.
- **Old behavior:** Swift rejected named initializer arguments out of declaration order, preventing the domain and selected iOS test bundles from compiling.
- **Change:** reorder arguments to match the declared initializer signatures. The Gate 12 validator also now asserts the actual provider-message omission and stored-envelope retention behavior instead of requiring a removed helper name.
- **Tests/evidence:** the corrected sources are included in `332c750` and `8954dce`. Gate 1's pure-domain package and iOS 18 build passed on `ec298ac`, while iOS unit/UI test compilation exposed the remaining argument-order defect. Full verification of `6ef976d` is pending in #40267935485.
- **Residual risk:** current-SHA simulator and Gate 2–14 evidence is not yet available.

### BUILD-002 — Swift could not type-check the meal performance fixture

- **Classification:** `CODE_DEFECT` in regression-test source; **priority:** P1.
- **Affected path:** `CalorieEstimatorTests.testDeterministicMealEstimateReportsP50P95AgainstLatencyTarget`, compiled by Gates 1–14.
- **Old behavior:** a 12-item `map` expression combining inferred integer/double arithmetic exceeded Swift's type-checking limit, so Gate 1 unit and UI test targets failed to compile before test execution.
- **Change:** construct a typed `[CalorieEstimator.Ingredient]` with a bounded loop and named intermediate values; the fixture still contains the same 12 deterministic ingredients.
- **CI:** run #40259694920 on `8954dce` reported the compiler diagnostic. Full verification of the corrected source on `6ef976d` is pending in #40267935485. No local tests were run.
- **Residual risk:** current-SHA unit/UI test results are not yet available.

### TIME-001 — daily projection calendar was implicit inside the computation path

- **Classification:** `CONTRACT_DRIFT`; **priority:** P1.
- **Affected path:** `CaloricEngine`, `DailyMetricsProjectionInputReader`, `DailyMetricsProjectionFingerprint`, `DailyMetricsProjector`, and confirmation transaction projection.
- **Old behavior:** input fetch, fingerprint day normalization, HealthKit snapshot day-key lookup, and calculation filtering each consulted `Calendar.current` internally, so a caller could select a day with one timezone and calculate it with another.
- **Change:** pass one explicit `Calendar` through daily input reads, fingerprint context, HealthKit snapshot day-key lookup, and calculation input for both projector and confirmation-transaction paths.
- **Tests added:** non-UTC cross-midnight cases cover Shanghai versus Los Angeles day boundaries for calculation and SwiftData input selection; existing historical recompute coverage includes DST day-end behavior.
- **CI:** full verification on `6ef976d` is pending in #40267935485. No local tests were run.
- **Residual risk:** no current-HEAD Actions result yet.

### HEALTH-001 — Gate 1 fixtures contradicted the projection contract

- **Classification:** `CODE_DEFECT` in the test fixtures; **priority:** P1.
- **Affected path:** `DailyMetricsProjectionFingerprintTests` and `HistoricalMetricsRecomputeServiceTests`.
- **Old behavior:** a “future” goal fixture was only two seconds after midnight, and a supposedly current non-pending row used legacy freshness fields. Both made the test expectations inconsistent with the production projection rules.
- **Change:** use a calendar-day future goal and mark the non-pending fixture with the current projection version and a nonempty fingerprint. Related read-model assertions now preserve observed expenditure separately from estimated intake/deficit, represent absent values as JSON null, and count missing days from the requested window.
- **Tests/evidence:** these assertions run in Gate 1; verification on `6ef976d` is pending in #40267935485.
- **Residual risk:** the previous Gate 1 run on `70b248a` still failed those five assertions; do not call them fixed by CI until a later SHA passes.

### METRICS-001 — Agent daily breakdown dropped availability evidence

- **Classification:** `CONTRACT_DRIFT`; **priority:** P1.
- **Affected path:** `GetMetricsTool` response mapping.
- **Old behavior:** per-day results omitted coverage, energy quality, recompute state, and projection version already present in `DailyMetricsReadResult`.
- **Change:** daily breakdown now returns those fields. `get_metrics` and `get_weekly_deficit` include an explicit note that the 7,700 kcal/kg conversion is rough and is not a body-weight prediction. Dashboard precision is reduced to one decimal and the derived conversion is visually neutral.
- **Tests added/changed:** `GetMetricsToolTests`, `GetWeeklyDeficitToolTests`.
- **CI:** Gate 1 full tests and the Gate 3 tool-test selection on the current code baseline `6ef976d` are pending in #40267935485.
- **Residual risk:** real user-facing behavior awaits current-HEAD Actions and simulator UI evidence.

### METRICS-002 — invalid numeric values inflated coverage

- **Classification:** `CODE_DEFECT`; **priority:** P1.
- **Affected path:** `DailyMetricsUsabilityPolicy.aggregateRanges`, `aggregateSignedRanges`, and `aggregateNumbers`.
- **Old behavior:** coverage counted availability flags without checking whether a value existed or was valid; `nil`, infinity, or negative nutrient values could enter valid-day counts and distort averages.
- **Change:** aggregate coverage now normalizes each value against availability and value validity; number aggregation accepts only finite nonnegative values while preserving pending-recompute state.
- **Tests added:** `DailyMetricsUsabilityTests.testAggregatesDoNotCountMissingOrNonFiniteValuesAsAvailableDays`.
- **CI:** DensosoDomain tests on the current code baseline `6ef976d` are pending in #40267935485.
- **Residual risk:** no current-HEAD Actions result yet.

### HEALTH-002 — signed energy balance lost surplus days in health context

- **Classification:** `CODE_DEFECT`; **priority:** P1.
- **Affected path:** `HealthIntelligenceDay` → 7/28-day `HealthContextSummary`.
- **Old behavior:** `HealthIntelligenceDay` applied a nonnegative validator to `dailyDeficitKcal`, dropping valid negative balances. Summary averages therefore excluded surplus days.
- **Change:** daily deficit input accepts finite signed values, and context coverage now reports valid `dailyDeficitKcal` and `proteinGrams` day counts.
- **Tests added:** `HealthIntelligenceTests.testHealthContextAveragesSignedEnergyBalanceAndReportsItsDenominator`.
- **CI:** Gate 1 and Gate 11 domain/app test selections on the current code baseline `6ef976d` are pending in #40267935485.
- **Residual risk:** no current-HEAD Actions result yet.

### UI-001 — estimates were displayed as observed values

- **Classification:** `CONTRACT_DRIFT`; **priority:** P1.
- **Affected path:** `DashboardScreen` and `WeeklyAnalyticsSnapshot`.
- **Old behavior:** the daily deficit prefix depended only on expenditure quality, so an observed expenditure plus estimated intake could look exact. The weekly chart labeled all values as “actual” and used one color.
- **Change:** daily intake, expenditure, and deficit use their own availability to show an approximate prefix. Weekly estimates/partial bars have a separate legend/color from observed values; the target line has its own style. Rough energy conversion has no favorable-color implication.
- **Tests changed:** `WeeklyAnalyticsServiceTests` asserts that a partial week contains estimated daily deficits and a partial aggregate.
- **CI:** Gate 1 UI screenshots and unit suite on the current code baseline `6ef976d` are pending in #40267935485.
- **Residual risk:** simulator verification is pending; no physical-device visual claim is made.

### HEALTH-003 — unrelated HealthKit cursors invalidated energy projections

- **Classification:** `CODE_DEFECT`; **priority:** P1.
- **Affected path:** `DailyMetricsProjectionFingerprint.context`.
- **Old behavior:** HealthKit cursor anchors and lookback metadata could enter the DailyMetrics fingerprint even when the canonical daily snapshot values were unchanged, causing unnecessary recomputation.
- **Change:** remove cursor progress from fingerprint context. `CaloricEngine` fingerprints the actual HealthKit values consumed by DailyMetrics; a cursor advance alone no longer invalidates the projection.
- **Tests added/changed:** `testSourceProfileAndGoalRevisionsChangeProjectionFingerprint` asserts cursor insertion and anchor/time movement preserve both fingerprint and `computedAt`; `testHealthKitSnapshotValueChangesProjectionFingerprint` asserts a real active-energy snapshot change updates the projection; the unrelated-cursor regression remains.
- **CI:** Gate 1 and Gate 11 selections on the current code baseline `6ef976d` are pending in #40267935485.
- **Residual risk:** current-HEAD fingerprint and write-suppression evidence is pending.

### GATE-6-001 — HealthKit gate approval wording drift

- **Classification:** `GATE_DEFECT` / `CONTRACT_DRIFT`; **priority:** P2.
- **Affected path:** `scripts/validate_phase6_healthkit.py` and the Gate 5 approval/Phase 6 scope statements.
- **Old behavior:** the validator required the literal sentence `Approved by user; Phase 6 may proceed`, while the gate document records `Status: approved by user after successful macOS CI` and says HealthKit delivery workers remain Phase 6. Gate 6 stopped before its domain and iOS tests on older SHA `70b248a`.
- **Change:** validate the approval status and the documented Phase 6 placement that actually exist, without adding an unsupported PR association or inventing a new approval claim.
- **CI:** the corrected validator is included in `8954dce`; its Gate 6 result is pending in #40267935485.
- **Residual risk:** no Gate 6 XCTest evidence exists yet on the current code baseline.

### PERF-HEALTH-001 — historical recompute blocked the main actor with pure math

- **Classification:** `CODE_DEFECT` / `PERFORMANCE`; **priority:** P1.
- **Affected path:** `HistoricalMetricsRecomputeService` → `DailyMetricsProjector` → `CaloricEngine`.
- **Old behavior:** historical projection fingerprinting and deterministic accounting ran synchronously on the main actor after SwiftData reads.
- **Change:** copy the day's meal, workout, profile, weight, HealthKit, and fingerprint inputs into Sendable values on the owning actor; detached utility tasks compute the fingerprint and accounting result. Only the value result returns for `DailyMetrics` construction, context mutation, and save. No SwiftData model or `ModelContext` crosses actors.
- **Tests added:** `HistoricalMetricsRecomputeServiceTests.testDetachedProjectionCalculationMatchesSynchronousProjection`; existing recompute tests exercise the async persistence path.
- **CI:** Gate 11 and full Build run #40267935485 are pending.
- **Residual risk:** ordinary synchronous transactional projection paths still run on their context actor. Today initial-render latency and the end-to-end 300 ms / 1 s performance targets remain unmeasured.

### HEALTH-004 — sibling shorthand escaped third-party subject detection

- **Classification:** `CODE_DEFECT`; **priority:** P1.
- **Affected path:** `DailyCheckInSelfReportResolver.otherPersonCues`.
- **Old behavior:** full sibling terms such as `我哥哥` were rejected, but short forms `我哥/我姐/我弟/我妹` could pass as the user's own status.
- **Change:** add the common shorthand forms to the third-party cue set; mixed self/relative text remains rejected for clarification.
- **Tests added:** third-party golden cases cover all four sibling shorthands.
- **CI:** Gate 3 and full Build run #40267935485 are pending.
- **Residual risk:** the resolver remains intentionally conservative when a message mentions another person.

### HEALTH-005 — unsupported future and weekday expressions defaulted to today

- **Classification:** `CODE_DEFECT` / `CONTRACT_DRIFT`; **priority:** P1.
- **Affected path:** `DailyCheckInSelfReportResolver.validateDate`.
- **Old behavior:** phrases such as `in a few days`, `next few days`, unanchored weekday names, or unsupported slash/Chinese/month-name dates could miss the cue lists and fall through to today's date.
- **Change:** recognize common future-relative English patterns; reject weekday-only dates without a supported day/ISO date; verify weekday consistency when a day is anchored; reject unsupported explicit date formats instead of treating them as today.
- **Tests added:** future phrase, weekday mismatch/conflict, and unsupported explicit-format cases.
- **CI:** Gate 3 and full Build run #40267935485 are pending.
- **Residual risk:** supported explicit dates remain ISO `YYYY-MM-DD`; other formats ask for clarification.

### HEALTH-006 — unsupported-date errors were masked by field validation

- **Classification:** `CODE_DEFECT` / `CONTRACT_DRIFT`; **priority:** P1.
- **Affected path:** `DailyCheckInSelfReportResolver.validate`.
- **Old behavior:** energy/stress/sleep matching ran before `validateDate`, so malformed or unsupported relative dates could be reported as missing/conflicting/model-mismatched fields instead of being rejected as unsupported dates.
- **Change:** validate date evidence immediately after subject and ambiguous-negation checks, before accepting or rejecting proposed self-report field values.
- **Regression evidence:** run #402612 on `e54558b` failed three assertions in `testSelfReportResolverRejectsConflictingOrMalformedExplicitDates` with the wrong error category. Existing golden assertions cover malformed dates, conflicting explicit dates, and future dates.
- **CI:** the fix is in `a1dcaf8`; same-SHA verification is pending in #40267935485.

### METRICS-003 — daily breakdown exceeded the tool output limit

- **Classification:** `CODE_DEFECT` / `CONTRACT_DRIFT`; **priority:** P1.
- **Affected path:** `GetMetricsTool.responseJSON` pagination.
- **Old behavior:** always returning four detailed days produced a 12,908-byte JSON response for the partial-coverage fixture, exceeding the 8,192-byte tool-output limit.
- **Change:** encode progressively smaller pages until the response fits, return a forward-progress `nextStartDate`, and return the standard valid JSON output-limit error if even one row cannot fit. Empty datasets retain an empty, non-truncated page.
- **Regression evidence:** the Gate 1 fixture now checks valid JSON, the 8,192-byte bound, a nonempty page, and that `nextStartDate` points at the first omitted row.
- **CI:** the fix is in `a1dcaf8`; same-SHA verification is pending in #40267935485. No local tests were run.

### METRICS-004 — pending recompute still exposed stale intake totals

- **Classification:** `CODE_DEFECT`; **priority:** P1.
- **Affected path:** `DailyMetricsReadModelMapper` → `get_metrics` intake aggregation.
- **Old behavior:** a current-version projection with meal evidence could keep intake marked `estimated` while `requiresRecompute` was true. The expenditure and deficit were pending, but a stale intake range could still enter a final energy summary.
- **Change:** intake is now marked `pendingRecompute` whenever its daily projection requires recomputation, so the shared aggregation omits the stale value while retaining its pending coverage.
- **Regression coverage added:** the pending-projection `get_metrics` case now includes a nonzero intake and valid meal coverage, then asserts that both daily and aggregate intake remain null with `pendingRecompute` availability.
- **CI:** pending; tests were added but not run locally. This change will be included in the next full GitHub Actions run after the coding batch is complete.

### HEALTH-007 — weekday token boundaries disappeared during normalization

- **Classification:** `CODE_DEFECT`; **priority:** P1.
- **Affected path:** `DailyCheckInSelfReportResolver.weekdays`.
- **Old behavior:** weekday detection used normalized text with spaces removed, then applied English `\b` boundaries. Phrases such as `This Friday` and `Monday I had ...` no longer had a token boundary, so unanchored weekdays could fall through as today.
- **Evidence:** run #40264693729 on `d076595` failed two assertions in `DailyCheckInConfirmationTests.testSelfReportResolverRejectsConflictingOrMalformedExplicitDates`; the failing inputs were `This Friday ...` and `Monday ...`.
- **Change:** detect English weekdays in the original text and keep normalization only for Chinese weekday cues. Existing regression cases cover both forms.
- **CI:** weekday detection fix is in `e7ed46b`; the full batch, including its regression tests, is being verified on `6ef976d` in #40267935485. No local tests were run.

### WATCH-001 — Watch outbox persistence was embedded in the client

- **Classification:** `CODE_DEFECT`; **priority:** P1.
- **Affected path:** `WatchConnectivityClient` outbound command queue.
- **Old behavior:** the client directly encoded/decoded the outbox in `UserDefaults`; corrupt data could be ignored, filesystem write failures were not observable through `UserDefaults.set`, and offline pending messages had no capacity bound.
- **Change:** extract `WatchMessageOutboxStore` at `Densoso/Infrastructure/WatchConnectivity/WatchMessageOutboxStore.swift`; persist with atomic file replacement; migrate the existing `watch.message.outbox.v1` payload after a successful file write; fail closed on unreadable or unwritable storage; reject queues above 128 messages and persisted data above 5 MiB without dropping existing commands.
- **Tests added:** `WatchMessageOutboxStoreTests` covers restart restoration, causal sequence and acknowledgement persistence, legacy migration, corrupt-file rejection, and surfaced file-write failure. `WatchMessageOutboxTests` covers queue-capacity rejection and over-capacity persisted data.
- **CI:** implementation is in `d684811`; full same-SHA verification is pending in #40267935485. Paired-device crash/reconnect acceptance remains Gate 15 evidence.

### WATCH-002 — stale Watch commands could replay and Watch could confirm drafts

- **Classification:** `CODE_DEFECT` / `CONTRACT_DRIFT`; **priority:** P1.
- **Affected path:** `WatchMessageEnvelope`, Watch pending-action UI, and `PhoneWatchConnectivityCoordinator.receive`.
- **Old behavior:** messages had `createdAt` but no expiry. An offline transcript or command could be replayed after a long delay. The Watch UI also emitted `confirm`/`reject`; the phone coordinator executed those requests through its local confirmation coordinator without requiring the user to review the draft on iPhone.
- **Change:** bump the envelope schema to 2 while decoding schema 1; new ordered commands expire after 24 hours and snapshot requests after 15 minutes. Legacy commands derive their expiry from `createdAt`; timestamps over five minutes in the future are rejected. The iPhone persists then terminally rejects expired messages and all Watch-originated confirmation/rejection requests. The Watch now only displays pending actions and directs the user to iPhone.
- **Tests added:** Domain cases cover schema-1 expiry fallback, invalid/overlong expiry, future timestamps, UTF-8 transcript bounds, and the phone-only action policy. Gate 8/14 contract validators now require the expiry and authorization checks and reject Watch action buttons.
- **CI:** implementation, focused domain/app selectors, and gate contracts are committed in `d684811`; no local tests were run. Full same-SHA verification is pending in #40267935485.

## Additional implementation already present on this repair branch

- Durable Agent request deadline, rounds/tool/token/cost accounting, resume checks, transient-image reattachment requirements, bounded provider history, and request-scoped reasoning cleanup.
- Provider usage metadata includes image count; unknown pricing remains non-blocking and is not reported as zero cost.
- DailyLoop snapshot freshness, coverage, error, and projection provenance are explicit.
- DailyCheckIn staging validates self-report evidence, third-party cues, conflicting/ambiguous negation, and supported dates.
- Historical projection uses day-specific profile/weight inputs, current-day `asOf`, pending recompute eligibility, and shared projection/fingerprint behavior.
- Historical pending recompute snapshots inputs before detached pure calculation; transactional writes stay on the owning context actor.
- Gate 5 reports synthetic/software evidence separately from the blocked real-meal field benchmark.

These are implementation statements only; final current-HEAD acceptance depends on Actions and the evidence boundaries below.

## Remaining items and acceptance boundary

- **Gate 1–14:** current full Build run #40267935485 on `6ef976d` is in progress. Gate 1 static validation has passed; the pure DensosoDomain package test is running.
- **Meal field benchmark:** `BLOCKED/MISSING_EVIDENCE` until real photos and kitchen-scale measurements, dataset composition, annotation method, sample size, confidence intervals/percentiles, and failure cases are provided.
- **Gate 15:** `NOT RUN`; signed, paired iPhone/Apple Watch acceptance is manual.
- **Gate 16:** `NOT RUN`; final owner release acceptance is manual.
- **Provider live behavior:** fixture/contract tests do not prove a live DeepSeek multimodal/structured request path.
- **Performance:** Gate 11/13 p50/p95 results are pending in #40267935485. Historical recompute now offloads fingerprinting/accounting from Sendable inputs; ordinary synchronous projection transactions remain on their context actor. Today initial render and end-to-end render/refresh targets are not yet measured.
- **Pull request:** none is associated with this branch; PR #14 is a separate V3 work line.

## Final status

**NOT READY** at code baseline `6ef976dfd34e6ecdbbb96bdc15c4da08f3d8f096`. Run #402612 on `e54558b` exposed date-validation ordering and oversized `get_metrics` output; those fixes are in `a1dcaf8`. Run #402646 on `d076595` exposed two remaining unanchored weekday cases, fixed in `e7ed46b`. Commit `d076595` added an explicit persistent Watch outbox store; `d684811` adds bounded atomic persistence, schema-compatible expiry, and the iPhone confirmation boundary. Full same-SHA CI and performance measurements are pending in #40267935485; field/device acceptance evidence is missing. Update this report after that run completes; do not convert pending or missing evidence to `PASS`.
