#!/usr/bin/env python3
"""Normalize the pinned Taiwan FDA food-composition archive into seed_foods.json.

The upstream JSON is a large array of nutrient-analysis rows, with one record per
food/nutrient pair. This importer groups those rows into the normalized format
consumed by import_food_db.py while preserving source values and provenance.
"""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import re
import sys
import unicodedata
import zipfile
from collections import Counter, defaultdict
from decimal import Decimal, InvalidOperation, ROUND_HALF_UP
from importlib.metadata import PackageNotFoundError, version
from pathlib import Path
from typing import Any, TextIO


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_ARCHIVE = ROOT / "FoodDataSources" / "taiwan-fda-nutrition-2026-10-05.zip"
DEFAULT_SEED = ROOT / "Densoso" / "Resources" / "seed_foods.json"
DEFAULT_MANIFEST = ROOT / "Densoso" / "Resources" / "FoodData" / "sources.json"
DEFAULT_REPORT = ROOT / "Densoso" / "Resources" / "FoodData" / "taiwan_food_import_report.json"
DEFAULT_ALIAS_REVIEW = ROOT / "Densoso" / "Resources" / "FoodData" / "taiwan_food_alias_review.json"

SOURCE_ID = "taiwan-fda-nutrition-information"
SOURCE_VERSION = "2026-10-05"
ARCHIVE_SHA256 = "755d2f0e4a7c1fe80ac0636863117e376773c9342cfd68e7b05e67d81e3c6064"
ARCHIVE_MEMBER = "20_5.json"
SOURCE_DATA_TYPE = "Taiwan FDA Nutrition Information Database"
OPENCC_PACKAGE = "opencc-python-reimplemented"
OPENCC_VERSION = "0.1.7"
OPENCC_WHEEL_SHA256 = "41b3b92943c7bed291f448e9c7fad4b577c8c2eae30fcfe5a74edf8818493aa6"

try:
    from opencc import OpenCC
except ImportError as error:
    raise SystemExit(
        "Taiwan FDA importer requires the pinned OpenCC package; install "
        "requirements-food-import.txt before running this script"
    ) from error

try:
    INSTALLED_OPENCC_VERSION = version(OPENCC_PACKAGE)
except PackageNotFoundError as error:
    raise SystemExit(
        "Taiwan FDA importer cannot identify OpenCC; install the pinned package "
        "from requirements-food-import.txt"
    ) from error
if INSTALLED_OPENCC_VERSION != OPENCC_VERSION:
    raise SystemExit(
        f"Taiwan FDA importer requires {OPENCC_PACKAGE}=={OPENCC_VERSION}, "
        f"found {INSTALLED_OPENCC_VERSION}"
    )

SIMPLIFIED_CONVERTER = OpenCC("t2s")

NUTRIENT_ITEMS: dict[str, tuple[str, ...]] = {
    "energyKcal": ("熱量",),
    "proteinG": ("粗蛋白", "粗蛋白質"),
    "fatG": ("粗脂肪",),
    "carbohydrateG": ("總碳水化合物", "碳水化合物"),
    "fiberG": ("膳食纖維",),
}
EXPECTED_UNITS = {
    "energyKcal": {"kcal"},
    "proteinG": {"g"},
    "fatG": {"g"},
    "carbohydrateG": {"g"},
    "fiberG": {"g"},
}
ENERGY_NAME = "熱量"


class ImportFailure(Exception):
    """Raised for a malformed or unpinned upstream data source."""


def read_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ImportFailure(f"unable to read JSON {path}: {error}") from error


def normalize_alias(value: str) -> str:
    normalized = unicodedata.normalize("NFKC", value).casefold()
    return "".join(character for character in normalized if character.isalnum())


