# Gate 03 — Agent and Provider

Status: Gate 3 contract for the `codex/ai-native-health-loop` main coding line.
The earlier 2026-09-02 phase approval is historical and is not a current PR or
phase-advance decision.

This file records Gate 3 scope and evidence. The current branch has no associated
PR; older V3 PR evidence below has been replaced with the current run state.

## Scope

- Introduce provider-neutral messages, tool calls, usage and events.
- Keep DeepSeek as the complete default text path.
- Add explicitly selected Qwen text support with separate Model Studio
  credential and workspace configuration. Phase 3 fixes qwen-flash to Beijing,
  the supported Function Calling region; a legacy Singapore choice is migrated
  locally before any network request.
- Declare future Qwen vision/speech capabilities without sending image or audio
  in this phase.
- Enforce unified Provider errors, at most two retries for network/5xx, optional
  `Retry-After`, cancellation propagation and one 45-second Agent deadline.
- Enforce five Provider rounds and eight actually executed tool calls.
- Replace stringified meal JSON with closed nested object/array schemas and local
  validation; add `create_workout_plan` as a staged action.
- Stage daily check-ins only when the proposed energy, stress, subjective sleep,
  note and date are supported by the current user's own words; missing or
  conflicting subjective fields must be clarified and never inferred from
  HealthKit.
- Persist provider-neutral conversations, real tool counts, consent and usage.
- Keep full local chat history for user-visible audit while sending only the
  last eight complete turns plus the active request, capped at 64 messages and
  a conservative 96 KiB input estimate. The active turn keeps intact tool-call
  and result pairs; an oversized active turn is rejected before another provider
  call.
- Preserve provider reasoning only in the active request's in-memory
  continuation. Persisted and post-request histories remove reasoning and image
  payloads, while the same request can still complete its required continuation.
- Resolve consent and usage idempotency by exact keys; aggregate usage only for
  the requested provider and half-open month window `[start, end)`. Focused
  repository tests cover key de-duplication, month boundaries and unknown-price
  preservation. Monthly token, audio and cost summaries stream through stable
  64-row keyset pages; a cross-page currency fixture preserves the existing
  unknown/mixed-currency result rules.
- Scope the Agent's daily-metrics read to the requested inclusive date range in
  SwiftData with stable 64-row date pages and return rows in ascending date
  order; focused tests cover both range boundaries, ordering, cross-page rows
  and an inverted-range empty result.
- Read the Agent's requested-day schedule through the bounded repository query,
  including active historical training-plan sessions across stable 64-row
  pages.
- Load confirmed workout and training-plan entries for the DailyLoop/Watch
  snapshot through `HealthProjectionActor`; retain only eligible today/tomorrow
  sessions after paging persisted plan metadata in batches of 64.
- Read visible and resumable conversation messages in stable 64-row ordinal
  pages while preserving message order and the current-request resume filter.
- Reset conversation messages and Agent request history in stable 64-row pages
  inside the existing single-save boundary, preserving records from other
  conversations.
- Read confirmed user-reported preferences newest-first in stable 64-row
  keyset pages, retaining only the requested top-K results while preserving the
  existing ID tie-break at the cutoff timestamp; the focused fixture covers
  invalid rows and valid ties across the page boundary.
- Expose an ordered `AsyncThrowingStream<AgentEvent>` for each request, including
  a typed cancellation event; the legacy final-response API remains available.
- Normalize local and cloud turns as `AgentTurnResult` with a typed
  `AgentIntent`. Local capture detection is a proposal only: it preserves the
  editable user text and never fabricates a `PendingAction`; only cloud tools
  stage typed `ActionPayload` values in the shared AgentSession confirmation
  queue. A completed workout cannot be classified as a future workout plan.
  Health-question and history-query intent cases remain reserved until the
  session exposes structured read-intent metadata; free-form reply wording is
  not used to infer them.
- Add soft monthly budget reminders without interrupting an active request.
  Each Agent request also has a hard per-request cost cap in the V9
  `AgentRequestCostBudgetRecord`. Before a provider call, the Agent reserves a
  conservative cost estimate from the bounded input upper bound, maximum output
  and transport retry limit. The request ID, provider/model/currency/rate version,
  cap, cumulative reservation and round are durable; resume cannot replace them
  with a larger factory budget. The default cap is 1,000,000 micros in the
  selected descriptor's currency. A legacy in-flight request that has prior rounds
  but no recoverable cost reservations is terminated before another provider
  call. Unknown pricing remains unavailable and does not fail an otherwise
  bounded provider request; a provider/model mismatch fails closed. Reservations
  are estimates, not invoice totals.
  Estimates resolve through a versioned `PricingDescriptor` matched by exact
  provider, model and capability tuple. DeepSeek uses the model ID and Responses
  endpoint from `ProviderCapabilityCatalog`; its fake-transport contract tests
  assert the actual request URL and model. DeepSeek Flash uses the official
  2026-09-10 peak-rate schedule checked on 2026-10-23. Qwen Flash uses the
  Beijing standard non-cached <=128k tier checked on 2026-10-23, with cached
  input conservatively priced at the non-cached rate. Qwen request bodies are
  capped at 120 KB to stay inside that tier.
  Models or usage units without a verified descriptor (including current Qwen
  ASR and vision) retain unknown cost instead of falling back to another model's
  price. These estimates are not invoice totals.
- Render restricted Markdown through typed `AssistantBlock` values with HTML,
  remote images and non-HTTPS links removed or rejected.
