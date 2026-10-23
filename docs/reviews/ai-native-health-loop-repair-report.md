# AI-Native Health Loop Repair Report

Date: 2026-10-23  
Repository: `Densityyang/densoso`  
Worktree: `E:\howtodo\densoso-ai-native-loop`  
Branch: `codex/ai-native-health-loop`  
Code baseline reviewed in this report: `6c1b9dde73e551174de0fe27dbbe1177eda10161`
Associated pull request: none

## Decision

**NOT READY.** The current full Build workflow, run [#39928118439](https://github.com/Densityyang/densoso/actions/runs/39928118439), is pending on this code baseline with no jobs or artifacts yet. The latest per-gate evidence is from older SHA `70b248a`: Gate 1 failed five assertions, Gates 2–5 passed, Gate 6 stopped at static validation, and Gate 7 started. That older run is not full-CI acceptance. Gate 1 fixtures and the Gate 6 static check have since been corrected; current-HEAD Actions evidence is pending.

The real-meal field benchmark remains `BLOCKED/MISSING_EVIDENCE`. Gate 15 signed iPhone/Watch evidence and Gate 16 owner acceptance remain unperformed. Provider fixture tests do not establish live DeepSeek multimodal/structured API behavior. Gate 11/13 now contain p50/p95 performance measurements for a 42-day health refresh and a 12-ingredient meal estimate; current-code results are pending. No local heavy tests were run; tests are assigned to GitHub Actions.

## CI evidence and boundaries

- Run [#39714060743](https://github.com/Densityyang/densoso/actions/runs/39714060743) on `e7d273a` failed in Gate 3 static validation after Gates 1 and 2 passed. The seven failures were static contract/source-location drift involving Provider documentation, pricing, DeepSeek configuration, DailyLoop plan lookup, and DailyCheckIn terminology. The validator exited before writing its fixture report, and the Gate 3 XCTest step did not run.
- Build IPA [#39716002512](https://github.com/Densityyang/densoso/actions/runs/39716002512) succeeded on the original reviewed SHA. It was an unsigned device-build path; it is not full test CI or signed-device acceptance.
- Run [#39917725806](https://github.com/Densityyang/densoso/actions/runs/39917725806) on `70b248a` is older than the current HEAD. Gate 1 failed five assertions across two tests; Gates 2–5 passed; Gate 3 reported 134/134 domain tests and 165/165 iOS tests. Gate 6's static validator then failed because it required a sentence absent from the gate document, so Gate 6 XCTest/domain steps did not run. Gate 7 started afterward; no Gate 8–14 evidence or final aggregate is available yet. This is partial, older-SHA evidence, not a full CI pass.
- Run [#39925916390](https://github.com/Densityyang/densoso/actions/runs/39925916390) on `92612ec` and run [#39926774913](https://github.com/Densityyang/densoso/actions/runs/39926774913) on `1ec9cb3` were superseded and cancelled before any jobs started.
- Run [#39927223905](https://github.com/Densityyang/densoso/actions/runs/39927223905) targeted `e3daa44`; it was superseded and cancelled before any jobs started.
- Run [#39928118439](https://github.com/Densityyang/densoso/actions/runs/39928118439) targets `6c1b9dd`; it is pending and has no job results or artifacts yet.
- The last known full Build CI pass before this repair series was `3628d42`, earlier than the reviewed HEAD.

## Findings addressed

### GATE-3-001 — validator drift obscured independent test evidence

- **Classification:** `GATE_DEFECT` / `CONTRACT_DRIFT`; **priority:** P1.
- **Affected path:** `scripts/validate_phase3_agent_provider.py`, `.github/workflows/build.yml`, Gate 3 source/config/test contracts.
- **Old behavior:** the static validator could exit before emitting its report, skip Gate 3 XCTest, and leave downstream gates without evidence.
- **Change:** validate real configuration and interfaces rather than brittle long-form wording; write failure diagnostics; continue independent Gate 3 tests; record step outcomes and upload artifacts with `always()`; retain a final fail-closed job result. The full workflow also records Gate 1–14 aggregate statuses.
- **Tests/evidence:** Gate 3 contract tests and run #399177 on `70b248a` passed (165 iOS tests, 134 domain tests). Current-HEAD confirmation is pending in #399281.
- **Residual risk:** no current-HEAD full Build result yet.

### HEALTH-001 — Gate 1 fixtures contradicted the projection contract

- **Classification:** `CODE_DEFECT` in the test fixtures; **priority:** P1.
- **Affected path:** `DailyMetricsProjectionFingerprintTests` and `HistoricalMetricsRecomputeServiceTests`.
- **Old behavior:** a “future” goal fixture was only two seconds after midnight, and a supposedly current non-pending row used legacy freshness fields. Both made the test expectations inconsistent with the production projection rules.
- **Change:** use a calendar-day future goal and mark the non-pending fixture with the current projection version and a nonempty fingerprint. Related read-model assertions now preserve observed expenditure separately from estimated intake/deficit, represent absent values as JSON null, and count missing days from the requested window.
- **Tests/evidence:** these assertions run in Gate 1; the latest run containing these fixes is still pending.
- **Residual risk:** the previous Gate 1 run on `70b248a` still failed those five assertions; do not call them fixed by CI until a later SHA passes.

### METRICS-001 — Agent daily breakdown dropped availability evidence

- **Classification:** `CONTRACT_DRIFT`; **priority:** P1.
- **Affected path:** `GetMetricsTool` response mapping.
- **Old behavior:** per-day results omitted coverage, energy quality, recompute state, and projection version already present in `DailyMetricsReadResult`.
- **Change:** daily breakdown now returns those fields. `get_metrics` and `get_weekly_deficit` include an explicit note that the 7,700 kcal/kg conversion is rough and is not a body-weight prediction. Dashboard precision is reduced to one decimal and the derived conversion is visually neutral.
- **Tests added/changed:** `GetMetricsToolTests`, `GetWeeklyDeficitToolTests`.
- **CI:** Gate 1 full tests and the Gate 3 tool-test selection on the current code baseline are pending.
- **Residual risk:** real user-facing behavior awaits current-HEAD Actions and simulator UI evidence.

### METRICS-002 — invalid numeric values inflated coverage

- **Classification:** `CODE_DEFECT`; **priority:** P1.
- **Affected path:** `DailyMetricsUsabilityPolicy.aggregateRanges`, `aggregateSignedRanges`, and `aggregateNumbers`.
- **Old behavior:** coverage counted availability flags without checking whether a value existed or was valid; `nil`, infinity, or negative nutrient values could enter valid-day counts and distort averages.
- **Change:** aggregate coverage now normalizes each value against availability and value validity; number aggregation accepts only finite nonnegative values while preserving pending-recompute state.
- **Tests added:** `DailyMetricsUsabilityTests.testAggregatesDoNotCountMissingOrNonFiniteValuesAsAvailableDays`.
- **CI:** DensosoDomain tests on the current code baseline are pending.
- **Residual risk:** no current-HEAD Actions result yet.

### HEALTH-002 — signed energy balance lost surplus days in health context

- **Classification:** `CODE_DEFECT`; **priority:** P1.
- **Affected path:** `HealthIntelligenceDay` → 7/28-day `HealthContextSummary`.
- **Old behavior:** `HealthIntelligenceDay` applied a nonnegative validator to `dailyDeficitKcal`, dropping valid negative balances. Summary averages therefore excluded surplus days.
- **Change:** daily deficit input accepts finite signed values, and context coverage now reports valid `dailyDeficitKcal` and `proteinGrams` day counts.
- **Tests added:** `HealthIntelligenceTests.testHealthContextAveragesSignedEnergyBalanceAndReportsItsDenominator`.
- **CI:** Gate 1 and Gate 11 domain/app test selections on the current code baseline are pending.
- **Residual risk:** no current-HEAD Actions result yet.

### UI-001 — estimates were displayed as observed values

- **Classification:** `CONTRACT_DRIFT`; **priority:** P1.
- **Affected path:** `DashboardScreen` and `WeeklyAnalyticsSnapshot`.
- **Old behavior:** the daily deficit prefix depended only on expenditure quality, so an observed expenditure plus estimated intake could look exact. The weekly chart labeled all values as “actual” and used one color.
- **Change:** daily intake, expenditure, and deficit use their own availability to show an approximate prefix. Weekly estimates/partial bars have a separate legend/color from observed values; the target line has its own style. Rough energy conversion has no favorable-color implication.
- **Tests changed:** `WeeklyAnalyticsServiceTests` asserts that a partial week contains estimated daily deficits and a partial aggregate.
- **CI:** Gate 1 UI screenshots and unit suite on the current code baseline are pending.
- **Residual risk:** simulator verification is pending; no physical-device visual claim is made.

### HEALTH-003 — unrelated HealthKit cursors invalidated energy projections

- **Classification:** `CODE_DEFECT`; **priority:** P1.
- **Affected path:** `DailyMetricsProjectionFingerprint.context`.
- **Old behavior:** HealthKit cursor anchors and lookback metadata could enter the DailyMetrics fingerprint even when the canonical daily snapshot values were unchanged, causing unnecessary recomputation.
- **Change:** remove cursor progress from fingerprint context. `CaloricEngine` fingerprints the actual HealthKit values consumed by DailyMetrics; a cursor advance alone no longer invalidates the projection.
- **Tests added/changed:** `testSourceProfileAndGoalRevisionsChangeProjectionFingerprint` asserts cursor insertion and anchor/time movement preserve both fingerprint and `computedAt`; `testHealthKitSnapshotValueChangesProjectionFingerprint` asserts a real active-energy snapshot change updates the projection; the unrelated-cursor regression remains.
- **CI:** Gate 1 and Gate 11 selections on the current code baseline are pending in #399281.
- **Residual risk:** current-HEAD fingerprint and write-suppression evidence is pending.

### GATE-6-001 — HealthKit gate approval wording drift

- **Classification:** `GATE_DEFECT` / `CONTRACT_DRIFT`; **priority:** P2.
- **Affected path:** `scripts/validate_phase6_healthkit.py` and the Gate 5 approval/Phase 6 scope statements.
- **Old behavior:** the validator required the literal sentence `Approved by user; Phase 6 may proceed`, while the gate document records `Status: approved by user after successful macOS CI` and says HealthKit delivery workers remain Phase 6. Gate 6 stopped before its domain and iOS tests on older SHA `70b248a`.
- **Change:** validate the approval status and the documented Phase 6 placement that actually exist, without adding an unsupported PR association or inventing a new approval claim.
- **CI:** the corrected validator is included in #399281; its Gate 6 result is pending.
- **Residual risk:** no Gate 6 XCTest evidence exists yet on the current code baseline.

### PERF-HEALTH-001 — historical recompute blocked the main actor with pure math

- **Classification:** `CODE_DEFECT` / `PERFORMANCE`; **priority:** P1.
- **Affected path:** `HistoricalMetricsRecomputeService` → `DailyMetricsProjector` → `CaloricEngine`.
- **Old behavior:** historical projection fingerprinting and deterministic accounting ran synchronously on the main actor after SwiftData reads.
- **Change:** copy the day's meal, workout, profile, weight, HealthKit, and fingerprint inputs into Sendable values on the owning actor; detached utility tasks compute the fingerprint and accounting result. Only the value result returns for `DailyMetrics` construction, context mutation, and save. No SwiftData model or `ModelContext` crosses actors.
- **Tests added:** `HistoricalMetricsRecomputeServiceTests.testDetachedProjectionCalculationMatchesSynchronousProjection`; existing recompute tests exercise the async persistence path.
- **CI:** Gate 11 and full Build run #399281 are pending.
- **Residual risk:** ordinary synchronous transactional projection paths still run on their context actor. Today initial-render latency and the end-to-end 300 ms / 1 s performance targets remain unmeasured.

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

- **Gate 1–14:** current full Build run #39928118439 is pending. Record its complete same-SHA status and artifacts before making a software-CI claim.
- **Meal field benchmark:** `BLOCKED/MISSING_EVIDENCE` until real photos and kitchen-scale measurements, dataset composition, annotation method, sample size, confidence intervals/percentiles, and failure cases are provided.
- **Gate 15:** `NOT RUN`; signed, paired iPhone/Apple Watch acceptance is manual.
- **Gate 16:** `NOT RUN`; final owner release acceptance is manual.
- **Provider live behavior:** fixture/contract tests do not prove a live DeepSeek multimodal/structured request path.
- **Performance:** Gate 11/13 p50/p95 results are pending in #399281. Historical recompute now offloads fingerprinting/accounting from Sendable inputs; ordinary synchronous projection transactions remain on their context actor. Today initial render and end-to-end render/refresh targets are not yet measured.
- **Pull request:** none is associated with this branch; PR #14 is a separate V3 work line.

## Final status

**NOT READY** at code baseline `6c1b9dde73e551174de0fe27dbbe1177eda10161`. Gate 3 passed on older SHA `70b248a`; Gate 1 failed on that same SHA. Current-baseline full CI and performance measurements are pending in #399281; field/device acceptance evidence is missing. Update this report after run #39928118439 completes; do not convert pending or missing evidence to `PASS`.