def verify_archive(path: Path, manifest_path: Path) -> dict[str, Any]:
    try:
        with path.open("rb") as archive_file:
            digest_value = hashlib.sha256()
            for chunk in iter(lambda: archive_file.read(1_048_576), b""):
                digest_value.update(chunk)
            digest = digest_value.hexdigest()
    except OSError as error:
        raise ImportFailure(f"unable to read upstream archive {path}: {error}") from error
    if digest != ARCHIVE_SHA256:
        raise ImportFailure(
            f"archive SHA-256 mismatch: expected {ARCHIVE_SHA256}, got {digest}"
        )
    manifest = read_json(manifest_path)
    sources = manifest.get("sources") if isinstance(manifest, dict) else None
    source = next(
        (item for item in sources or [] if isinstance(item, dict) and item.get("sourceID") == SOURCE_ID),
        None,
    )
    if source is None:
        raise ImportFailure(f"food manifest is missing source {SOURCE_ID!r}")
    if (
        source.get("sourceVersion") != SOURCE_VERSION
        or source.get("archiveSHA256") != ARCHIVE_SHA256
        or source.get("archivePath") != "FoodDataSources/taiwan-fda-nutrition-2026-10-05.zip"
        or source.get("dataType") != SOURCE_DATA_TYPE
        or source.get("verificationStatus") != "verified"
        or source.get("redistributionAllowed") is not True
        or source.get("licenseSPDX") != "OGDL-Taiwan-1.0"
    ):
        raise ImportFailure("Taiwan FDA source manifest entry does not match the pinned archive/license")
    return source


def iter_json_array(stream: TextIO):
    """Incrementally decode a JSON array without loading the 130 MB file at once."""
    decoder = json.JSONDecoder()
    buffer = ""
    position = 0
    started = False
    finished = False
    eof = False

    def read_more() -> None:
        nonlocal buffer, position, eof
        if position:
            buffer = buffer[position:]
            position = 0
        chunk = stream.read(1_048_576)
        if chunk:
            buffer += chunk
        else:
            eof = True

    while not finished:
        while position < len(buffer) and buffer[position].isspace():
            position += 1

        if not started:
            if position >= len(buffer):
                if eof:
                    raise ImportFailure("upstream JSON is empty")
                read_more()
                continue
            if buffer[position] != "[":
                raise ImportFailure("upstream JSON root must be an array")
            started = True
            position += 1

        while True:
            while position < len(buffer) and (buffer[position].isspace() or buffer[position] == ","):
                position += 1
            if position < len(buffer) and buffer[position] == "]":
                position += 1
                finished = True
                break
            if position >= len(buffer):
                if eof:
                    raise ImportFailure("upstream JSON array ended unexpectedly")
                read_more()
                break
            try:
                value, end = decoder.raw_decode(buffer, position)
            except json.JSONDecodeError:
                if eof:
                    raise ImportFailure("upstream JSON contains an incomplete or invalid value")
                read_more()
                continue
            position = end
            yield value
            if position > 8_388_608:
                buffer = buffer[position:]
                position = 0

        if eof and not finished:
            raise ImportFailure("upstream JSON array is missing its closing bracket")

    if buffer[position:].strip():
        raise ImportFailure("upstream JSON has trailing data after its array")
    while True:
        trailing = stream.read(1_048_576)
        if not trailing:
            break
        if trailing.strip():
            raise ImportFailure("upstream JSON has trailing data after its array")


def parse_number(raw: Any) -> Decimal | None:
    if raw is None or isinstance(raw, bool):
        return None
    text = str(raw).strip()
    if not text or text.casefold() in {"tr", "trace", "—", "–", "-", "n/a", "na", "null"}:
        return None
    try:
        value = Decimal(text)
    except InvalidOperation:
        return None
    if not value.is_finite():
        return None
    return value


def preparation_from_description(description: str) -> tuple[str, str | None]:
    match = re.search(r"樣品狀態\s*[:：]\s*([^\s;；,，]+)", description)
    if match is None:
        return "unknown", None
    state = match.group(1).strip()
    if state in {"生", "生食", "raw"}:
        return "raw", state
    if state in {"熟", "熟食", "cooked"}:
        return "cooked", state
    return "unknown", state