- Ensure Provider logs contain metadata only, never keys, authorization headers,
  complete health text, reasoning or transcripts.
  Production currently records no Provider diagnostics (`NoOpProviderLogSink`);
  any injected diagnostic sink receives only allowlisted, redacted metadata.

Pricing and capability baselines are versioned from the official
[DeepSeek pricing](https://api-docs.deepseek.com/quick_start/pricing/) and
[Qwen Flash capability/pricing](https://help.aliyun.com/en/model-studio/qwen-flash)
pages as checked on 2026-10-23.

## Non-goals

- No SpeechAnalyzer/legacy audio-session repair or Qwen ASR invocation.
- No camera, OCR, image upload, Qwen VL, portion estimation or meal-capture work.
- No HealthKit worker, background delivery or authorization expansion.
- No health intelligence, WatchConnectivity, WorkoutKit or final four-tab UI.
- No live Provider calls in CI and no changes to protected OCR sources.

## Gate contract

Daily-check-in tool arguments are checked against the current user turn before
the confirmation-required tool can create a `PendingAction`. A missing or
contradictory field, a note absent from the user's words, or a check-in about
another person produces a tool error and no pending action. Confirmed check-ins
stay in the local user-reported ledger and do not enter HealthKit projections.
Local turn contract tests verify answer, non-persisting capture proposal, and
cloud-staged action outcomes use the same typed result boundary.

The `agent-provider` job follows `domain-persistence` in the full workflow and
must prove:

1. DeepSeek and Qwen request/response/tool/usage fixture contracts;
2. 401/403 no retry, bounded 429/network/5xx retry, timeout and cancellation;
3. malformed Provider responses become typed, redacted errors;
4. every tool uses a closed local schema and `log_meal.dishes` is an array;
5. five rounds, eight tools and one 45-second deadline are hard limits;
6. every executable prompt-injection eval case—including injected tool output—
   produces only staged actions and zero direct health writes;
7. usage deduplicates by request/attempt, persists descriptor versions and
   applies conservative estimates only for exact provider/model/capability
   matches; missing price inputs remain unknown for soft-budget reporting;
8. Markdown emphasis/list/HTTPS behavior and HTML/image/non-HTTPS/fallback safety;
9. logs contain no credentials, complete health input or transcript; and
10. `.xcresult`, logs, test summary, fixture summary and redaction evidence are retained.

The workflow treats gate dependencies as execution order, not as a reason to
hide independent test evidence: in a full run, later gates still execute after
an earlier gate fails. The aggregate job reports all Gates 1-14 as `PASS`,
`FAIL`, `BLOCKED` or `NOT RUN` and fails if any selected gate is not `PASS`.
Gate artifacts are attempted with `if: always()`; missing files are listed in
the Gate 3 execution summary and produce upload-step warnings elsewhere. A
warning cannot change a failed gate to a successful one.

## Static contract anchors

- Provider identity is declared once in `ProviderCapabilityCatalog`. The
  validator checks that `DeepSeekProvider` uses those defaults and that the
  fake-transport contract tests assert the endpoint, model ID and capability
  behavior. It does not require the URL or model string to be duplicated in the
  provider implementation file.
- Pricing checks cover exact provider/model/capability matching and known
  descriptor entries. XCTest contracts assert that unsupported Qwen speech and
  vision usage keep unknown cost; a comment's exact capitalization is not the
  source of truth.
- DailyLoop plan reads are performed by `HealthProjectionActor` and the Agent's
  requested-day schedule is read by its repository. Gate tests cover historical
  multi-day plans, ordinary schedule filtering, page boundaries and the final
  today/tomorrow snapshot. The validator follows these current call paths rather
  than requiring a direct call to `WorkoutPlanSchedulingService.confirmedPlans()`
  from `DailyLoopSnapshotService`.
- `DailyCheckIn` represents user-reported energy, stress and subjective sleep;
  `DailyCheckInSelfReportResolver` checks proposed values and notes against the
  current user's words before staging. Domain and confirmation tests cover this
  contract; static validation uses the type and test names rather than an exact
  prose phrase in the source comment.

## Evidence record

| Evidence | Required result | Current result before CI repair |
| --- | --- | --- |
| Branch / head | Main coding line and exact SHA | `codex/ai-native-health-loop` at `e7d273ae87cd7eded510c0aed3a003acaeba0e58`; no associated PR |
| Latest full Build CI | Gates 1-14 report their actual result | [Run 39714060743](https://github.com/Densityyang/densoso/actions/runs/39714060743) — failed in Gate 3 static validation after Gates 1 and 2 passed |
| Gate 3 static validation | Source/config/test contracts match the current implementation | Failed on seven stale path/wording assertions; the run log identifies the validator step as the failure |
| Gate 3 XCTest | Independent provider/agent contracts execute and report results | `NOT RUN`; skipped after the validator step failed |
| Gate 3 artifact | Fixture report, test bundle and logs are available even on failure | Not uploaded; validator did not write its JSON on failure and upload required result files that had not been created |
| IPA build | Unsigned device build result is reported separately | [Build IPA 39716002512](https://github.com/Densityyang/densoso/actions/runs/39716002512) — succeeded; does not establish full test CI or signed-device acceptance |
| Last full Build CI pass | Same SHA as current head | Last known full pass is on `3628d42`, earlier than the current head |
| Device acceptance | Signed iPhone/Watch evidence | Not established by the cited unsigned IPA build |
| Repair acceptance | Repaired validator, continued independent gates, complete aggregate report | Awaiting a future GitHub Actions run; no Actions run was triggered for this edit |
