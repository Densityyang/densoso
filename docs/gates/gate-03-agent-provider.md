# Gate 03 — Agent and Provider

Status: approved by user on 2026-09-02

Gate 3 extends the same V3 core Draft PR. It runs only after foundation and
domain-persistence pass on the same head, and does not authorize Speech work.

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
- Persist provider-neutral conversations, real tool counts, consent and usage.
- Expose an ordered `AsyncThrowingStream<AgentEvent>` for each request, including
  a typed cancellation event; the legacy final-response API remains available.
- Add soft monthly budget reminders without interrupting an active request.
  Estimates use a versioned 2026-09-01 conservative table: DeepSeek V4 Flash
  peak/cache-miss rates and Qwen Beijing standard non-cached <=128k rates. Qwen
  request bodies are capped at 120 KB to stay inside that pricing tier; these
  values are estimates, not invoice totals.
- Render restricted Markdown through typed `AssistantBlock` values with HTML,
  remote images and non-HTTPS links removed or rejected.
- Ensure Provider logs contain metadata only, never keys, authorization headers,
  complete health text, reasoning or transcripts.
  Production currently records no Provider diagnostics (`NoOpProviderLogSink`);
  any injected diagnostic sink receives only allowlisted, redacted metadata.

Pricing and capability baselines are versioned from the official
[DeepSeek pricing](https://api-docs.deepseek.com/quick_start/pricing/) and
[Qwen Flash capability/pricing](https://help.aliyun.com/en/model-studio/qwen-flash)
pages as checked on 2026-09-01.

## Non-goals

- No SpeechAnalyzer/legacy audio-session repair or Qwen ASR invocation.
- No camera, OCR, image upload, Qwen VL, portion estimation or meal-capture work.
- No HealthKit worker, background delivery or authorization expansion.
- No health intelligence, WatchConnectivity, WorkoutKit or final four-tab UI.
- No live Provider calls in CI and no changes to protected OCR sources.

## Gate contract

The `agent-provider` job has `needs: domain-persistence` and must prove:

1. DeepSeek and Qwen request/response/tool/usage fixture contracts;
2. 401/403 no retry, bounded 429/network/5xx retry, timeout and cancellation;
3. malformed Provider responses become typed, redacted errors;
4. every tool uses a closed local schema and `log_meal.dishes` is an array;
5. five rounds, eight tools and one 45-second deadline are hard limits;
6. every executable prompt-injection eval case—including injected tool output—
   produces only staged actions and zero direct health writes;
7. usage deduplicates by request/attempt, persists and applies versioned,
   conservative pricing estimates for soft-budget warnings;
8. Markdown emphasis/list/HTTPS behavior and HTML/image/non-HTTPS/fallback safety;
9. logs contain no credentials, complete health input or transcript; and
10. `.xcresult`, logs, test summary, fixture summary and redaction evidence are retained.

## Evidence record

| Evidence | Required result | Current result |
| --- | --- | --- |
| PR head | Phase 3 implementation on Draft PR #14 | `b5766cc70c247f980f9c5c7bb59f3c5b3dc9de26` (`fix: preserve provider cancellation contracts`) |
| CI run | Same head completes the cumulative chain | [Run 33577727374](https://github.com/Densityyang/densoso/actions/runs/33577727374) — success |
| Foundation | gate-01-foundation succeeds | [Job 100085250453](https://github.com/Densityyang/densoso/actions/runs/33577727374/job/100085250453) — success |
| Dependencies | foundation and domain-persistence succeed | [Job 100090437216](https://github.com/Densityyang/densoso/actions/runs/33577727374/job/100090437216) — success |
| Provider contracts | DeepSeek/Qwen fixtures pass | [Job 100092358853](https://github.com/Densityyang/densoso/actions/runs/33577727374/job/100092358853) — success |
| Agent governance | 5/8/45, consent and injection tests pass | Gate3 selected tests — success |
| Tool schemas | Closed schemas and typed meal arrays pass | Gate3 selected tests — success |
| Usage/privacy | Ledger, budget and redaction tests pass | Gate3 selected tests — success |
| Markdown | Restricted renderer tests pass | Gate3 selected tests — success |
| Fixture packaging | Prompt-injection fixture is in the test bundle | `CpResource .../prompt-injection-phase3.yaml .../DensosoTests.xctest` observed in Gate3 build log |
| Artifact | `.xcresult`, logs and JSON summaries retained | `gate-03-agent-provider-results` — artifact ID `9828254631` |
| Signing | Simulator evidence only | `blocked-by-signing` |
| User decision | Approve or reject entry to Phase 4 | Approved 2026-09-02 |
