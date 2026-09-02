# Gate 04 — Speech Capture

Status: implementation candidate; awaiting macOS CI and user review

Gate 4 extends Draft PR #14 after the user approved Gate 3 on 2026-09-02.
It repairs speech capture only and does not authorize Phase 5 meal/photo work.

## Scope

- Split microphone session, frame capture, local transcribers and cloud ASR behind
  injectable contracts.
- Use `record + measurement + []`; activation uses no deactivation-only options.
- Enforce the state chain `idle → requestingPermission → configuringSession →
  preparingBackend → recording → finalizing → completed` with typed failures.
- Stop without silent restart on interruption, route change and media-services reset.
- Use one guarded input tap, a bounded frame stream, 55-second warning and
  60-second automatic stop.
- Route SpeechAnalyzer → legacy Speech → one Qwen ASR request → editable manual
  input. Qwen is eligible only when local transcription failed, audio frames exist,
  and `.speechAudio` consent plus the explicit fallback switch are both enabled.
- Send a protected 16 kHz mono WAV to the independent `qwen3-asr-flash` adapter;
  never send audio through the text/tool provider.
- Delete temporary WAV data after success, failure, cancellation and cold launch.
- Export redacted diagnostics containing stage, route type, format, backend,
  engine state and numeric errors, never keys, audio or transcript text.

## Non-goals

- No camera, PhotosPicker, OCR, barcode, food resolution or portion estimation.
- No Qwen vision and no asynchronous file-transcription model.
- No HealthKit, WatchConnectivity or WorkoutKit expansion.
- No background recording, silent restart or automatic submission to the Agent.
- No claim that Simulator CI proves physical microphone or `OSStatus -50` behavior.

## Gate contract

The `speech` job has `needs: agent-provider` and must prove:

1. every permission/session/route/format/tap/engine failure stage is typed;
2. repeated start/stop installs one tap and cancellation reaches every layer;
3. interruption, route change and media reset stop without silent restart;
4. modern runtime failure can replay captured frames into legacy Speech;
5. Qwen is called once only when local recognition failed and audio exists;
6. a capture that never started or captured no frame never calls cloud ASR;
7. audio consent is separate from health-text consent;
8. the Qwen request uses `input_audio`, `qwen3-asr-flash`, Beijing workspace,
   Base64 WAV and `usage.seconds`;
9. protected WAV and diagnostics are removed or redacted across every terminal path;
10. `.xcresult`, logs, summaries, routing matrix and provisional device matrix are retained.

## Real-device boundary

The required iPhone 17 / iOS 26.6 built-in-microphone 20-cycle run remains
provisional because the local app cannot currently be signed. The checked-in
`gate-04-device-matrix.json` records zero executed cycles and makes no pass claim.
The existing `blocked-by-signing` label must remain until signed evidence shows
zero `OSStatus -50` and zero recording failures.

## Evidence record

| Evidence | Required result | Current result |
| --- | --- | --- |
| PR head | Phase 4 implementation on Draft PR #14 | Pending publish |
| Dependencies | Gates 1–3 succeed on the same head | Pending CI |
| State/session | Failure stages, repeat/cancel/events/tap tests pass | Pending CI |
| Routing | SpeechAnalyzer → legacy → Qwen → manual tests pass | Pending CI |
| Qwen contract | Audio request/response/usage fixtures pass | Pending CI |
| Privacy | WAV cleanup/protection and diagnostics redaction pass | Pending CI |
| Artifact | `.xcresult`, logs and JSON matrices retained | Pending CI |
| Device | 20 physical cycles | Provisional; blocked by signing |
| User decision | Approve or reject entry to Phase 5 | Pending review |
