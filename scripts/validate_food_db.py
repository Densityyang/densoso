#!/usr/bin/env python3
"""Validate food import, unit, and production provenance boundaries."""

from __future__ import annotations

import json
import sqlite3
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parent.parent
IMPORTER = ROOT / "scripts" / "import_food_db.py"
SEED_FILE = ROOT / "Densoso" / "Resources" / "seed_foods.json"
MANIFEST_FILE = ROOT / "Densoso" / "Resources" / "FoodData" / "sources.json"
PROJECT_FILE = ROOT / "project.yml"


def _import(
    input_path: Path,
    output_path: Path,
    *,
    production: bool = False,
    manifest_path: Path = MANIFEST_FILE,
) -> subprocess.CompletedProcess[str]:
    command = [
        sys.executable,
        str(IMPORTER),
        "--input",
        str(input_path),
        "--manifest",
        str(manifest_path),
        "--output",
        str(output_path),
    ]
    if production:
        command.append("--production")
    return subprocess.run(command, check=False, capture_output=True, text=True)


def _count(database_path: Path, table: str) -> int:
    with sqlite3.connect(database_path) as connection:
        return int(connection.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0])


def _verify_energy_rejection(temp: Path, seed_item: dict[str, Any], marker: Any, label: str) -> None:
    item = dict(seed_item)
    item["id"] = 9000
    if marker is ...:
        item.pop("energyKcal", None)
    else:
        item["energyKcal"] = marker
    input_path = temp / f"missing-energy-{label}.json"
    output_path = temp / f"missing-energy-{label}.db"
    input_path.write_text(json.dumps([item], ensure_ascii=False), encoding="utf-8")
    result = _import(input_path, output_path)
    if result.returncode == 0:
        raise SystemExit(f"importer accepted unavailable energy marker {label!r}")


def _verify_per_serving_requires_normalization(
    temp: Path,
    seed_item: dict[str, Any],
    *,
    serving_grams: float | None,
    label: str,
) -> None:
    item = dict(seed_item)
    item.update({
        "id": 9005 if serving_grams is None else 9006,
        "energyKcal": 52,
        "energyUnit": "kcal/serving",
        "nutrientBasis": "perServing",
    })
    if serving_grams is None:
        item.pop("servingGrams", None)
    else:
        item["servingGrams"] = serving_grams
    input_path = temp / f"per-serving-{label}.json"
    output_path = temp / f"per-serving-{label}.db"
    input_path.write_text(json.dumps([item], ensure_ascii=False), encoding="utf-8")
    result = _import(input_path, output_path)
    if result.returncode == 0:
        raise SystemExit(
            f"importer treated per-serving energy as per-100g without normalization ({label})"
        )
    if "nutrientBasis 'perServing' is unsupported" not in result.stderr:
        raise SystemExit(f"per-serving input did not fail with an explicit basis error ({label})")


def _verify_unicode_alias_collision_is_reported(
    temp: Path, seed_item: dict[str, Any]
) -> None:
    first = dict(seed_item)
    first.update({"id": 9003, "name": "alias-fixture-one", "alias": "ＡＢＣ"})
    second = dict(seed_item)
    second.update({"id": 9004, "name": "alias-fixture-two", "alias": "abc"})
    input_path = temp / "unicode-alias-collision.json"
    output_path = temp / "unicode-alias-collision.db"
    input_path.write_text(json.dumps([first, second], ensure_ascii=False), encoding="utf-8")
    result = _import(input_path, output_path)
    if result.returncode != 0:
        raise SystemExit(f"alias collision fixture import failed: {result.stderr.strip()}")
    if "alias collision 'abc' maps to food IDs [9003, 9004]" not in result.stderr:
        raise SystemExit("importer did not report aliases that differ only by Unicode width")


