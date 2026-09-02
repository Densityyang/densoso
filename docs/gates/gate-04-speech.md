# Gate 04 — Speech Capture

Status: awaiting user Gate 4 approval

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
- Xcode 26.6 does not expose the online-documented `AnalyzerInputConverter` symbol;
  the production adapter therefore uses a bounded `AVAudioConverter` compatible
  with the SDK, explicitly drains it before SpeechAnalyzer finalization, and
  treats any conversion/input drop as a failed local path.

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
Simulator tests accept either Complete or CompleteUntilFirstUserAuthentication
because iOS 26 Simulator maps the requested protected class to the latter; the
signed physical-device matrix must still verify the exact Complete class.
The existing `blocked-by-signing` label must remain until signed evidence shows
zero `OSStatus -50` and zero recording failures.

## Evidence record

| Evidence | Required result | Current result |
| --- | --- | --- |
| PR head | Phase 4 implementation on Draft PR #14 | `7f1bc02eb10c32f4f4a168004e1758dc251eada4` |
| Implementation/fix commits | Phase 4 implementation plus SDK/Swift 6/test fixes | `e0cdec46b7ae94d832ce5ad15372195080f83964`, `210f054078ba82f4805c46a02b33bbd3a3bb6cc2`, `c44098cb78d8a497de0e60342ca85f63849a0d9f`, `7f1bc02eb10c32f4f4a168004e1758dc251eada4` |
| Chained CI | Gates 1–4 succeed on the same head | [run 33601854099](https://github.com/Densityyang/densoso/actions/runs/33601854099) — all four jobs passed |
| Gate 1 job | `gate-01-foundation` | [job 100157076743](https://github.com/Densityyang/densoso/actions/runs/33601854099/job/100157076743) — passed |
| Gate 2 job | `gate-02-domain-persistence` | [job 100161955859](https://github.com/Densityyang/densoso/actions/runs/33601854099/job/100161955859) — passed |
| Gate 3 job | `gate-03-agent-provider` | [job 100164733999](https://github.com/Densityyang/densoso/actions/runs/33601854099/job/100164733999) — passed |
| Gate 4 job | `gate-04-speech` | [job 100167613953](https://github.com/Densityyang/densoso/actions/runs/33601854099/job/100167613953) — passed |
| State/session | Failure stages, repeat/cancel/events/tap tests pass | Passed in Gate 4 job |
| Routing | SpeechAnalyzer → legacy → Qwen → manual tests pass | Passed in Gate 4 job |
| Qwen contract | Audio request/response/usage fixtures pass | Passed in Gate 4 job |
| Privacy | WAV cleanup/protection and diagnostics redaction pass | Passed in Gate 4 job; Simulator protection mapping is documented below |
| Artifact | `.xcresult`, logs and JSON matrices retained | `gate-04-speech-results` — artifact ID `9837055363` |
| Device | 20 physical cycles | Provisional; blocked by signing |
| User decision | Approve or reject entry to Phase 5 | Awaiting user Gate 4 approval |
