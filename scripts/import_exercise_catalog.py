#!/usr/bin/env python3
"""Create Densoso's versioned, offline exercise catalog from free-exercise-db.

The generated catalog intentionally stores only searchable exercise metadata, not
the upstream images. Run this with a pinned source revision in release builds.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
from pathlib import Path


SOURCE_URL = "https://github.com/yuhonas/free-exercise-db"
LICENSE_URL = "https://github.com/yuhonas/free-exercise-db/blob/main/LICENSE.md"

# Curated product aliases. Entries without an alias remain searchable by their
# upstream English name; translators can extend this map without changing IDs.
CHINESE_ALIASES = {
    "Barbell_Squat": ["深蹲", "杠铃深蹲"],
    "Barbell_Deadlift": ["硬拉", "杠铃硬拉"],
    "Barbell_Bench_Press_-_Medium_Grip": ["卧推", "杠铃卧推"],
    "Pullups": ["引体向上"],
    "Pushups": ["俯卧撑"],
    "Dumbbell_Bicep_Curl": ["哑铃弯举"],
}


def normalized_list(value: object) -> list[str]:
    if not isinstance(value, list):
        return []
    return sorted({item.strip() for item in value if isinstance(item, str) and item.strip()})


def catalog_entry(item: dict[str, object]) -> dict[str, object]:
    source_id = str(item["id"])
    return {
        "id": f"free-exercise-db:{source_id}",
        "sourceID": source_id,
        "name": str(item.get("name") or source_id.replace("_", " ")),
        "aliases": CHINESE_ALIASES.get(source_id, []),
        "category": str(item.get("category") or "other"),
        "equipment": item.get("equipment") if isinstance(item.get("equipment"), str) else None,
        "primaryMuscles": normalized_list(item.get("primaryMuscles")),
        "secondaryMuscles": normalized_list(item.get("secondaryMuscles")),
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--license-output", required=True, type=Path)
    parser.add_argument("--source-revision", required=True)
    parser.add_argument("--input-is-base64", action="store_true")
    args = parser.parse_args()

    raw = args.input.read_bytes()
    if args.input_is_base64:
        raw = base64.b64decode(raw)
    source_checksum = hashlib.sha256(raw).hexdigest()
    decoded = json.loads(raw)
    if not isinstance(decoded, list):
        raise SystemExit("Expected the upstream combined exercises.json array")

    entries = sorted(
        (catalog_entry(item) for item in decoded if isinstance(item, dict) and item.get("id")),
        key=lambda item: str(item["id"]),
    )
    equipment = sorted({item["equipment"] for item in entries if item["equipment"]})
    muscles = sorted({muscle for item in entries for muscle in item["primaryMuscles"] + item["secondaryMuscles"]})

    catalog = {
        "schemaVersion": 1,
        "catalogVersion": f"free-exercise-db-{args.source_revision[:12]}",
        "source": {
            "repository": SOURCE_URL,
            "revision": args.source_revision,
            "inputSHA256": source_checksum,
            "license": "Unlicense",
        },
        "entries": entries,
        "indexes": {"equipment": equipment, "muscles": muscles},
    }
    license_manifest = {
        "catalogVersion": catalog["catalogVersion"],
        "thirdParty": [{
            "name": "free-exercise-db",
            "repository": SOURCE_URL,
            "revision": args.source_revision,
            "license": "Unlicense",
            "licenseURL": LICENSE_URL,
            "inputSHA256": source_checksum,
            "attributionRequired": False,
        }],
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.license_output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(catalog, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    args.license_output.write_text(json.dumps(license_manifest, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    print(f"Generated {len(entries)} exercises: {args.output}")


if __name__ == "__main__":
    main()
