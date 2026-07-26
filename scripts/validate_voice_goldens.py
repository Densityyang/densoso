#!/usr/bin/env python3
"""Validate PR-H's deterministic Chinese voice-routing golden set."""

import argparse
import json
from collections import Counter
from pathlib import Path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, required=True)
    args = parser.parse_args()
    rows = [json.loads(line) for line in args.input.read_text(encoding="utf-8").splitlines() if line]
    kinds = Counter(row["expectedKind"] for row in rows)
    assert len(rows) >= 300, "requires at least 300 spoken Chinese examples"
    assert all(kinds[kind] > 0 for kind in ("mealDraft", "strengthSetDraft", "workoutPlanDraft", "readOnlyQuery"))
    text = "\n".join(row["text"] for row in rows)
    for required in ("公斤", "毫升", "一百", "×", "没吃", "补", "明天", "鸡凶肉"):
        assert required in text, f"missing coverage term: {required}"
    print(f"Validated {len(rows)} rows: {dict(sorted(kinds.items()))}")


if __name__ == "__main__":
    main()
