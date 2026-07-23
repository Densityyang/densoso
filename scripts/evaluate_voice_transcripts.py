#!/usr/bin/env python3
"""Score transcript and slot predictions against the PR-H golden set.

Predictions are JSONL with `actualText`, `actualKind`, and `actualSlots`.
The evaluator intentionally reports slot accuracy separately from transcript WER.
"""

import argparse
import json
from pathlib import Path


def word_error_rate(expected: str, actual: str) -> float:
    # Chinese evaluation commonly begins with character tokens when no segmenter
    # is present; callers may replace this tokenizer in a benchmark adapter.
    source, target = list(expected), list(actual)
    previous = list(range(len(target) + 1))
    for i, char in enumerate(source, 1):
        current = [i]
        for j, candidate in enumerate(target, 1):
            current.append(min(current[-1] + 1, previous[j] + 1, previous[j - 1] + (char != candidate)))
        previous = current
    return previous[-1] / max(1, len(source))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--goldens", type=Path, required=True)
    parser.add_argument("--predictions", type=Path, required=True)
    args = parser.parse_args()
    goldens = [json.loads(line) for line in args.goldens.read_text(encoding="utf-8").splitlines() if line]
    predictions = [json.loads(line) for line in args.predictions.read_text(encoding="utf-8").splitlines() if line]
    if len(goldens) != len(predictions):
        raise SystemExit("prediction count must equal golden count")

    total_slots = matched_slots = matched_kinds = 0
    wers = []
    for golden, prediction in zip(goldens, predictions):
        matched_kinds += golden["expectedKind"] == prediction["actualKind"]
        actual_slots = prediction.get("actualSlots", {})
        for key, value in golden["slots"].items():
            total_slots += 1
            matched_slots += actual_slots.get(key) == value
        wers.append(word_error_rate(golden["text"], prediction["actualText"]))

    report = {
        "samples": len(goldens),
        "intentAccuracy": matched_kinds / len(goldens),
        "slotAccuracy": matched_slots / max(1, total_slots),
        "transcriptWER": sum(wers) / len(wers),
    }
    print(json.dumps(report, ensure_ascii=False, sort_keys=True))


if __name__ == "__main__":
    main()