def _verify_incomplete_verified_manifest_is_rejected(temp: Path) -> None:
    manifest = json.loads(MANIFEST_FILE.read_text(encoding="utf-8"))
    verified_source = next(
        source for source in manifest["sources"]
        if source.get("verificationStatus") == "verified"
    )
    verified_source.pop("licenseURL", None)
    manifest_path = temp / "incomplete-verified-manifest.json"
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False), encoding="utf-8")
    output_path = temp / "incomplete-verified-manifest.db"
    result = _import(SEED_FILE, output_path, manifest_path=manifest_path)
    if result.returncode == 0 or "verified manifest source" not in result.stderr:
        raise SystemExit("importer accepted a verified source with incomplete license evidence")


def main() -> None:
    items = json.loads(SEED_FILE.read_text(encoding="utf-8"))
    if not isinstance(items, list) or not items:
        raise SystemExit("seed_foods.json must contain a non-empty food array")
    if not MANIFEST_FILE.is_file():
        raise SystemExit("food source manifest is missing")
    project_spec = PROJECT_FILE.read_text(encoding="utf-8")
    if "            --production" not in project_spec:
        raise SystemExit("app food database prebuild must use the production provenance filter")
    if "          - Resources/seed_foods.json" not in project_spec:
        raise SystemExit("unverified seed data must be excluded from the app target's source resources")
    if "      - path: Densoso/Resources\n        type: folder" in project_spec:
        raise SystemExit("the whole Resources folder cannot be shipped as a folder reference")

    manifest = json.loads(MANIFEST_FILE.read_text(encoding="utf-8"))
    registry = {source["sourceID"]: source for source in manifest["sources"]}
    expected_production_count = sum(
        1
        for item in items
        if (source := registry.get(item.get("sourceID")))
        and source.get("verificationStatus") == "verified"
        and source.get("redistributionAllowed") is True
        and source.get("licenseSPDX")
        and item.get("licenseStatus") == "verified"
        and item.get("sourceRecordID")
        and item.get("sourceName")
        and item.get("sourceDataType") == source.get("dataType")
        and item.get("sourceVersion") == source.get("sourceVersion")
    )

    with tempfile.TemporaryDirectory(prefix="densoso-food-db-") as temporary_directory:
        temporary = Path(temporary_directory)
        dev_database = temporary / "food_composition_dev.db"
        dev_result = _import(SEED_FILE, dev_database)
        if dev_result.returncode != 0:
            raise SystemExit(f"development food import failed: {dev_result.stderr.strip()}")
        row_count = _count(dev_database, "food_items")
        fts_count = _count(dev_database, "food_fts")
        if row_count != len(items) or fts_count != len(items):
            raise SystemExit(
                f"food database row mismatch: items={len(items)}, rows={row_count}, fts={fts_count}"
            )

        with sqlite3.connect(dev_database) as connection:
            sample_name = items[0]["name"]
            match_count = connection.execute(
                "SELECT COUNT(*) FROM food_fts WHERE food_fts MATCH ?", (f'"{sample_name}"',)
            ).fetchone()[0]
            if match_count != 1:
                raise SystemExit(f"FTS smoke test failed for {sample_name!r}: matches={match_count}")

            cooked_rice = connection.execute(
                "SELECT energyKcal FROM food_items WHERE name = '米饭(熟)'"
            ).fetchone()
            raw_rice = connection.execute(
                "SELECT energyKcal FROM food_items WHERE name = '大米(生)'"
            ).fetchone()
            if cooked_rice != (116,) or raw_rice != (346,):
                raise SystemExit("rice mass-basis fixtures are missing or have incorrect energy values")
            provenance_count = connection.execute(
                "SELECT COUNT(*) FROM food_items WHERE sourceID IS NOT NULL AND sourceVersion IS NOT NULL"
            ).fetchone()[0]
            if provenance_count != len(items):
                raise SystemExit("development database did not retain per-row provenance")

        production_database = temporary / "food_composition_production.db"
        production_result = _import(SEED_FILE, production_database, production=True)
        if production_result.returncode != 0:
            raise SystemExit(f"production food import failed: {production_result.stderr.strip()}")
        production_count = _count(production_database, "food_items")
        if production_count != expected_production_count:
            raise SystemExit(
                "production database contains records without verified redistributable provenance: "
                f"expected={expected_production_count}, actual={production_count}"
            )
        with sqlite3.connect(production_database) as connection:
            production_rows = connection.execute(
                "SELECT sourceID, sourceRecordID, sourceVersion, licenseStatus, sourceRecordJSON "
                "FROM food_items ORDER BY id"
            ).fetchall()
        if any(row[3] != "verified" for row in production_rows):
            raise SystemExit("production database contains a row without verified record-level licensing")
        if len({(row[0], row[1]) for row in production_rows}) != len(production_rows):
            raise SystemExit("production database contains duplicate source record IDs")
        for source_id, source_record_id, source_version, _, source_record_json in production_rows:
            source_record = json.loads(source_record_json)
            source = registry[source_id]
            if (
                not source_record.get("sourceName")
                or source_record.get("sourceRecordID") != source_record_id
                or source_version != source.get("sourceVersion")
                or source_record.get("massBasis") not in {"edibleRaw", "cooked", "asPurchased"}
                or source_record.get("nutrientBasis") != "per100g"
            ):
                raise SystemExit(
                    f"USDA source attribution or edible-mass basis was not retained for {source_record_id}"
                )

        for marker, label in [
            (..., "missing"),
            (None, "null"),
            ("", "empty"),
            ("—", "dash"),
            ("Tr", "trace"),
        ]:
            _verify_energy_rejection(temporary, items[0], marker, label)

        _verify_per_serving_requires_normalization(
            temporary, items[0], serving_grams=None, label="missing-serving-mass"
        )
        _verify_per_serving_requires_normalization(
            temporary, items[0], serving_grams=40, label="explicit-serving-mass-not-normalized"
        )

        _verify_unicode_alias_collision_is_reported(temporary, items[0])
        _verify_incomplete_verified_manifest_is_rejected(temporary)

        zero_item = dict(items[0])
        zero_item["id"] = 9001
        zero_item["energyKcal"] = 0
        zero_input = temporary / "explicit-zero.json"
        zero_database = temporary / "explicit-zero.db"
        zero_input.write_text(json.dumps([zero_item], ensure_ascii=False), encoding="utf-8")
        zero_result = _import(zero_input, zero_database)
        if zero_result.returncode != 0:
            raise SystemExit(f"importer rejected explicit numeric zero: {zero_result.stderr.strip()}")
        with sqlite3.connect(zero_database) as connection:
            explicit_zero = connection.execute(
                "SELECT energyKcal FROM food_items WHERE id = 9001"
            ).fetchone()
        if explicit_zero != (0,):
            raise SystemExit("explicit numeric zero was not preserved")

        kj_item = dict(items[0])
        kj_item["id"] = 9002
        kj_item["energyKcal"] = 418.4
        kj_item["energyUnit"] = "kJ/100g"
        kj_input = temporary / "kilo-joules.json"
        kj_database = temporary / "kilo-joules.db"
        kj_input.write_text(json.dumps([kj_item], ensure_ascii=False), encoding="utf-8")
        kj_result = _import(kj_input, kj_database)
        if kj_result.returncode != 0:
            raise SystemExit(f"importer rejected a valid kJ value: {kj_result.stderr.strip()}")
        with sqlite3.connect(kj_database) as connection:
            normalized_energy = connection.execute(
                "SELECT energyKcal, energyRaw, energyUnit FROM food_items WHERE id = 9002"
            ).fetchone()
        if normalized_energy != (100, "418.4", "kJ/100g"):
            raise SystemExit(f"kJ conversion or raw energy retention failed: {normalized_energy!r}")

    print(
        "Food database validation passed: "
        f"{len(items)} development rows, {production_count} redistributable production rows."
    )


if __name__ == "__main__":
    main()
