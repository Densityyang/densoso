#!/usr/bin/env python3
"""Validate packaged food provenance and the pinned recipe-prior catalog.

This Gate 17 check builds temporary development and production SQLite catalogs
with the real importer, inspects the resulting rows, and probes energy rejection
with mutated records. It also validates the on-disk recipe catalog and its
source quantity-evidence counts.
"""

from __future__ import annotations

import json
import hashlib
import re
import sqlite3
import subprocess
import sys
import tempfile
import unicodedata
from collections import Counter
from decimal import Decimal, InvalidOperation, ROUND_HALF_UP
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "scripts"
RESOURCES = ROOT / "Densoso" / "Resources"
FOOD_SEED = RESOURCES / "seed_foods.json"
FOOD_MANIFEST = RESOURCES / "FoodData" / "sources.json"
FOOD_IMPORTER = SCRIPTS / "import_food_db.py"
TAIWAN_IMPORTER = SCRIPTS / "import_taiwan_fda_foods.py"
TAIWAN_ARCHIVE = ROOT / "FoodDataSources" / "taiwan-fda-nutrition-2026-10-05.zip"
TAIWAN_IMPORT_REPORT = RESOURCES / "FoodData" / "taiwan_food_import_report.json"
TAIWAN_ALIAS_REVIEW = RESOURCES / "FoodData" / "taiwan_food_alias_review.json"
TAIWAN_OPENCC_WHEEL = ROOT / "FoodDataSources" / "wheels" / "opencc_python_reimplemented-0.1.7-py2.py3-none-any.whl"
RECIPE_CATALOG = RESOURCES / "FoodData" / "recipe_priors.json"
RECIPE_MANIFEST = RESOURCES / "FoodData" / "recipe_sources.json"
RECIPE_REPORT = RESOURCES / "FoodData" / "recipe_prior_import_report.json"
RECIPE_VALIDATOR = SCRIPTS / "validate_recipe_priors.py"

EXPECTED_TAIWAN_FDA_RECORD_COUNT = 979
EXPECTED_FOOD_PRODUCTION_COUNT = 24 + EXPECTED_TAIWAN_FDA_RECORD_COUNT
TAIWAN_FDA_SOURCE_ID = "taiwan-fda-nutrition-information"
TAIWAN_FDA_SOURCE_VERSION = "2026-10-05"
TAIWAN_FDA_ARCHIVE_SHA256 = "755d2f0e4a7c1fe80ac0636863117e376773c9342cfd68e7b05e67d81e3c6064"
TAIWAN_OPENCC_VERSION = "0.1.7"
TAIWAN_OPENCC_WHEEL_SHA256 = "41b3b92943c7bed291f448e9c7fad4b577c8c2eae30fcfe5a74edf8818493aa6"
EXPECTED_FDC_RECORDS = {
    "169757": ("usda-fdc-sr-legacy", "Rice, white, long-grain, regular, unenriched, cooked without salt"),
    "2512381": ("usda-fdc-foundation-foods", "Rice, white, long grain, unenriched, raw"),
    "2512380": ("usda-fdc-foundation-foods", "Rice, brown, long grain, unenriched, raw"),
    "2646170": ("usda-fdc-foundation-foods", "Chicken, breast, boneless, skinless, raw"),
    "2646169": ("usda-fdc-foundation-foods", "Pork, loin, tenderloin, boneless, raw"),
    "2514743": ("usda-fdc-foundation-foods", "Beef, ground, 90% lean meat / 10% fat, raw"),
    "171287": ("usda-fdc-sr-legacy", "Egg, whole, raw, fresh"),
    "172475": ("usda-fdc-sr-legacy", "Tofu, raw, firm, prepared with calcium sulfate"),
    "746782": ("usda-fdc-foundation-foods", "Milk, whole, 3.25% milkfat, with added vitamin D"),
    "174277": ("usda-fdc-sr-legacy", "Soy sauce made from soy and wheat (shoyu)"),
    "171410": ("usda-fdc-sr-legacy", "Oil, peanut, salad or cooking"),
    "1105314": ("usda-fdc-foundation-foods", "Bananas, ripe and slightly ripe, raw"),
    "1750340": ("usda-fdc-foundation-foods", "Apples, fuji, with skin, raw"),
    "321360": ("usda-fdc-foundation-foods", "Tomatoes, grape, raw"),
    "2258586": ("usda-fdc-foundation-foods", "Carrots, mature, raw"),
    "2346401": ("usda-fdc-foundation-foods", "Potatoes, russet, without skin, raw"),
    "2346406": ("usda-fdc-foundation-foods", "Cucumber, with peel, raw"),
    "1999633": ("usda-fdc-foundation-foods", "Spinach, mature"),
    "2684443": ("usda-fdc-foundation-foods", "Crustaceans, shrimp, farm raised, raw"),
    "790646": ("usda-fdc-foundation-foods", "Onions, yellow, raw"),
    "747447": ("usda-fdc-foundation-foods", "Broccoli, raw"),
    "2346396": ("usda-fdc-foundation-foods", "Oats, whole grain, rolled, old fashioned"),
    "790018": ("usda-fdc-foundation-foods", "Flour, wheat, all-purpose, unenriched, unbleached"),
    "1104647": ("usda-fdc-foundation-foods", "Garlic, raw"),
}
EXPECTED_FOOD_SOURCES = {
    "usda-fdc-foundation-foods": {
        "sourceVersion": "2026-04-30",
        "dataType": "Foundation",
        "sourceURL": "https://fdc.nal.usda.gov/fdc-datasets/FoodData_Central_foundation_food_json_2026-04-30.zip",
        "archiveSHA256": "186e988ec542e913f51ef62b86a47758e8cdd0d1dc3889e7b055581f3c09c77a",
    },
    "usda-fdc-sr-legacy": {
        "sourceVersion": "2018-04",
        "dataType": "SR Legacy",
        "sourceURL": "https://fdc.nal.usda.gov/fdc-datasets/FoodData_Central_sr_legacy_food_json_2018-04.zip",
        "archiveSHA256": "0fe8ae486a2c8eb42cb96413f058deb51863a46c8fb8eeb4b1fb45006dd338ef",
    },
}
EXPECTED_RECIPE_SOURCE_ID = "anduin-howtocook"
EXPECTED_RECIPE_SOURCE_VERSION = "5fb3140c20b2a713296696dc6fdd3b83ccc617a6"
EXPECTED_RECIPE_COUNTS = {
    "scanned": 373,
    "accepted": 366,
    "rejected": 7,
    "ingredients": 3262,
    "reviewRows": 112,
    "quantityReviewRows": 289,
}
EXPECTED_QUANTITY_COUNTS = {
    "formula": 133,
    "notSpecifiedInSource": 1264,
    "sourceQuantity": 1404,
    "sourceRange": 96,
    "sourceTextOnly": 365,
}