def split_aliases(value: Any) -> list[str]:
    if not isinstance(value, str):
        return []
    # Keep ASCII commas in the alias: Taiwan FDA names often use them inside
    # parenthetical sample notes (for example, year and source market).
    parts = re.split(r"[|，、;；]+", value)
    return [part.strip() for part in parts if part.strip()]


def parse_archive(path: Path) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    grouped: dict[str, dict[str, Any]] = {}
    counts: Counter[str] = Counter()
    nutrient_names: Counter[str] = Counter()
    invalid_rows: list[dict[str, str]] = []

    try:
        with zipfile.ZipFile(path) as archive:
            try:
                entry = archive.getinfo(ARCHIVE_MEMBER)
            except KeyError as error:
                raise ImportFailure(f"archive is missing {ARCHIVE_MEMBER!r}") from error
            with archive.open(entry) as binary, io.TextIOWrapper(binary, encoding="utf-8-sig") as stream:
                for row_number, row in enumerate(iter_json_array(stream), start=1):
                    counts["sourceRows"] += 1
                    if not isinstance(row, dict):
                        counts["nonObjectRows"] += 1
                        continue
                    if row.get("資料類別") != "樣品基本資料":
                        counts["otherDataCategoryRows"] += 1
                        continue
                    record_id = str(row.get("整合編號") or "").strip()
                    name = str(row.get("樣品名稱") or "").strip()
                    if not record_id or not name:
                        counts["missingRecordIDOrNameRows"] += 1
                        invalid_rows.append({"row": str(row_number), "reason": "missing record ID or sample name"})
                        continue
                    food = grouped.setdefault(record_id, {
                        "recordID": record_id,
                        "sourceName": name,
                        "commonName": str(row.get("俗名") or "").strip(),
                        "englishName": str(row.get("樣品英文名稱") or "").strip(),
                        "description": str(row.get("內容物描述") or "").strip(),
                        "sourceCategory": str(row.get("食品分類") or "").strip(),
                        "wasteRateRaw": row.get("廢棄率"),
                        "nutrients": {},
                        "rawNutrientValues": {},
                        "conflicts": [],
                    })
                    incoming_metadata = {
                        "sourceName": name,
                        "commonName": str(row.get("俗名") or "").strip(),
                        "englishName": str(row.get("樣品英文名稱") or "").strip(),
                        "description": str(row.get("內容物描述") or "").strip(),
                        "sourceCategory": str(row.get("食品分類") or "").strip(),
                    }
                    for metadata_key, incoming_value in incoming_metadata.items():
                        existing_value = food.get(metadata_key, "")
                        if existing_value and incoming_value and existing_value != incoming_value:
                            food["conflicts"].append(f"{metadata_key}-conflict")
                        elif not existing_value and incoming_value:
                            food[metadata_key] = incoming_value
                    incoming_waste = row.get("廢棄率")
                    prior_waste = food.get("wasteRateRaw")
                    if parse_number(prior_waste) is not None and parse_number(incoming_waste) is not None:
                        if parse_number(prior_waste) != parse_number(incoming_waste):
                            food["conflicts"].append("wasteRate-conflict")
                    elif prior_waste in (None, "") and incoming_waste not in (None, ""):
                        food["wasteRateRaw"] = incoming_waste
                    analysis = str(row.get("分析項") or "").strip()
                    if not analysis:
                        continue
                    nutrient_names[analysis] += 1
                    field = next((key for key, names in NUTRIENT_ITEMS.items() if analysis in names), None)
                    if field is None:
                        continue
                    unit = str(row.get("含量單位") or "").strip()
                    raw_value = row.get("每100克含量")
                    value = parse_number(raw_value)
                    if value is not None and unit not in EXPECTED_UNITS[field]:
                        food["conflicts"].append(f"{field}-unexpected-unit:{unit}")
                        counts[f"{field}UnexpectedUnit"] += 1
                        continue
                    previous = food["nutrients"].get(field)
                    if field in food["nutrients"] and previous is not None and value is not None and previous != value:
                        food["conflicts"].append(f"{field}-conflicting-values")
                    elif previous is None and value is not None:
                        food["nutrients"][field] = value
                        food["rawNutrientValues"][field] = raw_value
                    else:
                        food["nutrients"].setdefault(field, value)
                        food["rawNutrientValues"].setdefault(field, raw_value)
    except (OSError, zipfile.BadZipFile, UnicodeDecodeError) as error:
        raise ImportFailure(f"unable to parse Taiwan FDA archive: {error}") from error

    counts["sourceFoods"] = len(grouped)
    accepted: list[dict[str, Any]] = []
    excluded: Counter[str] = Counter()
    nulled_nutrients: Counter[str] = Counter()
    for record_id, food in sorted(grouped.items()):
        energy = food["nutrients"].get("energyKcal")
        if energy is None:
            excluded["missing-energy"] += 1
            continue
        if energy < 0 or energy > 1000:
            excluded["energy-out-of-range"] += 1
            continue
        if food["conflicts"]:
            excluded["conflicting-source-record"] += 1
            continue
        waste = parse_number(food["wasteRateRaw"])
        if waste is None or waste < 0 or waste > 100:
            excluded["missing-or-invalid-waste-rate"] += 1
            continue
        if not re.fullmatch(r"[A-Za-z0-9]+", record_id):
            excluded["unmappable-record-id"] += 1
            continue
        stable_id = int(record_id, 36)
        if stable_id <= 0:
            excluded["unmappable-record-id"] += 1
            continue

        prep, state_text = preparation_from_description(food["description"])
        edible = int((Decimal(100) - waste).quantize(Decimal("1"), rounding=ROUND_HALF_UP))
        row = {
            "id": stable_id,
            "name": food["sourceName"],
            "alias": None,
            "preparation": prep,
            "category": food["sourceCategory"] or "台灣 FDA 食品成分",
            "edible": edible,
            "energyKcal": float(energy),
            "proteinG": _validated_macro(food, "proteinG", nulled_nutrients),
            "fatG": _validated_macro(food, "fatG", nulled_nutrients),
            "carbohydrateG": _validated_macro(food, "carbohydrateG", nulled_nutrients),
            "fiberG": _validated_macro(food, "fiberG", nulled_nutrients),
            "sourceID": SOURCE_ID,
            "sourceRecordID": record_id,
            "sourceVersion": SOURCE_VERSION,
            "licenseStatus": "verified",
            "nutrientBasis": "per100g",
            "energyUnit": "kcal/100g",
            "massBasis": {"raw": "edibleRaw", "cooked": "cooked", "unknown": "asPurchased"}[prep],
            "sourceName": food["sourceName"],
            "sourceDataType": SOURCE_DATA_TYPE,
            "sourceRecord": {
                "sourceName": food["sourceName"],
                "foodCategory": food["sourceCategory"],
                "commonName": food["commonName"],
                "sampleEnglishName": food["englishName"],
                "contentsDescription": food["description"],
                "sampleState": state_text,
                "wasteRatePercent": str(food["wasteRateRaw"]).strip(),
                "valuesPer100gEdiblePortion": {
                    key: food["rawNutrientValues"].get(key)
                    for key in NUTRIENT_ITEMS
                },
            },
        }
        accepted.append(row)
        counts[f"preparation-{prep}"] += 1

    counts["acceptedBeforeAliasReview"] = len(accepted)
    return accepted, {
        "sourceRows": counts["sourceRows"],
        "otherDataCategoryRows": counts["otherDataCategoryRows"],
        "sourceFoods": counts["sourceFoods"],
        "acceptedBeforeAliasReview": len(accepted),
        "preparationCounts": {
            key.removeprefix("preparation-"): value
            for key, value in sorted(counts.items())
            if key.startswith("preparation-")
        },
        "excludedRecords": dict(sorted(excluded.items())),
        "nulledNutrientValues": dict(sorted(nulled_nutrients.items())),
        "ignoredRows": {
            key: value for key, value in sorted(counts.items())
            if key not in {"sourceRows", "otherDataCategoryRows", "sourceFoods", "acceptedBeforeAliasReview"}
            and not key.startswith("preparation-")
        },
        "analysisItemsSeen": dict(sorted(nutrient_names.items())),
        "missingNutrientValues": {
            field: sum(row[field] is None for row in accepted)
            for field in ("proteinG", "fatG", "carbohydrateG", "fiberG")
        },
        "ediblePercentageRounding": "100 minus source waste rate, rounded to a whole percentage point with ROUND_HALF_UP; original waste value retained per record",
        "invalidRowSamples": invalid_rows[:100],
    }


