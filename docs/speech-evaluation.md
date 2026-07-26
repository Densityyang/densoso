# Speech evaluation baseline

PR-E uses synthetic Chinese meal and workout utterances only. No microphone audio,
real health records, or cloud requests are stored by the evaluator.

`SpeechGoldenSet.zhCNV1` contains 300 versioned reference utterances: 150 meals
and 150 workouts. It covers food and brand names, serving words, grams/kilograms/
milliliters, Chinese numbers, exercise sets/repetitions/weight, time, and the
safe "do not save" phrasing. The set stores only expected text and slots. A
physical-device run supplies the observed transcript, typed draft slots, device,
OS build, locale, speech backend, and end-to-end latency before passing them to
`SpeechBenchmarkEvaluator`.

`SpeechBenchmarkEvaluator` reports three metrics for a supplied transcript and
typed-slot result:

- **Transcript error rate**: Levenshtein distance divided by reference tokens.
  Han characters are individual tokens; contiguous Latin letters and digits are
  one token. Whitespace and punctuation do not affect the score.
- **Slot accuracy**: exact normalized match over expected domain slots such as
  `food`, `grams`, `exercise`, `sets`, `reps`, and `weight`.
- **Latency**: caller-supplied end-to-end milliseconds, summarized as median and
  p95. The evaluator never measures or retains raw audio.

Before enabling a new Speech model, locale, or OS release by default, run the
versioned golden set on a physical iPhone and record the aggregate metrics,
device, OS build, locale, and model asset version in the PR. CI validates metric
calculation and golden-set coverage only; it cannot validate microphone
permission, downloaded language assets, or physical-device latency.