class GateFailure(Exception):
    """A validation failure with a user-readable explanation."""


def read_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise GateFailure(f"cannot read JSON {path.relative_to(ROOT)}: {error}") from error


def normalize_alias(value: str) -> str:
    normalized = unicodedata.normalize("NFKC", value).casefold()
    return "".join(character for character in normalized if character.isalnum())


def expected_production_rows(
    items: list[dict[str, Any]], registry: dict[str, dict[str, Any]]
) -> list[dict[str, Any]]:
    return [
        item
        for item in items
        if (source := registry.get(item.get("sourceID")))
        and source.get("verificationStatus") == "verified"
        and source.get("redistributionAllowed") is True
        and bool(source.get("licenseSPDX"))
        and item.get("licenseStatus") == "verified"
        and isinstance(item.get("sourceRecordID"), str)
        and bool(item["sourceRecordID"].strip())
        and bool(item.get("sourceName"))
        and item.get("sourceDataType") == source.get("dataType")
        and item.get("sourceVersion") == source.get("sourceVersion")
    ]


def validate_manifest(manifest: dict[str, Any]) -> dict[str, dict[str, Any]]:
    if manifest.get("schemaVersion") != 1 or not isinstance(manifest.get("sources"), list):
        raise GateFailure("food source manifest must have schemaVersion 1 and a sources array")
    registry: dict[str, dict[str, Any]] = {}
    for source in manifest["sources"]:
        if not isinstance(source, dict) or not isinstance(source.get("sourceID"), str):
            raise GateFailure("food source manifest contains a malformed source entry")
        source_id = source["sourceID"]
        if source_id in registry:
            raise GateFailure(f"food source manifest repeats sourceID {source_id!r}")
        registry[source_id] = source

    for source_id, expected in EXPECTED_FOOD_SOURCES.items():
        source = registry.get(source_id)
        if source is None:
            raise GateFailure(f"food source manifest is missing {source_id}")
        for key, value in expected.items():
            if source.get(key) != value:
                raise GateFailure(f"{source_id} manifest {key} is not pinned to {value!r}")
        if (
            source.get("licenseSPDX") != "CC0-1.0"
            or source.get("licenseURL") != "https://creativecommons.org/publicdomain/zero/1.0/"
            or source.get("verificationStatus") != "verified"
            or source.get("redistributionAllowed") is not True
            or source.get("dataRole") != "food-composition"
        ):
            raise GateFailure(f"{source_id} manifest does not establish verified CC0 food data")
        if not re.fullmatch(r"[0-9a-f]{64}", str(source.get("archiveSHA256", ""))):
            raise GateFailure(f"{source_id} manifest archiveSHA256 is invalid")

    taiwan_source = registry.get(TAIWAN_FDA_SOURCE_ID)
    expected_taiwan_fields = {
        "sourceURL": "https://data.fda.gov.tw/data/opendata/export/20/json",
        "catalogURL": "https://data.gov.tw/en/datasets/8543",
        "sourceVersion": TAIWAN_FDA_SOURCE_VERSION,
        "retrievedAt": "2026-10-26",
        "archivePath": "FoodDataSources/taiwan-fda-nutrition-2026-10-05.zip",
        "archiveSHA256": TAIWAN_FDA_ARCHIVE_SHA256,
        "archiveMember": "20_5.json",
        "licenseSPDX": "OGDL-Taiwan-1.0",
        "licenseURL": "https://data.gov.tw/license",
        "dataType": "Taiwan FDA Nutrition Information Database",
        "dataRole": "food-composition",
        "redistributionAllowed": True,
        "verificationStatus": "verified",
    }
    if taiwan_source is None:
        raise GateFailure(f"food source manifest is missing {TAIWAN_FDA_SOURCE_ID}")
    for key, value in expected_taiwan_fields.items():
        if taiwan_source.get(key) != value:
            raise GateFailure(f"Taiwan FDA manifest {key} is not pinned to {value!r}")
    if "Taiwan Food and Drug Administration" not in str(taiwan_source.get("attribution", "")):
        raise GateFailure("Taiwan FDA manifest is missing the required attribution text")
    if "Open Government Data License, version 1.0" not in str(taiwan_source.get("attribution", "")):
        raise GateFailure("Taiwan FDA manifest does not identify the OGDL version in its attribution")

    legacy = registry.get("legacy-china-food-seed")
    if legacy is None or (
        legacy.get("verificationStatus") != "unverified"
        or legacy.get("redistributionAllowed") is not False
        or legacy.get("licenseSPDX") is not None
    ):
        raise GateFailure("legacy Chinese seed source must remain explicitly unverified and excluded")
    return registry