def _validated_macro(food: dict[str, Any], field: str, nulled: Counter[str]) -> float | None:
    value = food["nutrients"].get(field)
    if value is None:
        return None
    if value < 0 or value > 150:
        nulled[f"{field}-out-of-range"] += 1
        return None
    return float(value)


def disambiguate_aliases(
    rows: list[dict[str, Any]],
    existing_rows: list[dict[str, Any]],
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    name_owners: dict[str, set[str]] = defaultdict(set)
    alias_owners: dict[str, set[str]] = defaultdict(set)
    existing_name_owners: dict[str, set[str]] = defaultdict(set)
    existing_alias_owners: dict[str, set[str]] = defaultdict(set)
    for existing in existing_rows:
        if existing.get("licenseStatus") != "verified" or not existing.get("sourceRecordID"):
            continue
        owner = f"{existing.get('sourceID')}:{existing.get('sourceRecordID')}"
        existing_name_owners[normalize_alias(str(existing.get("name") or ""))].add(owner)
        for alias in split_aliases(existing.get("alias")):
            existing_alias_owners[normalize_alias(alias)].add(owner)
    candidates_by_id: dict[str, list[str]] = {}
    alias_origins: dict[tuple[str, str], set[str]] = defaultdict(set)
    for row in rows:
        record_id = row["sourceRecordID"]
        name_owners[normalize_alias(row["name"])].add(record_id)
        source_aliases = [
            *split_aliases(row["sourceRecord"]["commonName"]),
            *split_aliases(row["sourceRecord"]["sampleEnglishName"]),
        ]
        candidates: list[tuple[str, str]] = [
            (alias, "source-common-or-english-name") for alias in source_aliases
        ]
        conversion_inputs = [row["sourceName"], *source_aliases]
        for source_alias in dict.fromkeys(conversion_inputs):
            simplified = SIMPLIFIED_CONVERTER.convert(source_alias).strip()
            if simplified and normalize_alias(simplified) != normalize_alias(source_alias):
                candidates.append((simplified, "opencc-t2s"))
        unique: list[str] = []
        for alias, origin in candidates:
            key = normalize_alias(alias)
            if key:
                if alias not in unique:
                    unique.append(alias)
                alias_origins[(record_id, alias)].add(origin)
        candidates_by_id[record_id] = unique
        for alias in unique:
            alias_owners[normalize_alias(alias)].add(record_id)

    review: list[dict[str, Any]] = []
    by_id = {row["sourceRecordID"]: row for row in rows}
    assigned_canonical_keys = set(existing_name_owners) | set(existing_alias_owners)
    for record_id, candidates in candidates_by_id.items():
        row = by_id[record_id]
        kept: list[str] = []
        kept_simplified: list[str] = []
        for alias in candidates:
            key = normalize_alias(alias)
            owners = alias_owners[key]
            name_matches = name_owners.get(key, set())
            external_owners = existing_name_owners.get(key, set()) | existing_alias_owners.get(key, set())
            if len(owners) > 1 or (name_matches and name_matches != {record_id}) or external_owners:
                review.append({
                    "sourceRecordID": record_id,
                    "sourceName": row["sourceName"],
                    "alias": alias,
                    "aliasOrigins": sorted(alias_origins.get((record_id, alias), set())),
                    "reason": "alias maps to multiple source records or conflicts with a canonical name",
                    "conflictingSourceRecordIDs": sorted(owners | name_matches | external_owners),
                })
            elif key != normalize_alias(row["name"]):
                kept.append(alias)
                if "opencc-t2s" in alias_origins.get((record_id, alias), set()):
                    kept_simplified.append(alias)
        # Duplicate canonical sample names are not silently searchable by an ambiguous name.
        canonical_key = normalize_alias(row["name"])
        canonical_external_conflicts = (
            existing_name_owners.get(canonical_key, set())
            | existing_alias_owners.get(canonical_key, set())
        )
        needs_disambiguation = (
            len(name_owners[canonical_key]) > 1
            or bool(canonical_external_conflicts)
            or canonical_key in assigned_canonical_keys
        )
        if needs_disambiguation:
            review.append({
                "sourceRecordID": record_id,
                "sourceName": row["sourceName"],
                "alias": row["sourceName"],
                "aliasOrigins": ["source-canonical-name"],
                "reason": "canonical sample name is shared by multiple source records",
                "conflictingSourceRecordIDs": sorted(name_owners[canonical_key] | canonical_external_conflicts),
            })
            suffix = row["preparation"] if row["preparation"] != "unknown" else row["category"]
            proposed = f"{row['sourceName']}（{suffix}）"
            proposed_key = normalize_alias(proposed)
            if (
                proposed_key in name_owners
                or proposed_key in existing_name_owners
                or proposed_key in existing_alias_owners
                or proposed_key in assigned_canonical_keys
            ):
                proposed = f"{row['sourceName']}（{row['sourceRecordID']}）"
                proposed_key = normalize_alias(proposed)
            if proposed_key in assigned_canonical_keys:
                proposed = f"{row['sourceName']}（{row['sourceRecordID']}，{row['id']}）"
                proposed_key = normalize_alias(proposed)
            row["name"] = proposed
            row["sourceRecord"]["canonicalNameDisambiguation"] = proposed
            assigned_canonical_keys.add(proposed_key)
        else:
            assigned_canonical_keys.add(canonical_key)
        row["alias"] = "|".join(kept) if kept else None
        row["simplifiedAliases"] = kept_simplified
    return rows, review


def merge_seed(existing_items: list[dict[str, Any]], generated_rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    retained = [row for row in existing_items if row.get("sourceID") != SOURCE_ID]
    existing_ids = {row.get("id") for row in retained}
    existing_keys = {
        (row.get("sourceID"), row.get("sourceRecordID"))
        for row in retained
        if row.get("sourceRecordID") is not None
    }
    for row in generated_rows:
        key = (row["sourceID"], row["sourceRecordID"])
        if row["id"] in existing_ids:
            raise ImportFailure(f"generated food ID {row['id']} collides with an existing seed row")
        if key in existing_keys:
            raise ImportFailure(f"source record {key!r} already exists in the seed")
    merged = sorted([*retained, *generated_rows], key=lambda row: row["id"])
    alias_owners: dict[str, set[int]] = defaultdict(set)
    for row in merged:
        if row.get("licenseStatus") != "verified":
            continue
        for alias in [str(row.get("name") or ""), *split_aliases(row.get("alias"))]:
            key = normalize_alias(alias)
            if key:
                alias_owners[key].add(row["id"])
    collisions = {key: sorted(ids) for key, ids in alias_owners.items() if len(ids) > 1}
    if collisions:
        raise ImportFailure(f"production food aliases remain ambiguous: {sorted(collisions.items())[:10]}")
    return merged


def render_json(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, indent=2, sort_keys=False) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=Path, default=DEFAULT_ARCHIVE)
    parser.add_argument("--seed", type=Path, default=DEFAULT_SEED)
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--report", type=Path, default=DEFAULT_REPORT)
    parser.add_argument("--alias-review", type=Path, default=DEFAULT_ALIAS_REVIEW)
    parser.add_argument("--check", action="store_true", help="verify generated rows match the checked-in seed")
    args = parser.parse_args()

    try:
        source = verify_archive(args.archive, args.manifest)
        generated_rows, report = parse_archive(args.archive)
        existing_items = read_json(args.seed)
        if not isinstance(existing_items, list):
            raise ImportFailure("seed must be a JSON array")
        retained_items = [row for row in existing_items if row.get("sourceID") != SOURCE_ID]
        generated_rows, alias_review = disambiguate_aliases(generated_rows, retained_items)
        merged_items = merge_seed(existing_items, generated_rows)
        report["aliasReview"] = {
            "ambiguousAliasCount": len(alias_review),
            "reviewFile": str(args.alias_review.relative_to(ROOT)).replace("\\", "/"),
        }
        report["source"] = {
            "sourceID": SOURCE_ID,
            "sourceVersion": SOURCE_VERSION,
            "sourceURL": source["sourceURL"],
            "archiveSHA256": ARCHIVE_SHA256,
            "archiveMember": ARCHIVE_MEMBER,
            "licenseSPDX": source["licenseSPDX"],
            "licenseURL": source["licenseURL"],
            "nutrientBasis": "per100g edible portion",
            "wasteRateTreatment": "retained as edible percentage; applied only for as-purchased portions",
        }
        report["aliasConversion"] = {
            "tool": OPENCC_PACKAGE,
            "version": OPENCC_VERSION,
            "config": "t2s",
            "wheelSHA256": OPENCC_WHEEL_SHA256,
            "canonicalNamesRemainTraditional": True,
            "ambiguousConversions": "reviewed and omitted from searchable aliases",
            "simplifiedAliasesAttached": sum(len(row["simplifiedAliases"]) for row in generated_rows),
            "ambiguousSimplifiedAliasesReviewed": sum(
                "opencc-t2s" in entry.get("aliasOrigins", []) for entry in alias_review
            ),
        }
        report["recordCount"] = len(generated_rows)
        report["seedRecordCount"] = len(merged_items)
        if args.check:
            actual_rows = read_json(args.seed)
            actual_source_rows = [row for row in actual_rows if row.get("sourceID") == SOURCE_ID]
            if actual_source_rows != generated_rows:
                raise ImportFailure(
                    f"checked-in seed has {len(actual_source_rows)} Taiwan FDA rows; pinned archive regenerates {len(generated_rows)}"
                )
            if args.report.exists() and read_json(args.report) != report:
                raise ImportFailure("checked-in Taiwan FDA import report differs from the pinned archive")
            if args.alias_review.exists() and read_json(args.alias_review) != alias_review:
                raise ImportFailure("checked-in Taiwan FDA alias review differs from the pinned archive")
            print(f"Taiwan FDA archive reproducibility: {len(generated_rows)} normalized records match.")
            return 0

        args.seed.write_text(render_json(merged_items), encoding="utf-8")
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(render_json(report), encoding="utf-8")
        args.alias_review.parent.mkdir(parents=True, exist_ok=True)
        args.alias_review.write_text(render_json(alias_review), encoding="utf-8")
        print(
            f"Taiwan FDA import: {len(generated_rows)} records from {report['source']['sourceVersion']}; "
            f"{len(alias_review)} ambiguous alias entries written to {args.alias_review}"
        )
    except (ImportFailure, OSError, KeyError, TypeError, ValueError) as error:
        print(f"Taiwan FDA import rejected: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