def validate_seed(
    items: Any, registry: dict[str, dict[str, Any]]
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    if not isinstance(items, list) or not items:
        raise GateFailure("food seed must be a non-empty array")
    ids: set[int] = set()
    for index, item in enumerate(items):
        if not isinstance(item, dict):
            raise GateFailure(f"seed row {index} is not an object")
        row_id = item.get("id")
        if isinstance(row_id, bool) or not isinstance(row_id, int) or row_id <= 0:
            raise GateFailure(f"seed row {index} has an invalid ID")
        if row_id in ids:
            raise GateFailure(f"seed contains duplicate food ID {row_id}")
        ids.add(row_id)
        if item.get("sourceID") not in registry:
            raise GateFailure(f"seed row {row_id} references an unknown sourceID")

    production = expected_production_rows(items, registry)
    if len(production) != EXPECTED_FOOD_PRODUCTION_COUNT:
        raise GateFailure(
            f"expected {EXPECTED_FOOD_PRODUCTION_COUNT} verified production rows, found {len(production)}"
        )
    fdc_rows = [item for item in production if item.get("sourceID") in EXPECTED_FOOD_SOURCES]
    actual_fdc_records = {item.get("sourceRecordID") for item in fdc_rows}
    if actual_fdc_records != set(EXPECTED_FDC_RECORDS):
        missing = sorted(set(EXPECTED_FDC_RECORDS) - actual_fdc_records)
        extra = sorted(actual_fdc_records - set(EXPECTED_FDC_RECORDS))
        raise GateFailure(f"production FDC record set changed: missing={missing}, extra={extra}")
    taiwan_rows = [item for item in production if item.get("sourceID") == TAIWAN_FDA_SOURCE_ID]
    if len(taiwan_rows) != EXPECTED_TAIWAN_FDA_RECORD_COUNT:
        raise GateFailure(
            f"expected {EXPECTED_TAIWAN_FDA_RECORD_COUNT} Taiwan FDA records, found {len(taiwan_rows)}"
        )
    taiwan_record_ids = {item.get("sourceRecordID") for item in taiwan_rows}
    if len(taiwan_record_ids) != EXPECTED_TAIWAN_FDA_RECORD_COUNT:
        raise GateFailure("Taiwan FDA production records contain duplicate Integration numbers")

    record_keys: set[tuple[str, str]] = set()
    aliases: dict[str, set[int]] = {}
    for item in production:
        row_id = item["id"]
        source_id, record_id = item.get("sourceID"), item.get("sourceRecordID")
        source = registry[source_id]
        if source_id in EXPECTED_FOOD_SOURCES:
            expected_source, expected_name = EXPECTED_FDC_RECORDS[record_id]
            if source_id != expected_source or item.get("sourceName") != expected_name:
                raise GateFailure(f"FDC {record_id} source mapping/name does not match its pinned record")
        elif source_id == TAIWAN_FDA_SOURCE_ID:
            source_record = item.get("sourceRecord")
            simplified_aliases = item.get("simplifiedAliases")
            searchable_aliases = str(item.get("alias") or "").split("|")
            if (
                not isinstance(record_id, str)
                or not re.fullmatch(r"[A-Za-z0-9]+", record_id)
                or item["id"] != int(record_id, 36)
                or not isinstance(source_record, dict)
                or not isinstance(source_record.get("valuesPer100gEdiblePortion"), dict)
                or item.get("sourceName") != source_record.get("sourceName")
                or source_record.get("sourceName") != item.get("sourceName")
                or not isinstance(simplified_aliases, list)
                or any(not isinstance(alias, str) for alias in simplified_aliases)
                or len(set(simplified_aliases)) != len(simplified_aliases)
                or any(alias not in searchable_aliases for alias in simplified_aliases)
            ):
                raise GateFailure(f"Taiwan FDA row {row_id} is not tied to its upstream Integration number")
            try:
                waste = Decimal(str(source_record.get("wasteRatePercent")))
            except InvalidOperation as error:
                raise GateFailure(f"Taiwan FDA row {row_id} has an invalid waste rate") from error
            if not waste.is_finite() or waste < 0 or waste > 100:
                raise GateFailure(f"Taiwan FDA row {row_id} has an out-of-range waste rate")
            expected_edible = int((Decimal(100) - waste).quantize(Decimal("1"), rounding=ROUND_HALF_UP))
            if item.get("edible") != expected_edible:
                raise GateFailure(f"Taiwan FDA row {row_id} does not preserve the source waste rate")
            source_values = source_record["valuesPer100gEdiblePortion"]
            raw_energy = source_values.get("energyKcal")
            if raw_energy is None or Decimal(str(raw_energy)) != Decimal(str(item.get("energyKcal"))):
                raise GateFailure(f"Taiwan FDA row {row_id} energy differs from its per-edible-100g source value")
            for nutrient in ("proteinG", "fatG", "carbohydrateG", "fiberG"):
                raw_value = source_values.get(nutrient)
                normalized_value = item.get(nutrient)
                if raw_value is None:
                    if normalized_value is not None:
                        raise GateFailure(f"Taiwan FDA row {row_id} fills missing {nutrient} with a value")
                elif normalized_value is None or Decimal(str(raw_value)) != Decimal(str(normalized_value)):
                    raise GateFailure(f"Taiwan FDA row {row_id} {nutrient} differs from its source value")
        else:
            raise GateFailure(f"verified food row {row_id} references unsupported source {source_id!r}")
        if item.get("sourceVersion") != source.get("sourceVersion"):
            raise GateFailure(f"food row {row_id} sourceVersion differs from its manifest release")
        if (
            item.get("licenseStatus") != "verified"
            or item.get("nutrientBasis") != "per100g"
            or item.get("sourceDataType") != source.get("dataType")
        ):
            raise GateFailure(f"food row {row_id} has incomplete record-level provenance")
        if record_id is None or (source_id, record_id) in record_keys:
            raise GateFailure(f"food row {row_id} has a missing or duplicate sourceRecordID")
        record_keys.add((source_id, record_id))
        if item.get("massBasis") not in {"edibleRaw", "cooked", "asPurchased"}:
            raise GateFailure(f"food row {row_id} has an unsupported mass basis")
        preparation = item.get("preparation")
        if preparation == "raw" and item.get("massBasis") != "edibleRaw":
            raise GateFailure(f"raw food row {row_id} is not marked as edibleRaw")
        if preparation == "cooked" and item.get("massBasis") != "cooked":
            raise GateFailure(f"cooked food row {row_id} is not marked as cooked")
        if preparation == "unknown" and item.get("massBasis") != "asPurchased":
            raise GateFailure(f"unknown-preparation food row {row_id} must preserve as-purchased basis")

        aliases_for_row = [item.get("name", "")]
        if item.get("alias"):
            aliases_for_row.extend(item["alias"].split("|"))
        for alias in aliases_for_row:
            key = normalize_alias(alias)
            if not key:
                raise GateFailure(f"food row {row_id} contains an empty normalized alias")
            aliases.setdefault(key, set()).add(row_id)
    collisions = {alias: sorted(owners) for alias, owners in aliases.items() if len(owners) > 1}
    if collisions:
        first = sorted(collisions.items())[:8]
        raise GateFailure(f"production aliases are ambiguous across food IDs: {first}")
    return production, {"foodIDs": len(ids), "productionAliases": len(aliases)}


def invoke_importer(input_path: Path, output_path: Path, *, production: bool) -> subprocess.CompletedProcess[str]:
    command = [
        sys.executable,
        str(FOOD_IMPORTER),
        "--input",
        str(input_path),
        "--manifest",
        str(FOOD_MANIFEST),
        "--output",
        str(output_path),
    ]
    if production:
        command.append("--production")
    return subprocess.run(command, check=False, capture_output=True, text=True)


def validate_imported_database(
    database_path: Path,
    expected_rows: list[dict[str, Any]],
    registry: dict[str, dict[str, Any]],
    *,
    production: bool,
) -> int:
    with sqlite3.connect(database_path) as connection:
        food_count = connection.execute("SELECT COUNT(*) FROM food_items").fetchone()[0]
        fts_count = connection.execute("SELECT COUNT(*) FROM food_fts").fetchone()[0]
        if food_count != len(expected_rows) or fts_count != len(expected_rows):
            raise GateFailure(
                f"{'production' if production else 'development'} DB row count mismatch: "
                f"expected={len(expected_rows)}, rows={food_count}, FTS={fts_count}"
            )
        actual_rows = connection.execute(
            "SELECT id, name, alias, sourceID, sourceRecordID, sourceVersion, "
            "licenseStatus, sourceRecordJSON, energyKcal, energyRaw, energyUnit "
            "FROM food_items ORDER BY id"
        ).fetchall()

    expected_by_id = {item["id"]: item for item in expected_rows}
    actual_ids = [row[0] for row in actual_rows]
    if len(set(actual_ids)) != len(actual_ids) or set(actual_ids) != set(expected_by_id):
        raise GateFailure("imported food database IDs differ from the expected source rows")
    for (
        row_id,
        name,
        alias,
        source_id,
        record_id,
        version,
        license_status,
        source_json,
        energy_kcal,
        energy_raw,
        energy_unit,
    ) in actual_rows:
        source_record = json.loads(source_json)
        expected = expected_by_id[row_id]
        raw_energy = expected.get("energyKcal", expected.get("energy"))
        expected_unit = expected.get("energyUnit", "kcal/100g")
        normalized_energy = float(raw_energy)
        if expected_unit == "kJ/100g":
            normalized_energy /= 4.184
        if (
            name != expected["name"]
            or alias != expected.get("alias")
            or source_id != expected["sourceID"]
            or record_id != expected.get("sourceRecordID")
            or version != expected["sourceVersion"]
            or license_status != expected.get("licenseStatus", "unverified")
            or source_record != expected
            or energy_kcal != round(normalized_energy)
            or energy_raw != str(raw_energy)
            or energy_unit != expected_unit
        ):
            raise GateFailure(
                f"imported food row {row_id} lost or changed its source record or energy value"
            )
        source = registry[source_id]
        if production and (
            license_status != "verified"
            or source.get("verificationStatus") != "verified"
            or source.get("redistributionAllowed") is not True
            or not record_id
            or version != source.get("sourceVersion")
        ):
            raise GateFailure(f"production database contains unverified row {row_id}")
    return int(food_count)


def validate_taiwan_archive_reproducibility(items: list[dict[str, Any]]) -> dict[str, Any]:
    if not TAIWAN_ARCHIVE.is_file():
        raise GateFailure("pinned Taiwan FDA archive is missing from FoodDataSources")
    digest = hashlib.sha256()
    with TAIWAN_ARCHIVE.open("rb") as archive_file:
        for chunk in iter(lambda: archive_file.read(1_048_576), b""):
            digest.update(chunk)
    actual_digest = digest.hexdigest()
    if actual_digest != TAIWAN_FDA_ARCHIVE_SHA256:
        raise GateFailure(f"Taiwan FDA archive SHA-256 mismatch: {actual_digest}")

    if not TAIWAN_OPENCC_WHEEL.is_file():
        raise GateFailure("pinned OpenCC wheel is missing from FoodDataSources/wheels")
    wheel_digest = hashlib.sha256()
    with TAIWAN_OPENCC_WHEEL.open("rb") as wheel_file:
        for chunk in iter(lambda: wheel_file.read(1_048_576), b""):
            wheel_digest.update(chunk)
    actual_wheel_digest = wheel_digest.hexdigest()
    if actual_wheel_digest != TAIWAN_OPENCC_WHEEL_SHA256:
        raise GateFailure(f"pinned OpenCC wheel SHA-256 mismatch: {actual_wheel_digest}")

    taiwan_rows = [item for item in items if item.get("sourceID") == TAIWAN_FDA_SOURCE_ID]
    report = read_json(TAIWAN_IMPORT_REPORT)
    alias_review = read_json(TAIWAN_ALIAS_REVIEW)
    if not isinstance(report, dict) or not isinstance(alias_review, list):
        raise GateFailure("Taiwan FDA import and alias review reports have invalid shapes")
    report_source = report.get("source")
    alias_review_summary = report.get("aliasReview")
    alias_conversion = report.get("aliasConversion")
    simplified_alias_count = sum(
        len(item.get("simplifiedAliases", [])) for item in taiwan_rows
    )
    ambiguous_simplified_count = sum(
        "opencc-t2s" in entry.get("aliasOrigins", [])
        for entry in alias_review
        if isinstance(entry, dict)
    )
    if (
        len(taiwan_rows) != EXPECTED_TAIWAN_FDA_RECORD_COUNT
        or report.get("recordCount") != EXPECTED_TAIWAN_FDA_RECORD_COUNT
        or not isinstance(report_source, dict)
        or report_source.get("archiveSHA256") != TAIWAN_FDA_ARCHIVE_SHA256
        or not isinstance(alias_review_summary, dict)
        or alias_review_summary.get("ambiguousAliasCount") != len(alias_review)
        or not isinstance(alias_conversion, dict)
        or alias_conversion.get("tool") != "opencc-python-reimplemented"
        or alias_conversion.get("version") != TAIWAN_OPENCC_VERSION
        or alias_conversion.get("config") != "t2s"
        or alias_conversion.get("wheelSHA256") != TAIWAN_OPENCC_WHEEL_SHA256
        or alias_conversion.get("canonicalNamesRemainTraditional") is not True
        or alias_conversion.get("simplifiedAliasesAttached") != simplified_alias_count
        or alias_conversion.get("ambiguousSimplifiedAliasesReviewed") != ambiguous_simplified_count
    ):
        raise GateFailure("Taiwan FDA checked-in report does not match the pinned production record counts")

    rows_by_record_id = {row["sourceRecordID"]: row for row in taiwan_rows}
    for entry in alias_review:
        if (
            not isinstance(entry, dict)
            or not isinstance(entry.get("sourceRecordID"), str)
            or not isinstance(entry.get("aliasOrigins"), list)
            or any(origin not in {"source-common-or-english-name", "opencc-t2s", "source-canonical-name"} for origin in entry["aliasOrigins"])
        ):
            raise GateFailure("Taiwan FDA alias review contains a malformed entry")
        row = rows_by_record_id.get(entry["sourceRecordID"])
        if row is None:
            raise GateFailure("Taiwan FDA alias review references a record outside the production dataset")
        row_aliases = [row.get("name", ""), *str(row.get("alias") or "").split("|")]
        if normalize_alias(str(entry.get("alias", ""))) in {normalize_alias(alias) for alias in row_aliases}:
            raise GateFailure("Taiwan FDA alias review contains a name that was still attached to that record")

    result = subprocess.run(
        [sys.executable, str(TAIWAN_IMPORTER), "--check"],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise GateFailure(f"Taiwan FDA archive does not reproduce checked-in food rows: {result.stderr.strip()}")
    return {
        "archiveSHA256": actual_digest,
        "openccWheelSHA256": actual_wheel_digest,
        "sourceVersion": TAIWAN_FDA_SOURCE_VERSION,
        "productionRecordCount": len(taiwan_rows),
        "excludedRecords": report.get("excludedRecords", {}),
        "missingNutrientValues": report.get("missingNutrientValues", {}),
        "ambiguousAliasEntriesReviewed": len(alias_review),
        "simplifiedAliasesAttached": simplified_alias_count,
        "ambiguousSimplifiedAliasesReviewed": ambiguous_simplified_count,
    }


def probe_unavailable_energy(temp: Path, seed_row: dict[str, Any]) -> dict[str, Any]:
    rejected: list[str] = []
    for marker_name, marker in [
        ("missing", ...),
        ("null", None),
        ("empty", ""),
        ("dash", "—"),
        ("trace", "Tr"),
    ]:
        item = dict(seed_row)
        item["id"] = 80001
        if marker is ...:
            item.pop("energyKcal", None)
            item.pop("energy", None)
        else:
            item["energyKcal"] = marker
        input_path = temp / f"energy-{marker_name}.json"
        output_path = temp / f"energy-{marker_name}.db"
        input_path.write_text(json.dumps([item], ensure_ascii=False), encoding="utf-8")
        result = invoke_importer(input_path, output_path, production=False)
        if result.returncode == 0 or "energy" not in result.stderr.lower():
            raise GateFailure(
                f"importer did not reject unavailable energy marker {marker_name}: "
                f"exit={result.returncode}, stderr={result.stderr.strip()!r}"
            )
        rejected.append(marker_name)

    explicit_zero = dict(seed_row)
    explicit_zero["id"] = 80002
    explicit_zero["energyKcal"] = 0
    input_path = temp / "energy-explicit-zero.json"
    output_path = temp / "energy-explicit-zero.db"
    input_path.write_text(json.dumps([explicit_zero], ensure_ascii=False), encoding="utf-8")
    result = invoke_importer(input_path, output_path, production=False)
    if result.returncode != 0:
        raise GateFailure(f"importer rejected explicit numeric zero: {result.stderr.strip()}")
    with sqlite3.connect(output_path) as connection:
        value = connection.execute(
            "SELECT energyKcal FROM food_items WHERE id = 80002"
        ).fetchone()
    if value != (0,):
        raise GateFailure(f"importer failed to preserve explicit numeric zero: {value!r}")
    return {"rejectedUnavailableMarkers": rejected, "explicitNumericZeroPreserved": True}


def probe_food_basis_and_record_identity(
    temp: Path, seed_row: dict[str, Any]
) -> dict[str, Any]:
    rejected: list[str] = []

    def expect_rejected(label: str, rows: list[dict[str, Any]]) -> None:
        input_path = temp / f"food-contract-{label}.json"
        output_path = temp / f"food-contract-{label}.db"
        input_path.write_text(json.dumps(rows, ensure_ascii=False), encoding="utf-8")
        result = invoke_importer(input_path, output_path, production=False)
        if result.returncode == 0:
            raise GateFailure(f"importer accepted invalid food composition contract {label}")
        rejected.append(label)

    missing_unit = dict(seed_row)
    missing_unit["id"] = 80003
    missing_unit.pop("energyUnit", None)
    expect_rejected("missing-energy-unit", [missing_unit])

    missing_basis = dict(seed_row)
    missing_basis["id"] = 80004
    missing_basis.pop("nutrientBasis", None)
    expect_rejected("missing-nutrient-basis", [missing_basis])

    per_serving = dict(seed_row)
    per_serving["id"] = 80005
    per_serving["energyUnit"] = "kcal/serving"
    per_serving["nutrientBasis"] = "perServing"
    expect_rejected("per-serving-energy", [per_serving])

    unknown_mass_basis = dict(seed_row)
    unknown_mass_basis["id"] = 80006
    unknown_mass_basis["preparation"] = "unknown"
    unknown_mass_basis["massBasis"] = "unknown"
    expect_rejected("verified-unknown-mass-basis", [unknown_mass_basis])

    missing_mass_basis = dict(seed_row)
    missing_mass_basis["id"] = 80007
    missing_mass_basis.pop("massBasis", None)
    expect_rejected("verified-missing-mass-basis", [missing_mass_basis])

    mismatched_raw_cooked = dict(seed_row)
    mismatched_raw_cooked["id"] = 80008
    mismatched_raw_cooked["preparation"] = "raw"
    mismatched_raw_cooked["massBasis"] = "cooked"
    expect_rejected("raw-cooked-basis-mismatch", [mismatched_raw_cooked])

    duplicate_first = dict(seed_row)
    duplicate_first["id"] = 80009
    duplicate_second = dict(seed_row)
    duplicate_second["id"] = 80010
    expect_rejected("duplicate-source-record", [duplicate_first, duplicate_second])

    kj_item = dict(seed_row)
    kj_item["id"] = 80011
    kj_item["energyKcal"] = 418.4
    kj_item["energyUnit"] = "kJ/100g"
    input_path = temp / "food-contract-kj-conversion.json"
    output_path = temp / "food-contract-kj-conversion.db"
    input_path.write_text(json.dumps([kj_item], ensure_ascii=False), encoding="utf-8")
    result = invoke_importer(input_path, output_path, production=False)
    if result.returncode != 0:
        raise GateFailure(f"importer rejected supported kJ/100g input: {result.stderr.strip()}")
    with sqlite3.connect(output_path) as connection:
        converted = connection.execute(
            "SELECT energyKcal, energyRaw, energyUnit FROM food_items WHERE id = 80011"
        ).fetchone()
    if converted != (100, "418.4", "kJ/100g"):
        raise GateFailure(f"importer did not preserve and normalize kJ/100g input: {converted!r}")

    return {
        "rejectedInvalidBasisOrProvenance": rejected,
        "convertedKJPer100g": converted[0],
        "retainedRawEnergyUnit": converted[2],
    }


def validate_recipe_priors() -> dict[str, Any]:
    catalog = read_json(RECIPE_CATALOG)
    manifest = read_json(RECIPE_MANIFEST)
    report = read_json(RECIPE_REPORT)
    if not isinstance(catalog, dict) or not isinstance(manifest, dict) or not isinstance(report, dict):
        raise GateFailure("recipe prior catalog, source manifest, and import report must be JSON objects")
    validation = subprocess.run(
        [sys.executable, str(RECIPE_VALIDATOR), "--catalog", str(RECIPE_CATALOG), "--report", str(RECIPE_REPORT)],
        check=False,
        capture_output=True,
        text=True,
    )
    if validation.returncode != 0:
        raise GateFailure(
            "recipe prior validator failed: "
            f"{validation.stdout.strip()} {validation.stderr.strip()}".strip()
        )
    try:
        validator_result = json.loads(validation.stdout)
    except json.JSONDecodeError as error:
        raise GateFailure(f"recipe prior validator did not return JSON: {error}") from error

    source = catalog.get("source")
    manifest_source = manifest.get("source")
    recipes = catalog.get("recipes")
    if (
        catalog.get("schemaVersion") != 2
        or not isinstance(source, dict)
        or not isinstance(manifest_source, dict)
        or not isinstance(recipes, list)
    ):
        raise GateFailure("recipe prior catalog is missing schema/source metadata or recipes")
    if source != manifest_source:
        raise GateFailure("recipe prior catalog source metadata differs from recipe_sources.json")
    if (
        source.get("sourceID") != EXPECTED_RECIPE_SOURCE_ID
        or source.get("sourceVersion") != EXPECTED_RECIPE_SOURCE_VERSION
        or source.get("licenseSPDX") != "Unlicense"
        or source.get("verificationStatus") != "verified"
        or source.get("redistributionAllowed") is not True
        or source.get("dataRole") != "recipe-prior"
    ):
        raise GateFailure("recipe prior source/license/version is not the pinned reviewed source")
    if (
        len(recipes) != EXPECTED_RECIPE_COUNTS["accepted"]
        or report.get("scannedCount") != EXPECTED_RECIPE_COUNTS["scanned"]
        or report.get("acceptedCount") != EXPECTED_RECIPE_COUNTS["accepted"]
        or report.get("rejectedCount") != EXPECTED_RECIPE_COUNTS["rejected"]
        or len(report.get("rejections", [])) != EXPECTED_RECIPE_COUNTS["rejected"]
        or report.get("ingredientRowCount") != EXPECTED_RECIPE_COUNTS["ingredients"]
        or report.get("reviewRowCount") != EXPECTED_RECIPE_COUNTS["reviewRows"]
        or len(report.get("reviewRows", [])) != EXPECTED_RECIPE_COUNTS["reviewRows"]
        or report.get("quantityReviewRowCount") != EXPECTED_RECIPE_COUNTS["quantityReviewRows"]
        or len(report.get("quantityReviewRows", [])) != EXPECTED_RECIPE_COUNTS["quantityReviewRows"]
        or report.get("quantityEvidenceCounts") != EXPECTED_QUANTITY_COUNTS
    ):
        raise GateFailure(
            "recipe prior scanned/accepted/rejected/ingredient/review/quantity evidence "
            "counts changed from the pin"
        )
    if (
        report.get("sourceID") != EXPECTED_RECIPE_SOURCE_ID
        or report.get("sourceVersion") != EXPECTED_RECIPE_SOURCE_VERSION
        or report.get("licenseSPDX") != "Unlicense"
        or report.get("status") != "PASS"
        or validator_result.get("status") != "PASS"
    ):
        raise GateFailure("recipe prior import report does not match the pinned source")

    quantity_counts: Counter[str] = Counter()
    ingredient_count = 0
    for recipe in recipes:
        for ingredient in recipe.get("ingredients", []):
            evidence = ingredient.get("quantityEvidence", {})
            quantity_counts[evidence.get("kind", "<missing>")] += 1
            ingredient_count += 1
    actual_quantities = dict(sorted(quantity_counts.items()))
    if ingredient_count != EXPECTED_RECIPE_COUNTS["ingredients"]:
        raise GateFailure(
            f"recipe prior ingredient count changed: expected={EXPECTED_RECIPE_COUNTS['ingredients']}, "
            f"actual={ingredient_count}"
        )
    if actual_quantities != dict(sorted(EXPECTED_QUANTITY_COUNTS.items())):
        raise GateFailure(
            f"recipe prior quantity evidence counts changed: {actual_quantities!r}"
        )
    return {
        "sourceID": EXPECTED_RECIPE_SOURCE_ID,
        "sourceVersion": EXPECTED_RECIPE_SOURCE_VERSION,
        "licenseSPDX": "Unlicense",
        "scanned": EXPECTED_RECIPE_COUNTS["scanned"],
        "accepted": len(recipes),
        "rejected": EXPECTED_RECIPE_COUNTS["rejected"],
        "ingredientRows": ingredient_count,
        "reviewedNonIngredientRows": EXPECTED_RECIPE_COUNTS["reviewRows"],
        "reviewedQuantityRows": EXPECTED_RECIPE_COUNTS["quantityReviewRows"],
        "quantityEvidenceCounts": actual_quantities,
        "validator": "PASS",
    }


def main() -> int:
    try:
        items = read_json(FOOD_SEED)
        if not isinstance(items, list):
            raise GateFailure("food seed must be an array")
        manifest = read_json(FOOD_MANIFEST)
        if not isinstance(manifest, dict):
            raise GateFailure("food source manifest must be an object")
        registry = validate_manifest(manifest)
        production, identity_summary = validate_seed(items, registry)
        taiwan_summary = validate_taiwan_archive_reproducibility(items)

        with tempfile.TemporaryDirectory(prefix="densoso-gate17-food-") as directory:
            temporary = Path(directory)
            dev_db = temporary / "food-development.db"
            dev_result = invoke_importer(FOOD_SEED, dev_db, production=False)
            if dev_result.returncode != 0:
                raise GateFailure(f"development food import failed: {dev_result.stderr.strip()}")
            dev_count = validate_imported_database(
                dev_db, items, registry, production=False
            )

            prod_db = temporary / "food-production.db"
            prod_result = invoke_importer(FOOD_SEED, prod_db, production=True)
            if prod_result.returncode != 0:
                raise GateFailure(f"production food import failed: {prod_result.stderr.strip()}")
            prod_count = validate_imported_database(
                prod_db, production, registry, production=True
            )
            energy_summary = probe_unavailable_energy(temporary, production[0])
            basis_summary = probe_food_basis_and_record_identity(temporary, production[0])

        recipe_summary = validate_recipe_priors()
        print(json.dumps({
            "status": "PASS",
            "food": {
                "developmentRows": dev_count,
                "productionRows": prod_count,
                "expectedProductionRows": EXPECTED_FOOD_PRODUCTION_COUNT,
                "verifiedSourceRecordIDs": len(EXPECTED_FDC_RECORDS) + EXPECTED_TAIWAN_FDA_RECORD_COUNT,
                "sourceIDs": sorted([*EXPECTED_FOOD_SOURCES, TAIWAN_FDA_SOURCE_ID]),
                "uniqueFoodIDs": identity_summary["foodIDs"],
                "uniqueProductionAliases": identity_summary["productionAliases"],
                **energy_summary,
                **basis_summary,
            },
            "taiwanFDA": taiwan_summary,
            "recipePriors": recipe_summary,
            "proofBoundary": (
                "Taiwan FDA production rows are regenerated from a bundled, SHA-256-pinned "
                "official archive and checked against source IDs, values, and the checked-in seed. "
                "USDA rows are validated against pinned record IDs/names and importer provenance; "
                "the full USDA archives are not bundled, so this gate does not independently "
                "recompute USDA nutrient values from those archives."
            ),
        }, ensure_ascii=False, sort_keys=True))
        return 0
    except (GateFailure, OSError, sqlite3.Error, json.JSONDecodeError) as error:
        print(json.dumps({"status": "FAIL", "errors": [str(error)]}, ensure_ascii=False), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
